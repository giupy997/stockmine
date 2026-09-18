// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IArbSys, IERC20, ISwapRouter02, IPonsEscrow, IPonsFactory} from "./Interfaces.sol";

/// @title StockMine
/// @notice Round game on a 5x5 grid for Robinhood Chain. Players put ETH on squares, one square wins each
///         round and its players share the ETH of the other squares. A cut of every round, plus the Pons
///         creator fees of the project token, fills a pot that buys tokenized stocks; the stocks go to the
///         round winners ("miners") and to the stakers of the project token.
/// @dev    Player funds never touch the pot and no role can move them: the owner and the keeper can only
///         tune bounded parameters, choose which allowed stock an epoch buys and with which slippage.
contract StockMine {
    // ------------------------------------------------------------------ constants

    uint256 public constant SQUARES = 25;
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_CUT_BPS = 1_500;
    uint256 public constant MIN_MINERS_SHARE_BPS = 2_000;
    uint256 public constant MAX_MINERS_SHARE_BPS = 8_000;
    uint256 public constant MAX_UNSTAKE_DELAY = 14 days;
    uint256 public constant MAX_STOCKS = 16;
    /// @dev L2 blocks between `close` and the block whose hash decides the round (~1 s on Robinhood Chain).
    uint256 public constant TARGET_DELAY = 10;
    /// @dev ArbSys only serves the hashes of the last 256 L2 blocks (~25 s).
    uint256 public constant HASH_WINDOW = 256;
    uint256 private constant ACC = 1e18;

    IArbSys private constant ARBSYS = IArbSys(address(100));

    // ------------------------------------------------------------------ immutables

    uint256 public immutable genesis;
    uint256 public immutable roundDuration;
    uint256 public immutable minPerSquare;
    address public immutable weth;
    ISwapRouter02 public immutable router;
    IPonsEscrow public immutable ponsEscrow;
    IPonsFactory public immutable ponsFactory;

    // ------------------------------------------------------------------ roles and parameters

    address public owner;
    address public pendingOwner;
    address public keeper;
    bool public paused;
    uint256 public cutBps = 700;
    uint256 public minersShareBps = 5_000;
    uint256 public unstakeDelay = 3 days;

    /// @notice The project token (launched on Pons after this contract exists). Set once.
    IERC20 public token;

    // ------------------------------------------------------------------ rounds

    enum RoundState {
        Open,
        Closed,
        Settled
    }

    struct Round {
        RoundState state;
        uint8 winner;
        uint64 targetBlock;
        uint64 epoch;
        uint256 total;
        uint256 winnersStake;
        uint256 prize;
    }

    mapping(uint256 => Round) public rounds;
    mapping(uint256 => uint256[25]) private _squareTotal;
    mapping(uint256 => mapping(address => uint256[25])) private _deployed;

    /// @notice ETH waiting to be turned into stocks at the next `closeEpoch`.
    uint256 public potEth;
    /// @notice ETH of rounds nobody won, added to the prize of the next round that has winners.
    uint256 public rollover;

    // ------------------------------------------------------------------ epochs (stock rewards for miners)

    uint256 public epoch;
    mapping(uint256 => uint256) public epochPoints;
    mapping(uint256 => uint256) public epochStock;
    mapping(uint256 => address) public epochToken;
    mapping(uint256 => mapping(address => uint256)) public points;
    mapping(uint256 => mapping(address => uint256)) public paidPoints;

    // ------------------------------------------------------------------ staking (stock rewards for holders)

    address[] public stocks;
    mapping(address => bool) public stockAllowed;
    mapping(address => bool) private _stockListed;
    mapping(address => uint256) public accPerShare;

    uint256 public totalStaked;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public stakedAt;
    mapping(address => mapping(address => uint256)) private _rewardDebt;
    mapping(address => mapping(address => uint256)) private _pendingStock;

    uint256 private _lock = 1;

    // ------------------------------------------------------------------ events

    event Deployed(uint256 indexed round, address indexed player, uint32 mask, uint256 perSquare);
    event RoundClosed(uint256 indexed round, uint256 targetBlock);
    event RoundSettled(uint256 indexed round, uint8 winner, uint256 total, uint256 winnersStake, uint256 prize, uint256 cut);
    event Claimed(address indexed player, uint256 amount);
    event PotFunded(address indexed from, uint256 amount);
    event EpochClosed(uint256 indexed epoch, address indexed stock, uint256 ethSpent, uint256 bought, uint256 toMiners, uint256 toStakers);
    event StockClaimed(address indexed account, address indexed stock, uint256 amount);
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event StockSet(address indexed stock, bool allowed);
    event ParamsSet(uint256 cutBps, uint256 minersShareBps, uint256 unstakeDelay);
    event KeeperSet(address indexed keeper);
    event TokenSet(address indexed token);
    event PausedSet(bool paused);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    // ------------------------------------------------------------------ errors

    error NotOwner();
    error NotKeeper();
    error Reentrancy();
    error Paused();
    error BadMask();
    error BadAmount();
    error BadParam();
    error RoundNotOver();
    error RoundEmpty();
    error RoundNotOpen();
    error RoundNotClosed();
    error RoundNotSettled();
    error TargetNotReached();
    error TargetStillValid();
    error TargetExpired();
    error StockNotAllowed();
    error NothingToDistribute();
    error TokenAlreadySet();
    error TokenNotSet();
    error StakeLocked();
    error TransferFailed();

    // ------------------------------------------------------------------ modifiers

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper && msg.sender != owner) revert NotKeeper();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        uint256 roundDuration_,
        uint256 minPerSquare_,
        address weth_,
        address router_,
        address ponsEscrow_,
        address ponsFactory_
    ) {
        if (roundDuration_ < 10 || roundDuration_ > 1 days) revert BadParam();
        owner = msg.sender;
        keeper = msg.sender;
        genesis = block.timestamp;
        roundDuration = roundDuration_;
        minPerSquare = minPerSquare_;
        weth = weth_;
        router = ISwapRouter02(router_);
        ponsEscrow = IPonsEscrow(ponsEscrow_);
        ponsFactory = IPonsFactory(ponsFactory_);
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @notice Anything sent here (Pons creator fees, donations) joins the pot that buys stocks.
    receive() external payable {
        potEth += msg.value;
        emit PotFunded(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------ game

    function currentRound() public view returns (uint256) {
        return (block.timestamp - genesis) / roundDuration;
    }

    function roundEndsAt(uint256 round) public view returns (uint256) {
        return genesis + (round + 1) * roundDuration;
    }

    /// @notice Put ETH on the squares set in `mask` (bit i = square i) for the current round, split equally.
    function deploy(uint32 mask) external payable {
        if (paused) revert Paused();
        if (mask == 0 || mask >= (1 << SQUARES)) revert BadMask();

        uint256 count;
        for (uint256 i; i < SQUARES; ++i) {
            if (mask & (1 << i) != 0) ++count;
        }
        uint256 perSquare = msg.value / count;
        if (perSquare < minPerSquare) revert BadAmount();

        uint256 round = currentRound();
        Round storage r = rounds[round];
        uint256[25] storage totals = _squareTotal[round];
        uint256[25] storage mine = _deployed[round][msg.sender];
        for (uint256 i; i < SQUARES; ++i) {
            if (mask & (1 << i) != 0) {
                totals[i] += perSquare;
                mine[i] += perSquare;
            }
        }
        uint256 used = perSquare * count;
        r.total += used;
        // the few wei that do not divide evenly go to the pot
        if (msg.value > used) potEth += msg.value - used;

        emit Deployed(round, msg.sender, mask, perSquare);
    }

    /// @notice First step of the draw, open to anyone once the round is over: it fixes the future L2 block
    ///         whose hash will pick the winning square. If that hash was never read in time (nobody called
    ///         `settle` within ~25 s) the round can be closed again on a new block.
    function close(uint256 round) external {
        Round storage r = rounds[round];
        if (block.timestamp < roundEndsAt(round)) revert RoundNotOver();
        if (r.total == 0) revert RoundEmpty();
        uint256 n = ARBSYS.arbBlockNumber();
        if (r.state == RoundState.Closed) {
            if (n <= uint256(r.targetBlock) + HASH_WINDOW) revert TargetStillValid();
        } else if (r.state != RoundState.Open) {
            revert RoundNotOpen();
        }
        r.state = RoundState.Closed;
        r.targetBlock = uint64(n + TARGET_DELAY);
        emit RoundClosed(round, r.targetBlock);
    }

    /// @notice Second step, open to anyone: reads the hash of the target block and settles the round.
    function settle(uint256 round) external {
        Round storage r = rounds[round];
        if (r.state != RoundState.Closed) revert RoundNotClosed();
        uint256 n = ARBSYS.arbBlockNumber();
        uint256 target = r.targetBlock;
        if (n <= target) revert TargetNotReached();
        if (n > target + HASH_WINDOW) revert TargetExpired();

        bytes32 h = ARBSYS.arbBlockHash(target);
        uint8 winner = uint8(uint256(keccak256(abi.encode(h, round, address(this)))) % SQUARES);

        uint256 winnersStake = _squareTotal[round][winner];
        uint256 losers = r.total - winnersStake;
        uint256 cut = (losers * cutBps) / BPS;
        potEth += cut;

        uint256 prize;
        if (winnersStake == 0) {
            rollover += losers - cut;
        } else {
            prize = losers - cut + rollover;
            rollover = 0;
            epochPoints[epoch] += winnersStake;
        }

        r.state = RoundState.Settled;
        r.winner = winner;
        r.epoch = uint64(epoch);
        r.winnersStake = winnersStake;
        r.prize = prize;
        emit RoundSettled(round, winner, r.total, winnersStake, prize, cut);
    }

    /// @notice Collect the ETH won in settled rounds. Winning stakes also become mining points of the epoch
    ///         the round was settled in, which is what `claimStock` pays on.
    function claim(uint256[] calldata roundIds) external nonReentrant {
        uint256 amount;
        for (uint256 i; i < roundIds.length; ++i) {
            Round storage r = rounds[roundIds[i]];
            if (r.state != RoundState.Settled) revert RoundNotSettled();
            uint256[25] storage mine = _deployed[roundIds[i]][msg.sender];
            uint256 won = mine[r.winner];
            if (won == 0) continue;
            mine[r.winner] = 0;
            amount += won + (r.prize * won) / r.winnersStake;
            points[r.epoch][msg.sender] += won;
        }
        if (amount != 0) _sendEth(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    // ------------------------------------------------------------------ epochs

    /// @notice Pull the Pons creator fees credited to this contract into the pot. Open to anyone.
    function harvest() public {
        if (address(ponsEscrow) == address(0)) return;
        try ponsEscrow.balanceOf(address(this)) returns (uint256 owed) {
            if (owed != 0) {
                try ponsEscrow.claim() {} catch {}
            }
        } catch {}
    }

    /// @notice Spend the pot on one allowed stock and share it between this epoch's miners and the stakers.
    /// @param stock   the tokenized stock to buy (must be allowed)
    /// @param poolFee Uniswap v3 fee tier of the WETH/stock pool to route through
    /// @param minOut  minimum stock amount accepted for the whole pot (slippage guard set by the keeper)
    function closeEpoch(address stock, uint24 poolFee, uint256 minOut) external onlyKeeper nonReentrant {
        if (!stockAllowed[stock]) revert StockNotAllowed();
        harvest();

        uint256 pts = epochPoints[epoch];
        uint256 st = totalStaked;
        uint256 eth = potEth;
        if (eth == 0 || (pts == 0 && st == 0)) revert NothingToDistribute();
        potEth = 0;

        uint256 before = IERC20(stock).balanceOf(address(this));
        router.exactInputSingle{value: eth}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: stock,
                fee: poolFee,
                recipient: address(this),
                amountIn: eth,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 bought = IERC20(stock).balanceOf(address(this)) - before;
        if (bought < minOut || bought == 0) revert BadAmount();

        uint256 toMiners;
        if (pts != 0) toMiners = st == 0 ? bought : (bought * minersShareBps) / BPS;
        uint256 toStakers = bought - toMiners;

        epochStock[epoch] = toMiners;
        epochToken[epoch] = stock;
        if (toStakers != 0) accPerShare[stock] += (toStakers * ACC) / st;

        emit EpochClosed(epoch, stock, eth, bought, toMiners, toStakers);
        ++epoch;
    }

    /// @notice Collect the stocks earned as a miner in closed epochs.
    function claimStock(uint256[] calldata epochIds) external nonReentrant {
        for (uint256 i; i < epochIds.length; ++i) {
            uint256 e = epochIds[i];
            if (e >= epoch) revert BadParam();
            uint256 owedPoints = points[e][msg.sender] - paidPoints[e][msg.sender];
            if (owedPoints == 0) continue;
            paidPoints[e][msg.sender] = points[e][msg.sender];
            uint256 amount = (epochStock[e] * owedPoints) / epochPoints[e];
            if (amount != 0) {
                _sendToken(epochToken[e], msg.sender, amount);
                emit StockClaimed(msg.sender, epochToken[e], amount);
            }
        }
    }

    // ------------------------------------------------------------------ staking

    function stake(uint256 amount) external nonReentrant {
        if (address(token) == address(0)) revert TokenNotSet();
        if (amount == 0) revert BadAmount();
        _accrue(msg.sender);

        uint256 before = token.balanceOf(address(this));
        _pullToken(address(token), msg.sender, amount);
        uint256 received = token.balanceOf(address(this)) - before;

        staked[msg.sender] += received;
        totalStaked += received;
        stakedAt[msg.sender] = block.timestamp;
        _resetDebt(msg.sender);
        emit Staked(msg.sender, received);
    }

    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0 || amount > staked[msg.sender]) revert BadAmount();
        if (block.timestamp < stakedAt[msg.sender] + unstakeDelay) revert StakeLocked();
        _accrue(msg.sender);

        staked[msg.sender] -= amount;
        totalStaked -= amount;
        _resetDebt(msg.sender);
        _sendToken(address(token), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    /// @notice Collect the stocks earned as a staker.
    function claimStaking() external nonReentrant {
        _accrue(msg.sender);
        _resetDebt(msg.sender);
        uint256 len = stocks.length;
        for (uint256 i; i < len; ++i) {
            address s = stocks[i];
            uint256 amount = _pendingStock[msg.sender][s];
            if (amount == 0) continue;
            _pendingStock[msg.sender][s] = 0;
            _sendToken(s, msg.sender, amount);
            emit StockClaimed(msg.sender, s, amount);
        }
    }

    function _accrue(address account) private {
        uint256 bal = staked[account];
        if (bal == 0) return;
        uint256 len = stocks.length;
        for (uint256 i; i < len; ++i) {
            address s = stocks[i];
            uint256 accrued = (bal * accPerShare[s]) / ACC;
            uint256 debt = _rewardDebt[account][s];
            if (accrued > debt) _pendingStock[account][s] += accrued - debt;
        }
    }

    function _resetDebt(address account) private {
        uint256 bal = staked[account];
        uint256 len = stocks.length;
        for (uint256 i; i < len; ++i) {
            address s = stocks[i];
            _rewardDebt[account][s] = (bal * accPerShare[s]) / ACC;
        }
    }

    // ------------------------------------------------------------------ views

    function squareTotals(uint256 round) external view returns (uint256[25] memory) {
        return _squareTotal[round];
    }

    function deployedBy(uint256 round, address player) external view returns (uint256[25] memory) {
        return _deployed[round][player];
    }

    /// @notice ETH `player` can still collect from a settled round (0 if not settled, lost or already claimed).
    function claimable(uint256 round, address player) external view returns (uint256) {
        Round storage r = rounds[round];
        if (r.state != RoundState.Settled) return 0;
        uint256 stake_ = _deployed[round][player][r.winner];
        if (stake_ == 0) return 0;
        return stake_ + (r.prize * stake_) / r.winnersStake;
    }

    /// @notice Stock a miner can collect from a closed epoch, given the rounds they have already claimed.
    function claimableStock(uint256 e, address player) external view returns (address stock, uint256 amount) {
        if (e >= epoch || epochPoints[e] == 0) return (epochToken[e], 0);
        uint256 owedPoints = points[e][player] - paidPoints[e][player];
        return (epochToken[e], (epochStock[e] * owedPoints) / epochPoints[e]);
    }

    function pendingStaking(address account) external view returns (address[] memory list, uint256[] memory amounts) {
        list = stocks;
        amounts = new uint256[](list.length);
        uint256 bal = staked[account];
        for (uint256 i; i < list.length; ++i) {
            uint256 accrued = (bal * accPerShare[list[i]]) / ACC;
            uint256 debt = _rewardDebt[account][list[i]];
            amounts[i] = _pendingStock[account][list[i]] + (accrued > debt ? accrued - debt : 0);
        }
    }

    function stocksCount() external view returns (uint256) {
        return stocks.length;
    }

    // ------------------------------------------------------------------ admin (bounded)

    function setStock(address stock, bool allowed) external onlyOwner {
        if (stock == address(0)) revert BadParam();
        if (allowed && !_stockListed[stock]) {
            if (stocks.length >= MAX_STOCKS) revert BadParam();
            _stockListed[stock] = true;
            stocks.push(stock);
        }
        stockAllowed[stock] = allowed;
        emit StockSet(stock, allowed);
    }

    function setParams(uint256 cutBps_, uint256 minersShareBps_, uint256 unstakeDelay_) external onlyOwner {
        if (cutBps_ > MAX_CUT_BPS) revert BadParam();
        if (minersShareBps_ < MIN_MINERS_SHARE_BPS || minersShareBps_ > MAX_MINERS_SHARE_BPS) revert BadParam();
        if (unstakeDelay_ > MAX_UNSTAKE_DELAY) revert BadParam();
        cutBps = cutBps_;
        minersShareBps = minersShareBps_;
        unstakeDelay = unstakeDelay_;
        emit ParamsSet(cutBps_, minersShareBps_, unstakeDelay_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Stops new deployments only. Closing, settling and every claim keep working while paused.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice Bind the project token once it exists on Pons. Cannot be changed afterwards.
    function setToken(address token_) external onlyOwner {
        if (address(token) != address(0)) revert TokenAlreadySet();
        if (token_ == address(0)) revert BadParam();
        token = IERC20(token_);
        emit TokenSet(token_);
    }

    /// @notice Point the Pons creator fees of the project token at a new recipient (e.g. a later version of
    ///         this contract). Balances already credited stay claimable here through `harvest`.
    function migrateFees(address newRecipient) external onlyOwner {
        if (address(token) == address(0)) revert TokenNotSet();
        if (newRecipient == address(0)) revert BadParam();
        ponsFactory.transferCreatorFeeRecipient(address(token), newRecipient);
    }

    function transferOwnership(address to) external onlyOwner {
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ------------------------------------------------------------------ transfers

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function _sendToken(address asset, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _pullToken(address asset, address from, uint256 amount) private {
        (bool ok, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
