// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {StockMine} from "../src/StockMine.sol";
import {IERC20, IPonsCurve} from "../src/Interfaces.sol";
import {MockArbSys} from "./Mocks.sol";

/// @dev Runs against a fork of Robinhood Chain: the real SwapRouter02, the real tokenized stocks and the real
///      Pons escrow. Only ArbSys is mocked, because a local EVM has no Nitro precompiles.
///      FORK=1 forge test --match-contract ForkTest -vv
contract ForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant PONS_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant PONS_ROUTER = 0x65050A9b7E5075A2bA5cED7b1b64EE66262c40Dc;
    address constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // two real Pons launches from September 2026: one that never left its curve, one that graduated
    address constant CURVE_TOKEN = 0x5151adc7aa7A56f8Cb9E131b7FAd77bA5775b821;
    address constant CURVE_TOKEN_CURVE = 0xa38660420999150b2B4e84B6DCE7a9f16791614E;
    address constant GRAD_TOKEN = 0x49D8c150CfE4004e3988B38824d3654CdB7a37e3;
    address constant GRAD_TOKEN_CURVE = 0xCdd51F5445fc703dac056bD67B1242B73ba9BCCc;

    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

    StockMine game;
    MockArbSys arb = MockArbSys(address(100));
    address alice = makeAddr("stockmine-fork-alice");
    address bob = makeAddr("stockmine-fork-bob");

    function setUp() public {
        if (!vm.envOr("FORK", false)) return;
        vm.createSelectFork("robinhood");
        vm.etch(address(100), address(new MockArbSys()).code);
        arb.set(1_000_000);

        // bound to a real Pons launch: setToken reads its record from the real factory
        game = _newGame();
        game.setToken(CURVE_TOKEN, CURVE_TOKEN_CURVE);
        assertEq(game.ponsPoolTickSpacing(), 200);
        game.setStock(NVDA, true);
        game.setStock(TSLA, true);
        game.setStock(SPY, true);
        game.setStock(AAPL, true);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _newGame() internal returns (StockMine) {
        return new StockMine(60, 0.0001 ether, WETH, ROUTER, PONS_ESCROW, PONS_FACTORY, PONS_ROUTER, PONS_HOOK, POOL_MANAGER);
    }

    function _gameWithBurnReserve(address realToken, address realCurve) internal returns (StockMine) {
        return _gameWithBurnReserve(realToken, realCurve, 1 ether);
    }

    /// @dev A game bound to a real Pons launch, with `reserve` ETH waiting in its burn reserve.
    function _gameWithBurnReserve(address realToken, address realCurve, uint256 reserve) internal returns (StockMine g) {
        g = _newGame();
        g.setToken(realToken, realCurve);
        g.setStock(NVDA, true);
        uint8 w = uint8(uint256(keccak256(abi.encode(keccak256(abi.encode("l2-block", arb.number() + g.TARGET_DELAY())), g.currentRound(), address(g)))) % 25);
        uint256 round = g.currentRound();
        vm.prank(alice);
        g.deploy{value: 0.01 ether}(uint32(1 << w));
        (bool ok,) = address(g).call{value: reserve * 5}(""); // the burn slice is 20% of the pot
        assertTrue(ok);
        vm.warp(g.roundEndsAt(round));
        g.close(round);
        arb.roll(g.TARGET_DELAY() + 1);
        g.settle(round);
        g.closeEpoch(NVDA, 500, 1);
        assertEq(g.burnEth(), reserve);
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
        console2.log("NVDA bought with 0.112 ETH, after the 20% burn slice (1e18):", bought);
        assertEq(game.burnEth(), 0.028 ether);
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

        // alice buys the real token on its curve and stakes it
        vm.startPrank(alice);
        uint256 got0 = IPonsCurve(CURVE_TOKEN_CURVE).buy{value: 0.01 ether}(0.01 ether, 1, alice);
        IERC20(CURVE_TOKEN).approve(address(game), type(uint256).max);
        game.stake(got0);
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
            // only the rounding dust of the per-share accumulator may stay behind: at most staked / 1e18 wei
            // per distribution, a few millionths of a billionth of a share with millions of tokens staked
            assertLt(IERC20(list[i]).balanceOf(address(game)), 1e9);
        }
    }

    function test_fork_buybackOnARealPonsCurve() public {
        if (!vm.envOr("FORK", false)) vm.skip(true);
        (bool ok, bytes memory ret) = CURVE_TOKEN_CURVE.staticcall(abi.encodeWithSignature("graduated()"));
        if (!ok || abi.decode(ret, (bool))) vm.skip(true); // it graduated since this test was written

        StockMine g = _gameWithBurnReserve(CURVE_TOKEN, CURVE_TOKEN_CURVE);
        uint256 deadBefore = IERC20(CURVE_TOKEN).balanceOf(DEAD);
        g.buybackAndBurn(0.05 ether, 1);
        uint256 burned = IERC20(CURVE_TOKEN).balanceOf(DEAD) - deadBefore;
        console2.log("tokens bought on the curve with 0.05 ETH and burned (1e18):", burned);
        assertGt(burned, 0);
        assertEq(g.totalBurned(), burned);
        assertEq(IERC20(CURVE_TOKEN).balanceOf(address(g)), 0);
        assertEq(g.burnEth(), 0.95 ether);
    }

    function test_fork_buybackThatGraduatesARealCurve() public {
        if (!vm.envOr("FORK", false)) vm.skip(true);
        (bool ok, bytes memory ret) = CURVE_TOKEN_CURVE.staticcall(abi.encodeWithSignature("graduated()"));
        if (!ok || abi.decode(ret, (bool))) vm.skip(true);

        StockMine g = _gameWithBurnReserve(CURVE_TOKEN, CURVE_TOKEN_CURVE, 8 ether);
        uint256 potBefore = g.potEth();
        uint256 balBefore = address(g).balance;

        // far more than the curve can take: it sells out, keeps what it needs and refunds the rest
        g.buybackAndBurn(8 ether, 1);
        uint256 used = balBefore - address(g).balance;
        console2.log("ETH the curve used to graduate (1e18):", used);
        assertLt(used, 8 ether);
        assertEq(g.burnEth(), 8 ether - used); // the refund is still burn money
        assertEq(g.potEth(), potBefore);
        assertTrue(IPonsCurve(CURVE_TOKEN_CURVE).graduated());

        // the pool may not exist yet: the contract asks the factory for it, then swaps through the router
        uint256 deadBefore = IERC20(CURVE_TOKEN).balanceOf(DEAD);
        g.buybackAndBurn(0.05 ether, 1);
        assertGt(IERC20(CURVE_TOKEN).balanceOf(DEAD), deadBefore);
        assertEq(g.burnEth(), 8 ether - used - 0.05 ether);
    }

    function test_fork_buybackOnARealGraduatedPool() public {
        if (!vm.envOr("FORK", false)) vm.skip(true);

        StockMine g = _gameWithBurnReserve(GRAD_TOKEN, GRAD_TOKEN_CURVE);
        uint256 deadBefore = IERC20(GRAD_TOKEN).balanceOf(DEAD);
        g.buybackAndBurn(0.05 ether, 1);
        uint256 burned = IERC20(GRAD_TOKEN).balanceOf(DEAD) - deadBefore;
        console2.log("tokens bought on the v4 pool with 0.05 ETH and burned (1e18):", burned);
        assertGt(burned, 0);
        assertEq(g.totalBurned(), burned);
        assertEq(IERC20(GRAD_TOKEN).balanceOf(address(g)), 0);
        assertEq(g.burnEth(), 0.95 ether);
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
