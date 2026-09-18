// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StockMine} from "../src/StockMine.sol";
import {MockArbSys, MockERC20, MockRouter, MockEscrow, MockFactory} from "./Mocks.sol";

contract StockMineTest is Test {
    uint256 constant ROUND = 60;
    uint256 constant MIN = 0.0001 ether;

    StockMine game;
    MockArbSys arb = MockArbSys(address(100));
    MockERC20 token;
    MockERC20 nvda;
    MockERC20 tsla;
    MockRouter router;
    MockEscrow escrow;
    MockFactory factory;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");
    address weth = makeAddr("weth");

    function setUp() public {
        vm.etch(address(100), address(new MockArbSys()).code);
        arb.set(1_000_000);
        vm.warp(1_700_000_000);

        token = new MockERC20("Project", "PRJ");
        nvda = new MockERC20("NVIDIA", "NVDA");
        tsla = new MockERC20("Tesla", "TSLA");
        router = new MockRouter();
        escrow = new MockEscrow();
        factory = new MockFactory();

        game = new StockMine(ROUND, MIN, weth, address(router), address(escrow), address(factory));
        game.setStock(address(nvda), true);
        game.setKeeper(keeper);
        game.setToken(address(token));

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _bit(uint256 square) internal pure returns (uint32) {
        return uint32(1 << square);
    }

    /// @dev The square that wins `round` if it is closed at the current mock L2 block.
    function _predict(uint256 round) internal view returns (uint8) {
        bytes32 h = keccak256(abi.encode("l2-block", arb.number() + game.TARGET_DELAY()));
        return uint8(uint256(keccak256(abi.encode(h, round, address(game)))) % 25);
    }

    function _other(uint8 square) internal pure returns (uint8) {
        return (square + 1) % 25;
    }

    function _finish(uint256 round) internal {
        vm.warp(game.roundEndsAt(round));
        game.close(round);
        arb.roll(game.TARGET_DELAY() + 1);
        game.settle(round);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _deploy(address who, uint32 mask, uint256 value) internal {
        vm.prank(who);
        game.deploy{value: value}(mask);
    }

    // ------------------------------------------------------------------ deploy

    function test_deploy_splitsEquallyAndSendsDustToPot() public {
        _deploy(alice, _bit(0) | _bit(7) | _bit(24), 1 ether + 2);
        uint256 per = (1 ether + 2) / 3;
        uint256[25] memory totals = game.squareTotals(0);
        assertEq(totals[0], per);
        assertEq(totals[7], per);
        assertEq(totals[24], per);
        assertEq(totals[1], 0);
        (,,,, uint256 total,,) = game.rounds(0);
        assertEq(total, per * 3);
        assertEq(game.potEth(), 1 ether + 2 - per * 3);
        assertEq(game.deployedBy(0, alice)[7], per);
    }

    function test_deploy_rejectsBadInput() public {
        vm.startPrank(alice);
        vm.expectRevert(StockMine.BadMask.selector);
        game.deploy{value: 1 ether}(0);
        vm.expectRevert(StockMine.BadMask.selector);
        game.deploy{value: 1 ether}(uint32(1 << 25));
        vm.expectRevert(StockMine.BadAmount.selector);
        game.deploy{value: MIN * 2 - 1}(_bit(0) | _bit(1));
        vm.stopPrank();

        game.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(StockMine.Paused.selector);
        game.deploy{value: 1 ether}(_bit(0));
    }

    function test_deploy_goesToTheRoundOfTheMoment() public {
        _deploy(alice, _bit(3), 1 ether);
        vm.warp(block.timestamp + ROUND * 5 + 1);
        assertEq(game.currentRound(), 5);
        _deploy(alice, _bit(3), 2 ether);
        (,,,, uint256 t0,,) = game.rounds(0);
        (,,,, uint256 t5,,) = game.rounds(5);
        assertEq(t0, 1 ether);
        assertEq(t5, 2 ether);
    }

    // ------------------------------------------------------------------ draw

    function test_close_needsAFinishedNonEmptyRound() public {
        _deploy(alice, _bit(0), 1 ether);
        vm.expectRevert(StockMine.RoundNotOver.selector);
        game.close(0);

        vm.warp(game.roundEndsAt(1));
        vm.expectRevert(StockMine.RoundEmpty.selector);
        game.close(1);

        game.close(0);
        vm.expectRevert(StockMine.TargetStillValid.selector);
        game.close(0);
    }

    function test_settle_waitsForTheTargetBlock() public {
        _deploy(alice, _bit(0), 1 ether);
        vm.expectRevert(StockMine.RoundNotClosed.selector);
        game.settle(0);

        vm.warp(game.roundEndsAt(0));
        game.close(0);
        arb.roll(game.TARGET_DELAY());
        vm.expectRevert(StockMine.TargetNotReached.selector);
        game.settle(0);

        arb.roll(1);
        game.settle(0);
        vm.expectRevert(StockMine.RoundNotClosed.selector);
        game.settle(0);
        vm.expectRevert(StockMine.RoundNotOpen.selector);
        game.close(0);
    }

    function test_settle_expiredTargetIsRerolled() public {
        _deploy(alice, _bit(0), 1 ether);
        vm.warp(game.roundEndsAt(0));
        game.close(0);
        (,, uint64 firstTarget,,,,) = game.rounds(0);

        arb.roll(game.TARGET_DELAY() + game.HASH_WINDOW() + 1);
        vm.expectRevert(StockMine.TargetExpired.selector);
        game.settle(0);

        game.close(0);
        (,, uint64 secondTarget,,,,) = game.rounds(0);
        assertGt(secondTarget, firstTarget);
        arb.roll(game.TARGET_DELAY() + 1);
        game.settle(0);
    }

    function test_settle_lastBlockOfTheWindowStillWorks() public {
        _deploy(alice, _bit(0), 1 ether);
        vm.warp(game.roundEndsAt(0));
        game.close(0);
        arb.roll(game.TARGET_DELAY() + game.HASH_WINDOW());
        game.settle(0);
    }

    // ------------------------------------------------------------------ payouts

    function test_winnersShareTheLosersEthMinusTheCut() public {
        uint8 w = _predict(0);
        uint8 l = _other(w);
        _deploy(alice, _bit(w), 1 ether);
        _deploy(bob, _bit(w), 3 ether);
        _deploy(carol, _bit(l), 8 ether);
        _finish(0);

        (StockMine.RoundState state, uint8 winner,,, uint256 total, uint256 winnersStake, uint256 prize) = game.rounds(0);
        assertEq(uint8(state), uint8(StockMine.RoundState.Settled));
        assertEq(winner, w);
        assertEq(total, 12 ether);
        assertEq(winnersStake, 4 ether);
        assertEq(prize, 7.44 ether); // 8 ETH lost, 7% cut
        assertEq(game.potEth(), 0.56 ether);

        assertEq(game.claimable(0, alice), 1 ether + 1.86 ether);
        assertEq(game.claimable(0, bob), 3 ether + 5.58 ether);
        assertEq(game.claimable(0, carol), 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        game.claim(_one(0));
        assertEq(alice.balance - before, 2.86 ether);

        // a second claim pays nothing
        vm.prank(alice);
        game.claim(_one(0));
        assertEq(alice.balance - before, 2.86 ether);

        vm.prank(bob);
        game.claim(_one(0));
        vm.prank(carol);
        game.claim(_one(0));
        assertEq(address(game).balance, game.potEth());
    }

    function test_roundNobodyWonRollsOverToTheNextWinners() public {
        uint8 w0 = _predict(0);
        _deploy(alice, _bit(_other(w0)), 5 ether);
        _finish(0);
        assertEq(game.rollover(), 4.65 ether);
        assertEq(game.potEth(), 0.35 ether);
        assertEq(game.claimable(0, alice), 0);

        uint256 round = game.currentRound();
        uint8 w1 = _predict(round);
        _deploy(bob, _bit(w1), 1 ether);
        _finish(round);
        assertEq(game.rollover(), 0);
        assertEq(game.claimable(round, bob), 1 ether + 4.65 ether);
    }

    function test_claim_revertsOnUnsettledRound() public {
        _deploy(alice, _bit(0), 1 ether);
        vm.prank(alice);
        vm.expectRevert(StockMine.RoundNotSettled.selector);
        game.claim(_one(0));
    }

    function testFuzz_ethIsConserved(uint256 seed) public {
        address[5] memory players = [alice, bob, carol, makeAddr("dave"), makeAddr("erin")];
        uint256 deposited;
        for (uint256 i; i < players.length; ++i) {
            vm.deal(players[i], 1_000 ether);
            uint32 mask = uint32(uint256(keccak256(abi.encode(seed, i, "mask"))) % ((1 << 25) - 1)) + 1;
            uint256 value = 0.01 ether + (uint256(keccak256(abi.encode(seed, i, "value"))) % 50 ether);
            _deploy(players[i], mask, value);
            deposited += value;
        }
        _finish(0);

        uint256 paid;
        for (uint256 i; i < players.length; ++i) {
            uint256 before = players[i].balance;
            vm.prank(players[i]);
            game.claim(_one(0));
            paid += players[i].balance - before;
        }
        assertEq(address(game).balance, deposited - paid);
        uint256 accounted = game.potEth() + game.rollover();
        assertGe(address(game).balance, accounted);
        assertLt(address(game).balance - accounted, 25); // rounding dust only
    }

    // ------------------------------------------------------------------ epochs

    function test_closeEpoch_buysStockForMinersAndStakers() public {
        token.mint(carol, 1_000e18);
        vm.startPrank(carol);
        token.approve(address(game), type(uint256).max);
        game.stake(1_000e18);
        vm.stopPrank();

        uint8 w = _predict(0);
        _deploy(alice, _bit(w), 1 ether);
        _deploy(bob, _bit(w), 3 ether);
        _deploy(bob, _bit(_other(w)), 10 ether);
        _finish(0);
        assertEq(game.potEth(), 0.7 ether);

        // creator fees waiting in the Pons escrow
        escrow.credit{value: 2 ether}(address(game));

        vm.prank(keeper);
        game.closeEpoch(address(nvda), 500, 27e18);

        // 2.7 ETH at 10 NVDA per ETH, half to miners and half to stakers
        assertEq(game.epoch(), 1);
        assertEq(game.potEth(), 0);
        assertEq(game.epochStock(0), 13.5e18);
        assertEq(game.epochToken(0), address(nvda));
        assertEq(nvda.balanceOf(address(game)), 27e18);

        vm.prank(alice);
        game.claim(_one(0));
        vm.prank(bob);
        game.claim(_one(0));

        (, uint256 aliceOwed) = game.claimableStock(0, alice);
        assertEq(aliceOwed, 3.375e18);
        vm.prank(alice);
        game.claimStock(_one(0));
        vm.prank(bob);
        game.claimStock(_one(0));
        assertEq(nvda.balanceOf(alice), 3.375e18);
        assertEq(nvda.balanceOf(bob), 10.125e18);

        vm.prank(carol);
        game.claimStaking();
        assertEq(nvda.balanceOf(carol), 13.5e18);
        assertEq(nvda.balanceOf(address(game)), 0);
    }

    function test_claimStock_paysRoundsClaimedLater() public {
        uint8 w = _predict(0);
        _deploy(alice, _bit(w), 1 ether);
        _deploy(bob, _bit(_other(w)), 10 ether);
        _finish(0);

        uint256 round = game.currentRound();
        w = _predict(round);
        _deploy(alice, _bit(w), 1 ether);
        _deploy(bob, _bit(_other(w)), 10 ether);
        _finish(round);

        vm.prank(keeper);
        game.closeEpoch(address(nvda), 500, 0);
        // nobody staked: the miners get all 1.4 ETH worth of stock
        assertEq(game.epochStock(0), 14e18);

        vm.startPrank(alice);
        game.claim(_one(0));
        game.claimStock(_one(0));
        assertEq(nvda.balanceOf(alice), 7e18);
        game.claimStock(_one(0));
        assertEq(nvda.balanceOf(alice), 7e18);
        game.claim(_one(round));
        game.claimStock(_one(0));
        assertEq(nvda.balanceOf(alice), 14e18);
        vm.stopPrank();
    }

    function test_closeEpoch_guards() public {
        vm.prank(alice);
        vm.expectRevert(StockMine.NotKeeper.selector);
        game.closeEpoch(address(nvda), 500, 0);

        vm.startPrank(keeper);
        vm.expectRevert(StockMine.StockNotAllowed.selector);
        game.closeEpoch(address(tsla), 500, 0);
        vm.expectRevert(StockMine.NothingToDistribute.selector);
        game.closeEpoch(address(nvda), 500, 0);
        vm.stopPrank();

        // a pot but nobody to give it to: it stays put
        (bool ok,) = address(game).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(keeper);
        vm.expectRevert(StockMine.NothingToDistribute.selector);
        game.closeEpoch(address(nvda), 500, 0);
        assertEq(game.potEth(), 1 ether);
    }

    function test_closeEpoch_slippageGuard() public {
        uint8 w = _predict(0);
        _deploy(alice, _bit(w), 1 ether);
        _deploy(bob, _bit(_other(w)), 10 ether);
        _finish(0);

        vm.prank(keeper);
        vm.expectRevert(bytes("Too little received"));
        game.closeEpoch(address(nvda), 500, 7e18 + 1);
        assertEq(game.potEth(), 0.7 ether);
        assertEq(game.epoch(), 0);
    }

    function test_claimStock_rejectsOpenEpoch() public {
        vm.prank(alice);
        vm.expectRevert(StockMine.BadParam.selector);
        game.claimStock(_one(0));
    }

    // ------------------------------------------------------------------ staking

    function test_staking_sharesByStakeAndOnlyFromWhenStaked() public {
        game.setStock(address(tsla), true);
        token.mint(alice, 100e18);
        token.mint(bob, 300e18);
        vm.prank(alice);
        token.approve(address(game), type(uint256).max);
        vm.prank(bob);
        token.approve(address(game), type(uint256).max);

        vm.prank(alice);
        game.stake(100e18);

        (bool ok,) = address(game).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(keeper);
        game.closeEpoch(address(nvda), 500, 0); // 10 NVDA, all to alice

        vm.prank(bob);
        game.stake(300e18);

        (ok,) = address(game).call{value: 4 ether}("");
        assertTrue(ok);
        vm.prank(keeper);
        game.closeEpoch(address(tsla), 3000, 0); // 40 TSLA, 1/4 alice, 3/4 bob

        (address[] memory list, uint256[] memory owed) = game.pendingStaking(alice);
        assertEq(list.length, 2);
        assertEq(owed[0], 10e18);
        assertEq(owed[1], 10e18);

        vm.prank(alice);
        game.claimStaking();
        vm.prank(bob);
        game.claimStaking();
        assertEq(nvda.balanceOf(alice), 10e18);
        assertEq(nvda.balanceOf(bob), 0);
        assertEq(tsla.balanceOf(alice), 10e18);
        assertEq(tsla.balanceOf(bob), 30e18);
    }

    function test_unstake_isLockedAfterEachStake() public {
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.approve(address(game), type(uint256).max);
        game.stake(60e18);

        vm.expectRevert(StockMine.StakeLocked.selector);
        game.unstake(60e18);

        vm.warp(block.timestamp + 3 days);
        game.stake(40e18); // restarts the lock
        vm.expectRevert(StockMine.StakeLocked.selector);
        game.unstake(1);

        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(StockMine.BadAmount.selector);
        game.unstake(100e18 + 1);
        game.unstake(100e18);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(game.totalStaked(), 0);
    }

    function test_unstake_keepsRewardsEarnedBefore() public {
        token.mint(alice, 100e18);
        vm.startPrank(alice);
        token.approve(address(game), type(uint256).max);
        game.stake(100e18);
        vm.stopPrank();

        (bool ok,) = address(game).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(keeper);
        game.closeEpoch(address(nvda), 500, 0);

        vm.warp(block.timestamp + 3 days);
        vm.startPrank(alice);
        game.unstake(100e18);
        game.claimStaking();
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 10e18);
    }

    // ------------------------------------------------------------------ fees and admin

    function test_harvest_pullsPonsFeesIntoThePot() public {
        escrow.credit{value: 1.5 ether}(address(game));
        vm.prank(alice);
        game.harvest();
        assertEq(game.potEth(), 1.5 ether);
        game.harvest(); // nothing owed: no-op
        assertEq(game.potEth(), 1.5 ether);
    }

    function test_admin_boundsAndRoles() public {
        assertEq(game.cutBps(), 700);
        vm.expectRevert(StockMine.BadParam.selector);
        game.setParams(1_501, 5_000, 1 days);
        vm.expectRevert(StockMine.BadParam.selector);
        game.setParams(1_000, 1_999, 1 days);
        vm.expectRevert(StockMine.BadParam.selector);
        game.setParams(1_000, 8_001, 1 days);
        vm.expectRevert(StockMine.BadParam.selector);
        game.setParams(1_000, 5_000, 14 days + 1);
        game.setParams(500, 6_000, 1 days);
        assertEq(game.cutBps(), 500);

        vm.expectRevert(StockMine.TokenAlreadySet.selector);
        game.setToken(address(tsla));

        vm.startPrank(alice);
        vm.expectRevert(StockMine.NotOwner.selector);
        game.setParams(0, 5_000, 0);
        vm.expectRevert(StockMine.NotOwner.selector);
        game.setStock(address(tsla), true);
        vm.expectRevert(StockMine.NotOwner.selector);
        game.migrateFees(alice);
        vm.stopPrank();

        game.migrateFees(bob);
        assertEq(factory.lastToken(), address(token));
        assertEq(factory.lastRecipient(), bob);
    }

    function test_setStock_capsTheList() public {
        for (uint256 i; i < 15; ++i) {
            game.setStock(address(uint160(0x1000 + i)), true);
        }
        assertEq(game.stocksCount(), 16);
        vm.expectRevert(StockMine.BadParam.selector);
        game.setStock(address(0x9999), true);
        // turning one off and on again does not grow the list
        game.setStock(address(nvda), false);
        assertFalse(game.stockAllowed(address(nvda)));
        game.setStock(address(nvda), true);
        assertEq(game.stocksCount(), 16);
    }

    function test_ownership_isTwoStep() public {
        game.transferOwnership(alice);
        assertEq(game.owner(), address(this));
        vm.prank(bob);
        vm.expectRevert(StockMine.NotOwner.selector);
        game.acceptOwnership();
        vm.prank(alice);
        game.acceptOwnership();
        assertEq(game.owner(), alice);
    }

    receive() external payable {}
}
