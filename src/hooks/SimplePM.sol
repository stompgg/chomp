// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {BattleContext} from "../Structs.sol";

struct PMEntry {
    uint96 p0Shares;
    uint96 p1Shares;
    uint96 totalDeposits;
}

struct PMBalance {
    uint128 p0SharesBalance;
    uint128 p1SharesBalance;
}

contract SimplePM {
    error TooLate(uint256 turnId);
    error GameNotOver(bytes32 battleKey);
    error InvalidBattle(bytes32 battleKey);

    // Carries buyer + post-trade totals so consumers (belch/munch) never need a follow-up read.
    // Non-indexed args are hand-packed into two words (ABI encoding would pad every field to 32 bytes):
    //   word0: bits [0..95] sharesMinted | bits [96..191] p0Shares | bit 192 isP0
    //   word1: bits [0..95] p1Shares    | bits [96..191] totalDeposits
    // The deposit amount is omitted deliberately — it is recoverable as the delta of totalDeposits.
    event sharesBought(bytes32 indexed battleKey, address indexed buyer, uint256 word0, uint256 word1);
    event sharesClaimed(bytes32 indexed battleKey, address indexed claimant, uint256 amount);

    uint256 public constant DENOM = 100;
    uint256 public constant LAST_TURN_TO_JOIN = 15;
    uint256 public constant FEE_MULTIPLIER_PERCENT_PER_TURN = 2;

    mapping(bytes32 battleKey => PMEntry) public marketForBattle;
    mapping(bytes32 battleKey => mapping(address => PMBalance)) public sharesPerUserForBattle;

    IEngine public immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
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
        PMEntry storage market = marketForBattle[battleKey];
        market.totalDeposits += depositValue;
        if (isP0) {
            market.p0Shares += sharesToMint;
            sharesPerUserForBattle[battleKey][msg.sender].p0SharesBalance += sharesToMint;
        } else {
            market.p1Shares += sharesToMint;
            sharesPerUserForBattle[battleKey][msg.sender].p1SharesBalance += sharesToMint;
        }
        emit sharesBought(
            battleKey,
            msg.sender,
            uint256(sharesToMint) | (uint256(market.p0Shares) << 96) | (isP0 ? uint256(1) << 192 : 0),
            uint256(market.p1Shares) | (uint256(market.totalDeposits) << 96)
        );
    }

    // Relayable bulk redemption to each holder; per-battle terms hoisted out of the loop.
    function claimShares(bytes32 battleKey, address[] calldata claimants) public {
        address winner = ENGINE.getWinner(battleKey);
        if (winner == address(0)) {
            revert GameNotOver(battleKey);
        }
        bool isP0Winner = winner == ENGINE.getBattleContext(battleKey).p0;

        PMEntry storage marketDetails = marketForBattle[battleKey];
        uint256 totalDeposits = marketDetails.totalDeposits;
        // Redeem the winning side; if nobody backed the winner, refund the side that did bet pro-rata.
        uint256 winningShares = isP0Winner ? marketDetails.p0Shares : marketDetails.p1Shares;
        bool redeemP0 = winningShares == 0 ? !isP0Winner : isP0Winner;
        uint256 totalRedeemableShares = redeemP0 ? marketDetails.p0Shares : marketDetails.p1Shares;

        for (uint256 i; i < claimants.length; i++) {
            address claimant = claimants[i];
            PMBalance storage balance = sharesPerUserForBattle[battleKey][claimant];
            uint256 sharesToRedeem = redeemP0 ? balance.p0SharesBalance : balance.p1SharesBalance;

            // Redeemed and forfeited shares alike are cleared; zero both before paying (CEI).
            balance.p0SharesBalance = 0;
            balance.p1SharesBalance = 0;

            if (sharesToRedeem == 0) {
                continue;
            }
            uint256 redemptionAmount = totalDeposits * sharesToRedeem / totalRedeemableShares;
            if (redemptionAmount > 0) {
                (bool s,) = payable(claimant).call{value: redemptionAmount}("");
                if (!s) {
                    // Restore the redeemed balance so a rejecting recipient can retry, and skip the rest.
                    if (redeemP0) {
                        balance.p0SharesBalance = uint128(sharesToRedeem);
                    } else {
                        balance.p1SharesBalance = uint128(sharesToRedeem);
                    }
                } else {
                    emit sharesClaimed(battleKey, claimant, redemptionAmount);
                }
            }
        }
    }
}
