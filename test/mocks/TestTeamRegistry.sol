// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Structs.sol";

import {IMonRegistry} from "../../src/teams/IMonRegistry.sol";
import {ITeamRegistry} from "../../src/teams/ITeamRegistry.sol";

contract TestTeamRegistry is ITeamRegistry {
    // Legacy: single team per player (for backwards compatibility)
    mapping(address => Mon[]) public teams;
    // New: multiple teams per player indexed by teamIndex
    mapping(address => mapping(uint256 => Mon[])) public indexedTeams;
    mapping(address => mapping(uint256 => bool)) public hasIndexedTeam;
    uint256[] indices;

    function setTeam(address player, Mon[] memory team) public {
        teams[player] = team;
    }

    function setTeamAt(address player, uint256 teamIndex, Mon[] memory team) public {
        delete indexedTeams[player][teamIndex];
        for (uint256 i = 0; i < team.length; i++) {
            indexedTeams[player][teamIndex].push(team[i]);
        }
        hasIndexedTeam[player][teamIndex] = true;
    }

    function getTeam(address player, uint256 teamIndex) external view returns (Mon[] memory) {
        if (hasIndexedTeam[player][teamIndex]) {
            return indexedTeams[player][teamIndex];
        }
        return teams[player];
    }

    function getTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex)
        external
        view
        returns (Mon[] memory, Mon[] memory)
    {
        Mon[] memory team0 = hasIndexedTeam[p0][p0TeamIndex] ? indexedTeams[p0][p0TeamIndex] : teams[p0];
        Mon[] memory team1 = hasIndexedTeam[p1][p1TeamIndex] ? indexedTeams[p1][p1TeamIndex] : teams[p1];
        return (team0, team1);
    }

    function getTeamCount(address player) external view returns (uint256) {
        return teams[player].length;
    }

    function getMonRegistry() external pure returns (IMonRegistry) {
        return IMonRegistry(address(0));
    }

    function setIndices(uint256[] memory _indices) public {
        indices = _indices;
    }

    function getMonRegistryIndicesForTeam(address, uint256) external view returns (uint256[] memory) {
        return indices;
    }
}
