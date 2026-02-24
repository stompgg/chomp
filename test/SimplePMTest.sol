// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SimplePM, PMEntry, PMBalance} from "../src/hooks/SimplePM.sol";
import {IEngine} from "../src/IEngine.sol";
import {MockSimplePMEngine} from "./mocks/MockSimplePMEngine.sol";

contract ReentrantClaimer {
    SimplePM public pm;
    bytes32 public battleKey;
    bool public shouldReenter;

    constructor(SimplePM _pm) {
        pm = _pm;
    }

    function setup(bytes32 _battleKey, bool _shouldReenter) external {
        battleKey = _battleKey;
        shouldReenter = _shouldReenter;
    }

    function claim() external {
        pm.claimShares(battleKey);
    }

    function buySharesOnBehalf(bytes32 _battleKey, bool isP0) external payable {
        pm.buyShares{value: msg.value}(_battleKey, isP0);
    }

    receive() external payable {
        if (shouldReenter) {
            shouldReenter = false;
            pm.claimShares(battleKey);
        }
    }
}

contract ReentrantBuyer {
    SimplePM public pm;
    bytes32 public battleKey;
    bool public shouldReenter;

    constructor(SimplePM _pm) {
        pm = _pm;
    }

    function setup(bytes32 _battleKey, bool _shouldReenter) external {
        battleKey = _battleKey;
        shouldReenter = _shouldReenter;
    }

    function buySharesOnBehalf(bytes32 _battleKey, bool isP0) external payable {
        pm.buyShares{value: msg.value}(_battleKey, isP0);
    }

    function claim() external {
        pm.claimShares(battleKey);
    }

    receive() external payable {
        if (shouldReenter) {
            shouldReenter = false;
            pm.buyShares{value: msg.value}(battleKey, true);
        }
    }
}

