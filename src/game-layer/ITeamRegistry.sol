// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";

import "../abilities/IAbility.sol";
import "../moves/IMoveSet.sol";

interface ITeamRegistry {
    function getTeam(address player, uint256 teamIndex) external returns (Mon[] memory);
    function getTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex) external returns (Mon[] memory, Mon[] memory);
    function getTeamCount(address player) external returns (uint256);
    function getMonRegistryIndicesForTeam(address player, uint256 teamIndex) external returns (uint256[] memory);

    function getMonData(uint256 monId)
        external
        view
        returns (MonStats memory mon, uint256[] memory moves, uint256[] memory abilities);
    function getMonDataBatch(uint256[] calldata monIds)
        external
        view
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities);
    function getMonStats(uint256 monId) external view returns (MonStats memory);
    function getMonMetadata(uint256 monId, bytes32 key) external view returns (bytes32);
    function getMonCount() external view returns (uint256);
    function getMonIds(uint256 start, uint256 end) external view returns (uint256[] memory);
    function isValidMove(uint256 monId, uint256 moveSlot) external view returns (bool);
    function isValidAbility(uint256 monId, uint256 ability) external view returns (bool);
    function validateMon(Mon memory m, uint256 monId) external view returns (bool);
    function validateMonBatch(Mon[] calldata mons, uint256[] calldata monIds) external view returns (bool);

    // Per-mon exp / level (registry-side state, mirrored to frontend in batched form)
    function getExp(address player, uint256 monId) external view returns (uint256);
    function getLevel(address player, uint256 monId) external view returns (uint256);
    function levelForExp(uint256 exp) external pure returns (uint256);
    function getExpAndLevelsForMons(address player, uint256[] calldata monIds)
        external view returns (uint256[] memory exp, uint256[] memory levels);
    function getExpAndLevelsForTeam(address player, uint256 teamIndex)
        external view returns (uint256[] memory monIds, uint256[] memory exp, uint256[] memory levels);
    function getExpAndLevelsForTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex)
        external view returns (
            uint256[] memory p0MonIds, uint256[] memory p0Exp, uint256[] memory p0Levels,
            uint256[] memory p1MonIds, uint256[] memory p1Exp, uint256[] memory p1Levels
        );

    // Facets — assignment (caller-driven) + delta application (Engine consumes at startBattle)
    function assignFacets(uint256[] calldata monIds, uint8[] calldata facetIds) external;
    function getFacetData(address player, uint256 monId)
        external view returns (uint16 unlockedBitmap, uint8 assignedFacetId);
    function getFacetDeltaForMon(address player, uint256 monId) external view returns (StatDelta memory);
    function getTeamsWithDeltas(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex)
        external view returns (
            Mon[] memory p0Team, Mon[] memory p1Team,
            StatDelta[] memory p0Deltas, StatDelta[] memory p1Deltas
        );
}
