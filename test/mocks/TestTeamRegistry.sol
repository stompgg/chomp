// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Structs.sol";

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

    function setIndices(uint256[] memory _indices) public {
        indices = _indices;
    }

    function getMonRegistryIndicesForTeam(address, uint256) external view returns (uint256[] memory) {
        return indices;
    }

    // Tests skip mon validation by having validateMonBatch always return true.
    function validateMonBatch(Mon[] calldata, uint256[] calldata) external pure returns (bool) {
        return true;
    }

    function validateMon(Mon memory, uint256) external pure returns (bool) {
        return true;
    }

    function getMonData(uint256)
        external
        pure
        returns (MonStats memory, uint256[] memory, uint256[] memory)
    {
        return (MonStats({hp: 0, stamina: 0, speed: 0, attack: 0, defense: 0, specialAttack: 0, specialDefense: 0, type1: Type.None, type2: Type.None}), new uint256[](0), new uint256[](0));
    }

    function getMonDataBatch(uint256[] calldata)
        external
        pure
        returns (MonStats[] memory, uint256[][] memory, uint256[][] memory)
    {
        return (new MonStats[](0), new uint256[][](0), new uint256[][](0));
    }

    function getMonStats(uint256) external pure returns (MonStats memory) {
        return MonStats({hp: 0, stamina: 0, speed: 0, attack: 0, defense: 0, specialAttack: 0, specialDefense: 0, type1: Type.None, type2: Type.None});
    }

    function getMonMetadata(uint256, bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function getMonCount() external pure returns (uint256) {
        return 0;
    }

    function getMonIds(uint256, uint256) external pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function isValidMove(uint256, uint256) external pure returns (bool) {
        return true;
    }

    function isValidAbility(uint256, uint256) external pure returns (bool) {
        return true;
    }

    // ---- exp / level stubs (zero-state, lets non-registry-aware tests run) ----

    function getExp(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function getLevel(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function levelForExp(uint256) external pure returns (uint256) {
        return 0;
    }

    function getExpAndLevelsForMons(address, uint256[] calldata ids)
        external
        pure
        returns (uint256[] memory exp, uint256[] memory levels)
    {
        exp = new uint256[](ids.length);
        levels = new uint256[](ids.length);
    }

    function getExpAndLevelsForTeam(address, uint256)
        external
        view
        returns (uint256[] memory ids, uint256[] memory exp, uint256[] memory levels)
    {
        ids = indices;
        exp = new uint256[](indices.length);
        levels = new uint256[](indices.length);
    }

    function getExpAndLevelsForTeams(address, uint256, address, uint256)
        external
        view
        returns (
            uint256[] memory p0MonIds,
            uint256[] memory p0Exp,
            uint256[] memory p0Levels,
            uint256[] memory p1MonIds,
            uint256[] memory p1Exp,
            uint256[] memory p1Levels
        )
    {
        p0MonIds = indices;
        p1MonIds = indices;
        p0Exp = new uint256[](indices.length);
        p0Levels = new uint256[](indices.length);
        p1Exp = new uint256[](indices.length);
        p1Levels = new uint256[](indices.length);
    }

    // ---- facet stubs ----

    function assignFacets(uint256[] calldata, uint8[] calldata) external pure {}

    function getFacetData(address, uint256) external pure returns (uint16, uint8) {
        return (0, 0);
    }

    function getFacetDeltaForMon(address, uint256) external pure returns (StatDelta memory) {
        return StatDelta(0, 0, 0, 0, 0, 0);
    }

    function getTeamsWithDeltas(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex)
        external
        view
        returns (
            Mon[] memory p0Team,
            Mon[] memory p1Team,
            StatDelta[] memory p0Deltas,
            StatDelta[] memory p1Deltas
        )
    {
        p0Team = hasIndexedTeam[p0][p0TeamIndex] ? indexedTeams[p0][p0TeamIndex] : teams[p0];
        p1Team = hasIndexedTeam[p1][p1TeamIndex] ? indexedTeams[p1][p1TeamIndex] : teams[p1];
        p0Deltas = new StatDelta[](p0Team.length);
        p1Deltas = new StatDelta[](p1Team.length);
    }
}
