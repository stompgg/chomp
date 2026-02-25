// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
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

    function buyShares(bytes32 battleKey, bool isP0) payable public {
        if (ENGINE.getStartTimestamp(battleKey) == 0) {
            revert InvalidBattle(battleKey);
        }
        uint256 turnId = ENGINE.getTurnIdForBattleState(battleKey);
        if (turnId > LAST_TURN_TO_JOIN) {
            revert TooLate(turnId);
        }
        uint96 depositValue = uint96(msg.value);
        uint96 sharesToMint = uint96(depositValue * (DENOM - (turnId * FEE_MULTIPLIER_PERCENT_PER_TURN)) / DENOM);
        marketForBattle[battleKey].totalDeposits += depositValue;
        if (isP0) {
            marketForBattle[battleKey].p0Shares += sharesToMint;
            sharesPerUserForBattle[battleKey][msg.sender].p0SharesBalance += sharesToMint;
        }
        else {
            marketForBattle[battleKey].p1Shares += sharesToMint;
            sharesPerUserForBattle[battleKey][msg.sender].p1SharesBalance += sharesToMint;
        }
        emit sharesBought(battleKey, depositValue, isP0);
    }

    function claimShares(bytes32 battleKey) public {
        address winner = ENGINE.getWinner(battleKey);
        if (winner == address(0)) {
            revert GameNotOver(battleKey);
        }
        address[] memory players = ENGINE.getPlayersForBattle(battleKey);
        bool isP0Winner = winner == players[0];

        PMEntry storage marketDetails = marketForBattle[battleKey];
        uint256 sharesToRedeem = sharesPerUserForBattle[battleKey][msg.sender].p0SharesBalance;
        uint256 totalWinningShares = marketForBattle[battleKey].p0Shares;
        if (! isP0Winner) {
            sharesToRedeem = sharesPerUserForBattle[battleKey][msg.sender].p1SharesBalance;
            totalWinningShares = marketForBattle[battleKey].p1Shares;
        }
        sharesPerUserForBattle[battleKey][msg.sender].p0SharesBalance = 0;
        sharesPerUserForBattle[battleKey][msg.sender].p1SharesBalance = 0;
        uint256 redemptionAmount = marketDetails.totalDeposits * sharesToRedeem / totalWinningShares;
        if (redemptionAmount > 0) {
            (bool _s,) = payable(msg.sender).call{value: redemptionAmount}("");
            (_s);
        }
    }

    function rescue(bytes32 battleKey) public onlyOwner {
        address winner = ENGINE.getWinner(battleKey);
        if (winner == address(0)) {
            revert GameNotOver(battleKey);
        }
        uint256 remaining = address(this).balance;
        if (remaining > 0) {
            (bool _s,) = payable(msg.sender).call{value: remaining}("");
            (_s);
        }
    }
}