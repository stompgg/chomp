// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Ownable} from "../lib/Ownable.sol";
import {IGachaPointsAssigner} from "./IGachaPointsAssigner.sol";

/// @notice Single-slot packed per-player profile + owner-managed assigner allowlist.
///
/// `playerData[address]` bit layout:
///   bit 255         : bonusAwarded (first-game-ever bonus has been awarded)
///   bit 254         : isWhitelistedAsOpponent (CPU flag)
///   bit 253         : isHardCpu (only meaningful when bit 254 is set)
///   bits 250-252    : streakDay (1..STREAK_FLAT_BONUS_MAX; 0 = no streak yet)
///   bits 192-223    : lastQuestCompletedDay (uint32 calendar day)
///   bits 128-159    : lastFirstGameTimestamp (uint32 seconds since epoch)
///   bits 0-127      : pointsBalance (uint128)
abstract contract PlayerProfile is IGachaPointsAssigner, Ownable {
    error NotAssigner();
    error PointsOverflow();

    uint256 internal constant BONUS_AWARDED_BIT = 1 << 255;
    uint256 internal constant IS_CPU_BIT = 1 << 254;
    uint256 internal constant IS_HARD_CPU_BIT = 1 << 253;
    uint256 internal constant STREAK_DAY_SHIFT = 250;
    uint256 internal constant STREAK_DAY_MASK = 0x7;
    uint256 internal constant LAST_FIRST_GAME_TS_SHIFT = 128;
    uint256 internal constant LAST_QUEST_DAY_SHIFT = 192;
    uint256 internal constant FIRST_GAME_OF_DAY_COOLDOWN = 1 days;
    uint256 internal constant POINTS_MASK_128 = (1 << 128) - 1;

    mapping(address => uint256) public playerData;

    /// @notice One bool grants both IGachaPointsAssigner and IExpAssigner authority.
    mapping(address => bool) public isAssigner;

    // ----- Owner-managed flags / allowlist -----

    function setWhitelistedOpponents(address[] memory toAllow, address[] memory toDisallow) external onlyOwner {
        _flipPlayerDataBitBulk(toAllow, toDisallow, IS_CPU_BIT);
    }

    function setHardCpuOpponents(address[] memory toMark, address[] memory toUnmark) external onlyOwner {
        _flipPlayerDataBitBulk(toMark, toUnmark, IS_HARD_CPU_BIT);
    }

    function setAssigners(address[] memory toAdd, address[] memory toRemove) external onlyOwner {
        for (uint256 i; i < toAdd.length;) {
            isAssigner[toAdd[i]] = true;
            unchecked { ++i; }
        }
        for (uint256 i; i < toRemove.length;) {
            isAssigner[toRemove[i]] = false;
            unchecked { ++i; }
        }
    }

    function _flipPlayerDataBitBulk(address[] memory on, address[] memory off, uint256 bit) internal {
        for (uint256 i; i < on.length;) {
            playerData[on[i]] |= bit;
            unchecked { ++i; }
        }
        for (uint256 i; i < off.length;) {
            playerData[off[i]] &= ~bit;
            unchecked { ++i; }
        }
    }

    // ----- View accessors -----

    function pointsBalance(address player) public view returns (uint256) {
        return uint128(playerData[player]);
    }

    function isWhitelistedOpponent(address addr) public view returns (bool) {
        return playerData[addr] & IS_CPU_BIT != 0;
    }

    function isHardCpu(address addr) public view returns (bool) {
        return playerData[addr] & IS_HARD_CPU_BIT != 0;
    }

    // ----- IGachaPointsAssigner -----

    function assignPoints(address player, uint256 amount) external override {
        if (!isAssigner[msg.sender]) revert NotAssigner();
        uint256 data = playerData[player];
        uint256 newPoints = (data & POINTS_MASK_128) + amount;
        if (newPoints > POINTS_MASK_128) revert PointsOverflow();
        playerData[player] = (data & ~POINTS_MASK_128) | newPoints;
    }
}