contract SimplePMTest is Test {
    SimplePM public pm;
    MockSimplePMEngine public mockEngine;

    bytes32 constant BATTLE_KEY = bytes32(uint256(1));

    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);
    address constant CHARLIE = address(0x3);
    address constant P0 = address(0xA0);
    address constant P1 = address(0xB0);

    function setUp() public {
        mockEngine = new MockSimplePMEngine();
        pm = new SimplePM(IEngine(address(mockEngine)));

        // Default: valid battle at turn 0, p0=P0, p1=P1, no winner yet
        mockEngine.setStartTimestamp(BATTLE_KEY, 1);
        mockEngine.setTurnId(BATTLE_KEY, 0);
        mockEngine.setPlayers(BATTLE_KEY, P0, P1);

        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        vm.deal(CHARLIE, 100 ether);
    }

    // =========================================================================
    // Group 1: buyShares — Basic Mechanics
    // =========================================================================

    function test_T1_1_BuySharesTurn0FullSharesMinted() public {
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        (uint96 p0Shares, uint96 p1Shares, uint96 totalDeposits) = pm.marketForBattle(BATTLE_KEY);
        assertEq(p0Shares, 1 ether);
        assertEq(p1Shares, 0);
        assertEq(totalDeposits, 1 ether);

        (uint128 p0Balance, uint128 p1Balance) = pm.sharesPerUserForBattle(BATTLE_KEY, ALICE);
        assertEq(p0Balance, 1 ether);
        assertEq(p1Balance, 0);
    }

    function test_T1_2_BuySharesForP1() public {
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);

        (uint96 p0Shares, uint96 p1Shares, uint96 totalDeposits) = pm.marketForBattle(BATTLE_KEY);
        assertEq(p0Shares, 0);
        assertEq(p1Shares, 1 ether);
        assertEq(totalDeposits, 1 ether);

        (uint128 p0Balance, uint128 p1Balance) = pm.sharesPerUserForBattle(BATTLE_KEY, ALICE);
        assertEq(p0Balance, 0);
        assertEq(p1Balance, 1 ether);
    }

    function test_T1_3_FeeScalesWithTurnNumber() public {
        // Turn 0: 100% shares
        mockEngine.setTurnId(BATTLE_KEY, 0);
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
        (uint128 p0Balance,) = pm.sharesPerUserForBattle(BATTLE_KEY, ALICE);
        assertEq(p0Balance, 1 ether);

        // Turn 5: 90% shares (use a different battle key per turn to isolate)
        bytes32 key5 = bytes32(uint256(5));
        mockEngine.setStartTimestamp(key5, 1);
        mockEngine.setTurnId(key5, 5);
        vm.prank(BOB);
        pm.buyShares{value: 1 ether}(key5, true);
        (uint128 bobP0,) = pm.sharesPerUserForBattle(key5, BOB);
        assertEq(bobP0, 0.9 ether);

        // Turn 10: 80% shares
        bytes32 key10 = bytes32(uint256(10));
        mockEngine.setStartTimestamp(key10, 1);
        mockEngine.setTurnId(key10, 10);
        vm.prank(CHARLIE);
        pm.buyShares{value: 1 ether}(key10, true);
        (uint128 charlieP0,) = pm.sharesPerUserForBattle(key10, CHARLIE);
        assertEq(charlieP0, 0.8 ether);

        // Turn 15: 70% shares
        bytes32 key15 = bytes32(uint256(15));
        mockEngine.setStartTimestamp(key15, 1);
        mockEngine.setTurnId(key15, 15);
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(key15, true);
        (uint128 aliceP0_15,) = pm.sharesPerUserForBattle(key15, ALICE);
        assertEq(aliceP0_15, 0.7 ether);
    }

    function test_T1_4_MultipleBuysAccumulate() public {
        vm.startPrank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
        vm.stopPrank();

        (uint96 p0Shares,, uint96 totalDeposits) = pm.marketForBattle(BATTLE_KEY);
        assertEq(p0Shares, 2 ether);
        assertEq(totalDeposits, 2 ether);

        (uint128 p0Balance,) = pm.sharesPerUserForBattle(BATTLE_KEY, ALICE);
        assertEq(p0Balance, 2 ether);
    }

    function test_T1_5_UserBuysBothSides() public {
        vm.startPrank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);
        vm.stopPrank();

        (uint96 p0Shares, uint96 p1Shares, uint96 totalDeposits) = pm.marketForBattle(BATTLE_KEY);
        assertEq(p0Shares, 1 ether);
        assertEq(p1Shares, 1 ether);
        assertEq(totalDeposits, 2 ether);

        (uint128 p0Balance, uint128 p1Balance) = pm.sharesPerUserForBattle(BATTLE_KEY, ALICE);
        assertEq(p0Balance, 1 ether);
        assertEq(p1Balance, 1 ether);
    }

    // =========================================================================
    // Group 2: buyShares — Revert Conditions
    // =========================================================================

    function test_T2_1_RevertAtTurn16() public {
        mockEngine.setTurnId(BATTLE_KEY, 16);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SimplePM.TooLate.selector, 16));
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
    }

    function test_T2_2_RevertAtTurn100() public {
        mockEngine.setTurnId(BATTLE_KEY, 100);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SimplePM.TooLate.selector, 100));
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
    }

    function test_T2_3_DoesNotRevertAtTurn15() public {
        mockEngine.setTurnId(BATTLE_KEY, 15);
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        (uint96 p0Shares,,) = pm.marketForBattle(BATTLE_KEY);
        assertEq(p0Shares, 0.7 ether);
    }

    function test_T2_4_RevertIfBattleNotStarted() public {
        bytes32 fakeBattle = bytes32(uint256(999));
        // startTimestamp defaults to 0 (not set)
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SimplePM.InvalidBattle.selector, fakeBattle));
        pm.buyShares{value: 1 ether}(fakeBattle, true);
    }

    // =========================================================================
    // Group 3: claimShares — Happy Path
    // =========================================================================

    function test_T3_1_SoloBettorClaimsEntirePool() public {
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        // P0 wins
        mockEngine.setWinner(BATTLE_KEY, P0);

        uint256 balanceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);

        assertEq(ALICE.balance - balanceBefore, 1 ether);
        assertEq(address(pm).balance, 0);
    }

    function test_T3_2_TwoBettorsOppositeSidesWinnerTakesAll() public {
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
        vm.prank(BOB);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);

        // P0 wins
        mockEngine.setWinner(BATTLE_KEY, P0);

        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        assertEq(ALICE.balance - aliceBefore, 2 ether);

        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        pm.claimShares(BATTLE_KEY);
        assertEq(BOB.balance - bobBefore, 0);

        assertEq(address(pm).balance, 0);
    }

    function test_T3_3_TwoBettorsSameSideProportionalSplit() public {
        vm.prank(ALICE);
        pm.buyShares{value: 2 ether}(BATTLE_KEY, true);
        vm.prank(BOB);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        // P0 wins
        mockEngine.setWinner(BATTLE_KEY, P0);

        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        assertEq(ALICE.balance - aliceBefore, 2 ether);

        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        pm.claimShares(BATTLE_KEY);
        assertEq(BOB.balance - bobBefore, 1 ether);
    }

    function test_T3_4_EarlyVsLateBettorEarlyGetsMore() public {
        // Alice bets at turn 0: 1 ETH → 1e18 shares
        mockEngine.setTurnId(BATTLE_KEY, 0);
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        // Bob bets at turn 10: 1 ETH → 0.8e18 shares
        mockEngine.setTurnId(BATTLE_KEY, 10);
        vm.prank(BOB);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        // P0 wins. Total deposits = 2 ETH. Total p0 shares = 1.8e18.
        mockEngine.setWinner(BATTLE_KEY, P0);

        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        uint256 alicePayout = ALICE.balance - aliceBefore;

        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        pm.claimShares(BATTLE_KEY);
        uint256 bobPayout = BOB.balance - bobBefore;

        // Total p0 shares = 1e18 + 0.8e18 = 1.8e18
        // Alice: 2e18 * 1e18 / 1.8e18 = 1.111...e18
        // Bob:   2e18 * 0.8e18 / 1.8e18 = 0.888...e18
        uint256 totalP0Shares = 1 ether + 0.8 ether;
        assertGt(alicePayout, bobPayout);
        assertEq(alicePayout, 2 ether * 1 ether / totalP0Shares);
        assertEq(bobPayout, 2 ether * 0.8 ether / totalP0Shares);
        assertLe(alicePayout + bobPayout, 2 ether);
    }

    function test_T3_5_P1WinsScenario() public {
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);

        // P1 wins
        mockEngine.setWinner(BATTLE_KEY, P1);

        uint256 balanceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        assertEq(ALICE.balance - balanceBefore, 1 ether);
    }

    // =========================================================================
    // Group 4: claimShares — Edge Cases
    // =========================================================================

    function test_T4_1_RevertIfGameNotOver() public {
        // Winner defaults to address(0)
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SimplePM.GameNotOver.selector, BATTLE_KEY));
        pm.claimShares(BATTLE_KEY);
    }

    function test_T4_2_DoubleClaimReturnsNothing() public {
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        mockEngine.setWinner(BATTLE_KEY, P0);

        vm.startPrank(ALICE);
        pm.claimShares(BATTLE_KEY);
        uint256 balanceAfterFirst = ALICE.balance;

        pm.claimShares(BATTLE_KEY);
        assertEq(ALICE.balance, balanceAfterFirst);
        vm.stopPrank();
    }

    function test_T4_3_UserBetOnLosingSideOnly() public {
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);

        // Someone must bet on winning side to avoid div-by-zero
        vm.prank(BOB);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        // P0 wins, Alice bet on P1
        mockEngine.setWinner(BATTLE_KEY, P0);

        uint256 balanceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        assertEq(ALICE.balance - balanceBefore, 0);

        // Shares are zeroed
        (uint128 p0Balance, uint128 p1Balance) = pm.sharesPerUserForBattle(BATTLE_KEY, ALICE);
        assertEq(p0Balance, 0);
        assertEq(p1Balance, 0);
    }

    function test_T4_4_UserBetBothSidesOnlyWinningSidePays() public {
        vm.startPrank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);
        vm.stopPrank();

        // P0 wins. Total deposits = 2 ETH. Total p0 shares = 1 ETH.
        mockEngine.setWinner(BATTLE_KEY, P0);

        uint256 balanceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        // Payout = 2e18 * 1e18 / 1e18 = 2 ETH (all deposits, since Alice is the only p0 bettor)
        assertEq(ALICE.balance - balanceBefore, 2 ether);

        // Both balances zeroed
        (uint128 p0Balance, uint128 p1Balance) = pm.sharesPerUserForBattle(BATTLE_KEY, ALICE);
        assertEq(p0Balance, 0);
        assertEq(p1Balance, 0);
    }

    function test_T4_5_NobodyBetOnWinningSideDivByZero() public {
        // Only bet on P1
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);

        // P0 wins, but nobody bet on P0 → totalWinningShares = 0
        mockEngine.setWinner(BATTLE_KEY, P0);

        // Division by zero reverts
        vm.prank(ALICE);
        vm.expectRevert();
        pm.claimShares(BATTLE_KEY);
    }

    function test_T4_6_RevertIfBattleNotStarted() public {
        bytes32 fakeBattle = bytes32(uint256(999));
        // startTimestamp is 0 by default → getWinner returns address(0)
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SimplePM.GameNotOver.selector, fakeBattle));
        pm.claimShares(fakeBattle);
    }

    function test_T4_7_RoundingDust() public {
        // 3 users bet unequal amounts: 1 ETH, 2 ETH, 3 ETH on P0
        // Plus 1 ETH from losing side
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
        vm.prank(BOB);
        pm.buyShares{value: 2 ether}(BATTLE_KEY, true);
        vm.prank(CHARLIE);
        pm.buyShares{value: 3 ether}(BATTLE_KEY, true);

        // Add losing side deposit to make the pool interesting
        address loser = address(0x4);
        vm.deal(loser, 100 ether);
        vm.prank(loser);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);

        // P0 wins. Total deposits = 7 ETH. Total p0 shares = 6 ETH.
        mockEngine.setWinner(BATTLE_KEY, P0);

        uint256 aliceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        uint256 alicePayout = ALICE.balance - aliceBefore;

        uint256 bobBefore = BOB.balance;
        vm.prank(BOB);
        pm.claimShares(BATTLE_KEY);
        uint256 bobPayout = BOB.balance - bobBefore;

        uint256 charlieBefore = CHARLIE.balance;
        vm.prank(CHARLIE);
        pm.claimShares(BATTLE_KEY);
        uint256 charliePayout = CHARLIE.balance - charlieBefore;

        // Alice: 7e18 * 1e18 / 6e18 = 1.166...e18
        // Bob:   7e18 * 2e18 / 6e18 = 2.333...e18
        // Charlie: 7e18 * 3e18 / 6e18 = 3.5e18
        // Total payouts ≤ 7 ETH
        assertLe(alicePayout + bobPayout + charliePayout, 7 ether);
        assertGe(alicePayout + bobPayout + charliePayout, 7 ether - 3); // at most a few wei of dust
    }

    function test_T4_8_UserWithZeroSharesClaims() public {
        // Someone else bets so we don't get div-by-zero
        vm.prank(BOB);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);

        mockEngine.setWinner(BATTLE_KEY, P0);

        // Alice never bought shares
        uint256 balanceBefore = ALICE.balance;
        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        assertEq(ALICE.balance - balanceBefore, 0);
    }

    // =========================================================================
    // Group 5: ETH Accounting Invariants
    // =========================================================================

    function test_T5_1_TotalPayoutsNeverExceedContractBalance() public {
        vm.prank(ALICE);
        pm.buyShares{value: 3 ether}(BATTLE_KEY, true);
        vm.prank(BOB);
        pm.buyShares{value: 2 ether}(BATTLE_KEY, true);
        vm.prank(CHARLIE);
        pm.buyShares{value: 5 ether}(BATTLE_KEY, false);

        mockEngine.setWinner(BATTLE_KEY, P0);

        uint256 contractBalanceBefore = address(pm).balance;
        assertEq(contractBalanceBefore, 10 ether);

        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);
        vm.prank(BOB);
        pm.claimShares(BATTLE_KEY);

        // Contract balance should never go negative (i.e., ≥ 0)
        assertGe(address(pm).balance, 0);
    }

    function test_T5_2_LosingSideDepositsStayInContract() public {
        vm.prank(ALICE);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, true);
        vm.prank(BOB);
        pm.buyShares{value: 4 ether}(BATTLE_KEY, false);

        // P0 wins. Alice is the only winner.
        mockEngine.setWinner(BATTLE_KEY, P0);

        vm.prank(ALICE);
        pm.claimShares(BATTLE_KEY);

        // Alice gets all 5 ETH (sole winner with all p0 shares)
        // 5e18 * 1e18 / 1e18 = 5 ETH
        assertEq(address(pm).balance, 0);
    }

    // =========================================================================
    // Group 6: Reentrancy
    // =========================================================================

    function test_T6_1_ReentrantClaimSharesIsHarmless() public {
        ReentrantClaimer attacker = new ReentrantClaimer(pm);
        vm.deal(address(attacker), 100 ether);

        // Attacker buys shares
        attacker.buySharesOnBehalf{value: 1 ether}(BATTLE_KEY, true);

        // Bob also bets on losing side
        vm.prank(BOB);
        pm.buyShares{value: 1 ether}(BATTLE_KEY, false);

        mockEngine.setWinner(BATTLE_KEY, P0);

        // Setup reentrant claim
        attacker.setup(BATTLE_KEY, true);

        uint256 balanceBefore = address(attacker).balance;
        attacker.claim();
        uint256 payout = address(attacker).balance - balanceBefore;

        // Should only get paid once: 2 ETH total pool, attacker has all p0 shares
        assertEq(payout, 2 ether);
    }

    function test_T6_2_ReentrantBuySharesDuringClaim() public {
        ReentrantBuyer attacker = new ReentrantBuyer(pm);
        vm.deal(address(attacker), 100 ether);

        // Attacker buys shares
        attacker.buySharesOnBehalf{value: 1 ether}(BATTLE_KEY, true);

        mockEngine.setWinner(BATTLE_KEY, P0);

        // Setup: on receiving ETH from claim, buy more shares
        attacker.setup(BATTLE_KEY, true);

        // This should not revert — the reentrant buy during claim is benign
        // (though buying shares after game is over is a bit silly, it doesn't break accounting)
        attacker.claim();
    }

    // =========================================================================
    // Group 7: Owner Rescue
    // =========================================================================

    function test_T7_1_OwnerRescuesWhenNobodyBetOnWinningSide() public {
        // Only bet on P1
        vm.prank(ALICE);
        pm.buyShares{value: 5 ether}(BATTLE_KEY, false);

        // P0 wins — nobody bet on P0, so funds are stuck
        mockEngine.setWinner(BATTLE_KEY, P0);

        // Owner (this test contract, the deployer) rescues
        uint256 ownerBefore = address(this).balance;
        pm.rescue(BATTLE_KEY);
        assertEq(address(this).balance - ownerBefore, 5 ether);
        assertEq(address(pm).balance, 0);
    }

    function test_T7_2_RescueRevertsIfGameNotOver() public {
        vm.expectRevert(abi.encodeWithSelector(SimplePM.GameNotOver.selector, BATTLE_KEY));
        pm.rescue(BATTLE_KEY);
    }

    function test_T7_3_NonOwnerCannotRescue() public {
        mockEngine.setWinner(BATTLE_KEY, P0);

        vm.prank(ALICE);
        vm.expectRevert();
        pm.rescue(BATTLE_KEY);
    }

    // Allow this contract to receive ETH (for rescue)
    receive() external payable {}
}
