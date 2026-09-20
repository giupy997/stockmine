// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISwapRouter02, IPonsRouter} from "../src/Interfaces.sol";

/// @dev Stand-in for the Nitro precompile: same range rule as the real one (last 256 blocks, never the future).
contract MockArbSys {
    uint256 public number;

    error InvalidBlockNumber();

    function set(uint256 n) external {
        number = n;
    }

    function roll(uint256 by) external {
        number += by;
    }

    function arbBlockNumber() external view returns (uint256) {
        return number;
    }

    function arbBlockHash(uint256 b) external view returns (bytes32) {
        if (b >= number || b + 256 < number) revert InvalidBlockNumber();
        return keccak256(abi.encode("l2-block", b));
    }
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Sells any MockERC20 at a fixed rate per ETH and honours the minimum out.
contract MockRouter {
    uint256 public rate = 10e18; // stock units per 1 ETH

    function setRate(uint256 r) external {
        rate = r;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(msg.value == p.amountIn, "value");
        out = (p.amountIn * rate) / 1e18;
        require(out >= p.amountOutMinimum, "Too little received");
        MockERC20(p.tokenOut).mint(p.recipient, out);
    }
}

contract MockEscrow {
    mapping(address => uint256) public balanceOf;

    function credit(address account) external payable {
        balanceOf[account] += msg.value;
    }

    function claim() external {
        uint256 amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send");
    }
}

/// @dev Pons curve stand-in: sells the token at a fixed rate until `graduated` is switched on.
contract MockCurve {
    MockERC20 public immutable asset;
    bool public graduated;
    uint256 public rate = 1_000_000e18; // tokens per 1 ETH

    constructor(MockERC20 asset_) {
        asset = asset_;
    }

    function token() external view returns (address) {
        return address(asset);
    }

    function setGraduated(bool g) external {
        graduated = g;
    }

    uint256 public cap = type(uint256).max; // ETH the curve still accepts before it sells out
    bool public cheat; // deliver one wei and skip the slippage check, like a broken venue would

    function setCap(uint256 c) external {
        cap = c;
    }

    function setCheat(bool c) external {
        cheat = c;
    }

    /// @dev Like the real curve: the buy that sells it out only uses what it needs and refunds the rest.
    function buy(uint256 amountIn, uint256 minAmountOut, address to) external payable returns (uint256 out) {
        require(!graduated, "graduated");
        require(msg.value == amountIn, "value");
        uint256 used = amountIn > cap ? cap : amountIn;
        out = cheat ? 1 : (used * rate) / 1e18;
        require(cheat || out >= minAmountOut, "slippage");
        asset.mint(to, out);
        if (used == cap) graduated = true;
        if (used < amountIn) {
            (bool ok,) = msg.sender.call{value: amountIn - used}("");
            require(ok, "refund");
        }
    }
}

/// @dev Pons router stand-in: one ETH -> token step, output to the caller, and it remembers the step it got.
contract MockPonsRouter {
    uint256 public rate = 500_000e18; // tokens per 1 ETH
    IPonsRouter.Step public lastStep;
    address public lastRecipient;
    uint256 public calls;
    bool public cheat; // deliver one wei and skip the slippage check

    function setCheat(bool c) external {
        cheat = c;
    }

    function swap(IPonsRouter.Step[] calldata steps, address recipient, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        payable
    {
        require(steps.length == 1 && steps[0].tokenIn == address(0), "route");
        require(msg.value == amountIn, "value");
        require(deadline >= block.timestamp, "deadline");
        uint256 out = cheat ? 1 : (amountIn * rate) / 1e18;
        require(cheat || out >= minOut, "slippage");
        lastStep = steps[0];
        lastRecipient = recipient;
        ++calls;
        MockERC20(steps[0].tokenOut).mint(msg.sender, out);
    }
}

contract MockFactory {
    address public lastToken;
    address public lastRecipient;
    uint256 public poolCreations;

    struct Launch {
        address curve;
        address pairToken;
        uint24 poolFee;
        int24 tickSpacing;
    }

    mapping(address => Launch) public launches;

    function setLaunch(address token, address curve, address pairToken, uint24 poolFee, int24 tickSpacing) external {
        launches[token] = Launch(curve, pairToken, poolFee, tickSpacing);
    }

    /// @dev Head of the real record: token, curve, deployer, fee recipient, pair token, threshold, fee, spacing.
    function getLaunchedToken(address token)
        external
        view
        returns (address, address, address, address, address, uint256, uint24, int24)
    {
        Launch memory l = launches[token];
        if (l.curve == address(0)) return (address(0), address(0), address(0), address(0), address(0), 0, 0, 0);
        return (token, l.curve, address(0), address(0), l.pairToken, 4.2 ether, l.poolFee, l.tickSpacing);
    }

    function createGraduatedPool(address) external {
        ++poolCreations;
    }

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        lastToken = token;
        lastRecipient = newRecipient;
    }
}
