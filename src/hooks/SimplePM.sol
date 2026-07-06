// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {BattleContext} from "../Structs.sol";
import {Ownable} from "../lib/Ownable.sol";

struct PMEntry {
    uint96 p0Shares;
    uint96 p1Shares;
    uint96 totalDeposits;
}

struct PMBalance {
    uint128 p0SharesBalance;
    uint128 p1SharesBalance;
}

contract SimplePM is Ownable {
    error TooLate(uint256 turnId);
    error GameNotOver(bytes32 battleKey);
    error InvalidBattle(bytes32 battleKey);
    error HasWinningShares(bytes32 battleKey);

    event sharesBought(bytes32 indexed battleKey, uint256 amount, bool isP0);

    uint256 public constant DENOM = 100;
    uint256 public constant LAST_TURN_TO_JOIN = 15;
    uint256 public constant FEE_MULTIPLIER_PERCENT_PER_TURN = 2;

    mapping(bytes32 battleKey => PMEntry) public marketForBattle;
    mapping(bytes32 battleKey => mapping(address => PMBalance)) public sharesPerUserForBattle;

    IEngine public immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
        _initializeOwner(msg.sender);
    }

    function buyShares(bytes32 battleKey, bool isP0) public payable {
        // Existence guard + executed turn come from the context. Under deferred PvP the executed turnId
        // is 0 while moves buffer, so the live turn adds the buffered count (getBufferedTurns.length) —
        // read separately to keep this cost off every per-turn getBattleContext caller.
        BattleContext memory ctx = ENGINE.getBattleContext(battleKey);
        if (ctx.startTimestamp == 0) {
            revert InvalidBattle(battleKey);
        }
        (, uint256[] memory bufferedTurns) = ENGINE.getBufferedTurns(battleKey);
        uint256 turnId = uint256(ctx.turnId) + bufferedTurns.length;
        if (turnId > LAST_TURN_TO_JOIN) {
            revert TooLate(turnId);
        }
        uint96 depositValue = uint96(msg.value);
        uint96 sharesToMint = uint96(depositValue * (DENOM - (turnId * FEE_MULTIPLIER_PERCENT_PER_TURN)) / DENOM);
        marketForBattle[battleKey].totalDeposits += depositValue;
        if (isP0) {
            marketForBattle[battleKey].p0Shares += sharesToMint;
            sharesPerUserForBattle[battleKey][msg.sender].p0SharesBalance += sharesToMint;
        } else {
            marketForBattle[battleKey].p1Shares += sharesToMint;
            sharesPerUserForBattle[battleKey][msg.sender].p1SharesBalance += sharesToMint;
        }
        emit sharesBought(battleKey, depositValue, isP0);
    }

    // Redeems each claimant's winning shares to that claimant, so anyone can relay a bulk claim for
    // holders who never manually claimed. Per-battle terms are hoisted out of the loop.
    function claimShares(bytes32 battleKey, address[] calldata claimants) public {
        address winner = ENGINE.getWinner(battleKey);
        if (winner == address(0)) {
            revert GameNotOver(battleKey);
        }
        bool isP0Winner = winner == ENGINE.getBattleContext(battleKey).p0;

        PMEntry storage marketDetails = marketForBattle[battleKey];
        uint256 totalDeposits = marketDetails.totalDeposits;
        uint256 totalWinningShares = isP0Winner ? marketDetails.p0Shares : marketDetails.p1Shares;

        for (uint256 i; i < claimants.length; i++) {
            address claimant = claimants[i];
            PMBalance storage balance = sharesPerUserForBattle[battleKey][claimant];
            uint256 sharesToRedeem = isP0Winner ? balance.p0SharesBalance : balance.p1SharesBalance;

            // Winning shares get redeemed; losing shares are worthless. Zero both before paying (CEI).
            balance.p0SharesBalance = 0;
            balance.p1SharesBalance = 0;

            // Skips zero-share claimants, which also dodges the 0/0 revert when nobody bet the winner.
            if (sharesToRedeem == 0) {
                continue;
            }
            uint256 redemptionAmount = totalDeposits * sharesToRedeem / totalWinningShares;
            if (redemptionAmount > 0) {
                (bool s,) = payable(claimant).call{value: redemptionAmount}("");
                if (!s) {
                    // Restore the winning balance so a rejecting recipient can retry, and skip the rest.
                    if (isP0Winner) {
                        balance.p0SharesBalance = uint128(sharesToRedeem);
                    } else {
                        balance.p1SharesBalance = uint128(sharesToRedeem);
                    }
                }
            }
        }
    }

    // Recovers a single battle's deposits, only when the winning side has no shares (nobody bet the
    // winner) so claimShares can never distribute the pot. Scoped to this battle's totalDeposits.
    function rescue(bytes32 battleKey) public onlyOwner {
        address winner = ENGINE.getWinner(battleKey);
        if (winner == address(0)) {
            revert GameNotOver(battleKey);
        }
        bool isP0Winner = winner == ENGINE.getBattleContext(battleKey).p0;
        PMEntry storage marketDetails = marketForBattle[battleKey];
        uint256 totalWinningShares = isP0Winner ? marketDetails.p0Shares : marketDetails.p1Shares;
        if (totalWinningShares != 0) {
            revert HasWinningShares(battleKey);
        }
        uint256 amount = marketDetails.totalDeposits;
        marketDetails.totalDeposits = 0;
        if (amount > 0) {
            (bool _s,) = payable(msg.sender).call{value: amount}("");
            (_s);
        }
    }
}
