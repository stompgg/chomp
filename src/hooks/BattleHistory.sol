// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngineHook} from "../IEngineHook.sol";
import {IEngine} from "../IEngine.sol";
import {BattleData} from "../Structs.sol";
import {EnumerableSetLib} from "../lib/EnumerableSetLib.sol";

/// @title BattleHistory
/// @notice Tracks battle statistics for all players including total battles fought and wins/losses
contract BattleHistory is IEngineHook {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    // Only runs at OnBattleEnd (bit 3 = 0x08)
    uint16 public constant STEPS_BITMAP = 0x08;

    IEngine public immutable engine;

    mapping(address => uint256) private _numBattles;

    // Mapping from player address to set of all opponents fought
    mapping(address => EnumerableSetLib.AddressSet) private _opponents;

    // Mapping from player pair to battle summary
    // Key is keccak256(abi.encodePacked(p0, p1)) where p0 < p1
    mapping(bytes32 => BattleSummary) private _battleSummaries;

    struct BattleSummary {
        uint128 totalBattles;
        uint128 p0Wins; // wins by the lower address (p0 in the sorted pair)
    }

    constructor(IEngine _engine) {
        engine = _engine;
    }

    function getStepsBitmap() external pure override returns (uint16) {
        return STEPS_BITMAP;
    }

    function onBattleStart(bytes32 battleKey) external {}

    function onRoundStart(bytes32 battleKey) external {}

    function onRoundEnd(bytes32 battleKey) external {}

    /// @notice Called when a battle ends - updates battle statistics
    function onBattleEnd(bytes32 battleKey) external {
        (, BattleData memory battleData) = engine.getBattle(battleKey);

        address p0 = battleData.p0;
        address p1 = battleData.p1;
        address winner = engine.getWinner(battleKey);

        // Update total battles for both players
        _numBattles[p0]++;
        _numBattles[p1]++;

        // Add opponents to each player's set
        _opponents[p0].add(p1);
        _opponents[p1].add(p0);

        // Update battle summary for this pair
        bytes32 pairKey = _getPairKey(p0, p1);
        BattleSummary storage summary = _battleSummaries[pairKey];
        summary.totalBattles++;

        // Track wins for the lower address in the sorted pair
        (address lower, ) = _sortAddresses(p0, p1);
        if (winner == lower) {
            summary.p0Wins++;
        }
    }

    /// @notice Get total number of battles fought by a player
    /// @param player The player address
    /// @return Total number of battles
    function getNumBattles(address player) external view returns (uint256) {
        return _numBattles[player];
    }

    /// @notice Get battle summary between two players
    /// @param p0 First player address
    /// @param p1 Second player address
    /// @return totalBattles Total number of completed battles between p0 and p1
    /// @return p0Wins Number of wins by p0
    function getBattleSummary(address p0, address p1) external view returns (uint256 totalBattles, uint256 p0Wins) {
        bytes32 pairKey = _getPairKey(p0, p1);
        BattleSummary memory summary = _battleSummaries[pairKey];

        // If p0 is the lower address, return as-is
        (address lower, ) = _sortAddresses(p0, p1);
        if (p0 == lower) {
            return (summary.totalBattles, summary.p0Wins);
        } else {
            // If p0 is the higher address, we need to return p1's wins from p0's perspective
            return (summary.totalBattles, summary.totalBattles - summary.p0Wins);
        }
    }

    /// @notice Get all opponents fought by a player
    /// @param player The player address
    /// @return Array of opponent addresses
    function getOpponents(address player) external view returns (address[] memory) {
        return _opponents[player].values();
    }

    /// @notice Get the number of unique opponents a player has fought
    /// @param player The player address
    /// @return Number of unique opponents
    function getNumOpponents(address player) external view returns (uint256) {
        return _opponents[player].length();
    }

    /// @dev Sort two addresses and return them in ascending order
    function _sortAddresses(address a, address b) private pure returns (address lower, address higher) {
        if (a < b) {
            return (a, b);
        } else {
            return (b, a);
        }
    }

    /// @dev Get a unique key for a pair of addresses (sorted)
    function _getPairKey(address a, address b) private pure returns (bytes32) {
        (address lower, address higher) = _sortAddresses(a, b);
        return keccak256(abi.encodePacked(lower, higher));
    }
}
