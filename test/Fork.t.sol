// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StockMine} from "../src/StockMine.sol";
import {IERC20} from "../src/Interfaces.sol";
import {MockArbSys, MockERC20} from "./Mocks.sol";

/// @dev Runs against a fork of Robinhood Chain: the real SwapRouter02, the real tokenized stocks and the real
///      Pons escrow. Only ArbSys is mocked, because a local EVM has no Nitro precompiles.
///      FORK=1 forge test --match-contract ForkTest -vv
contract ForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant PONS_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;

    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    StockMine game;
    MockArbSys arb = MockArbSys(address(100));
    MockERC20 token;
    address alice = makeAddr("stockmine-fork-alice");
    address bob = makeAddr("stockmine-fork-bob");

    function setUp() public {
        if (!vm.envOr("FORK", false)) return;
        vm.createSelectFork("robinhood");
        vm.etch(address(100), address(new MockArbSys()).code);
        arb.set(1_000_000);

        token = new MockERC20("Project", "PRJ");
        game = new StockMine(60, 0.0001 ether, WETH, ROUTER, PONS_ESCROW, PONS_FACTORY);
        game.setToken(address(token));
        game.setStock(NVDA, true);
        game.setStock(TSLA, true);
        game.setStock(SPY, true);
        game.setStock(AAPL, true);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _predict(uint256 round) internal view returns (uint8) {
        bytes32 h = keccak256(abi.encode("l2-block", arb.number() + game.TARGET_DELAY()));
        return uint8(uint256(keccak256(abi.encode(h, round, address(game)))) % 25);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function test_fork_roundThenRealStockToTheWinner() public {
        if (!vm.envOr("FORK", false)) vm.skip(true);

        uint256 round = game.currentRound();
        uint8 w = _predict(round);
        vm.prank(alice);
        game.deploy{value: 0.5 ether}(uint32(1 << w));
        vm.prank(bob);
        game.deploy{value: 2 ether}(uint32(1 << ((w + 1) % 25)));

        vm.warp(game.roundEndsAt(round));
        game.close(round);
        arb.roll(game.TARGET_DELAY() + 1);
        game.settle(round);
        assertEq(game.potEth(), 0.14 ether);

        game.closeEpoch(NVDA, 500, 1);
        uint256 bought = game.epochStock(0);
        console2.log("NVDA bought with 0.14 ETH (1e18):", bought);
        assertGt(bought, 0);

        vm.startPrank(alice);
        game.claim(_one(round));
        game.claimStock(_one(0));
        vm.stopPrank();
        assertEq(IERC20(NVDA).balanceOf(alice), bought);
        assertEq(alice.balance, 10 ether + 1.86 ether);
    }

    function test_fork_everyListedStockCanBeBoughtAndPaidOut() public {
        if (!vm.envOr("FORK", false)) vm.skip(true);

        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.approve(address(game), type(uint256).max);
        game.stake(100e18);
        vm.stopPrank();

        address[4] memory list = [NVDA, TSLA, SPY, AAPL];
        uint24[4] memory fees = [uint24(500), 3000, 500, 500];
        for (uint256 i; i < list.length; ++i) {
            (bool ok,) = address(game).call{value: 0.1 ether}("");
            assertTrue(ok);
            game.closeEpoch(list[i], fees[i], 1);
        }
        vm.prank(alice);
        game.claimStaking();
        for (uint256 i; i < list.length; ++i) {
            uint256 got = IERC20(list[i]).balanceOf(alice);
            console2.log("stock received for 0.1 ETH (1e18):", got);
            assertGt(got, 0);
            // only the rounding dust of the per-share accumulator may stay behind
            assertLt(IERC20(list[i]).balanceOf(address(game)), 1_000);
        }
    }

    function test_fork_harvestAgainstTheRealPonsEscrow() public {
        if (!vm.envOr("FORK", false)) vm.skip(true);

        game.harvest(); // nothing credited yet: must not revert
        assertEq(game.potEth(), 0);

        // `credit(address)` is how curves and the hook pay a recipient; if it is open, prove the full path
        (bool ok,) = PONS_ESCROW.call{value: 0.3 ether}(abi.encodeWithSignature("credit(address)", address(game)));
        console2.log("escrow.credit callable from outside:", ok);
        if (ok) {
            game.harvest();
            assertEq(game.potEth(), 0.3 ether);
        }
    }

    receive() external payable {}
}
