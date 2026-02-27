// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";

import "./IMonRegistry.sol";
import "./ITeamRegistry.sol";

contract LookupTeamRegistry is ITeamRegistry {
    uint32 constant BITS_PER_MON_INDEX = 32;
    uint256 constant ONES_MASK = (2 ** BITS_PER_MON_INDEX) - 1;

    struct Args {
        IMonRegistry REGISTRY;
        uint256 MONS_PER_TEAM;
        uint256 MOVES_PER_MON;
    }

    error InvalidTeamSize();
    error DuplicateMonId();
    error InvalidTeamIndex();

    IMonRegistry immutable REGISTRY;
    uint256 immutable MONS_PER_TEAM;
    uint256 immutable MOVES_PER_MON;

    mapping(address => mapping(uint256 => uint256)) public monRegistryIndicesForTeamPacked;
    mapping(address => uint256) public numTeams;

    constructor(Args memory args) {
        REGISTRY = args.REGISTRY;
        MONS_PER_TEAM = args.MONS_PER_TEAM;
        MOVES_PER_MON = args.MOVES_PER_MON;
    }

    function createTeam(uint256[] memory monIndices) public virtual {
        _createTeamForUser(msg.sender, monIndices);
    }

    function _createTeamForUser(address user, uint256[] memory monIndices) internal {
        if (monIndices.length != MONS_PER_TEAM) {
            revert InvalidTeamSize();
        }

        // Check for duplicate mon indices
        _checkForDuplicates(monIndices);

        uint256 packed;
        for (uint256 i; i < MONS_PER_TEAM;) {
            packed |= uint256(uint32(monIndices[i])) << (i * BITS_PER_MON_INDEX);
            unchecked {
                ++i;
            }
        }

        uint256 teamId = numTeams[user];
        monRegistryIndicesForTeamPacked[user][teamId] = packed;

        // Update the team index
        numTeams[user] = teamId + 1;
    }

    function updateTeam(uint256 teamIndex, uint256[] memory teamMonIndicesToOverride, uint256[] memory newMonIndices)
        public
        virtual
    {
        uint256 numMonsToOverride = teamMonIndicesToOverride.length;

        // Check for duplicate mon indices
        _checkForDuplicates(newMonIndices);

        // Update the team
        for (uint256 i; i < numMonsToOverride; i++) {
            uint256 monIndexToOverride = teamMonIndicesToOverride[i];
            _setMonRegistryIndices(teamIndex, uint32(newMonIndices[i]), monIndexToOverride, msg.sender);
        }
    }

    function _checkForDuplicates(uint256[] memory monIndices) internal view {
        for (uint256 i; i < MONS_PER_TEAM - 1; i++) {
            for (uint256 j = i + 1; j < MONS_PER_TEAM; j++) {
                if (monIndices[i] == monIndices[j]) {
                    revert DuplicateMonId();
                }
            }
        }
    }

    // Layout: | Nothing | Nothing | Mon5 | Mon4 | Mon3 | Mon2 | Mon1 | Mon 0 <-- rightmost bits
    function _setMonRegistryIndices(uint256 teamIndex, uint32 monId, uint256 position, address caller) internal {
        // Create a bitmask to clear the bits we want to modify
        uint256 clearBitmask = ~(ONES_MASK << (position * BITS_PER_MON_INDEX));

        // Get the existing packed value
        uint256 existingPackedValue = monRegistryIndicesForTeamPacked[caller][teamIndex];

        // Clear the bits we want to modify
        uint256 clearedValue = existingPackedValue & clearBitmask;

        // Create the value bitmask with the new monId
        uint256 valueBitmask = uint256(monId) << (position * BITS_PER_MON_INDEX);

        // Combine the cleared value with the new value
        monRegistryIndicesForTeamPacked[caller][teamIndex] = clearedValue | valueBitmask;
    }

    function _getMonRegistryIndex(address player, uint256 teamIndex, uint256 position) internal view returns (uint256) {
        return uint32(monRegistryIndicesForTeamPacked[player][teamIndex] >> (position * BITS_PER_MON_INDEX));
    }

    function getMonRegistryIndicesForTeam(address player, uint256 teamIndex) public view returns (uint256[] memory) {
        if (teamIndex >= numTeams[player]) {
            revert InvalidTeamIndex();
        }
        // Cache packed value (1 SLOAD instead of MONS_PER_TEAM)
        uint256 packed = monRegistryIndicesForTeamPacked[player][teamIndex];
        uint256[] memory ids = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            ids[i] = uint32(packed >> (i * BITS_PER_MON_INDEX));
            unchecked {
                ++i;
            }
        }
        return ids;
    }

    // Read directly from the registry
    function getTeam(address player, uint256 teamIndex) external view returns (Mon[] memory) {
        Mon[] memory team = new Mon[](MONS_PER_TEAM);

        // Cache packed index (1 SLOAD instead of MONS_PER_TEAM)
        uint256 packed = monRegistryIndicesForTeamPacked[player][teamIndex];

        // Build monIds for batch call
        uint256[] memory monIds = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            monIds[i] = uint32(packed >> (i * BITS_PER_MON_INDEX));
            unchecked {
                ++i;
            }
        }

        // Single batch call instead of MONS_PER_TEAM individual calls
        (MonStats[] memory stats, address[][] memory moves, address[][] memory abilities) = REGISTRY.getMonDataBatch(monIds);

        // Unpack into team
        for (uint256 i; i < MONS_PER_TEAM;) {
            IMoveSet[] memory movesToUse = new IMoveSet[](MOVES_PER_MON);
            for (uint256 j; j < MOVES_PER_MON;) {
                movesToUse[j] = IMoveSet(moves[i][j]);
                unchecked {
                    ++j;
                }
            }
            team[i] = Mon({stats: stats[i], ability: IAbility(abilities[i][0]), moves: movesToUse});
            unchecked {
                ++i;
            }
        }
        return team;
    }

    function getTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex) external view returns (Mon[] memory, Mon[] memory) {
        Mon[] memory p0Team = new Mon[](MONS_PER_TEAM);
        Mon[] memory p1Team = new Mon[](MONS_PER_TEAM);

        uint256 p0Packed = monRegistryIndicesForTeamPacked[p0][p0TeamIndex];
        uint256 p1Packed = monRegistryIndicesForTeamPacked[p1][p1TeamIndex];

        // Build all monIds for batch call
        uint256 totalMons = MONS_PER_TEAM * 2;
        uint256[] memory monIds = new uint256[](totalMons);
        for (uint256 i; i < MONS_PER_TEAM;) {
            monIds[i] = uint32(p0Packed >> (i * BITS_PER_MON_INDEX));
            monIds[i + MONS_PER_TEAM] = uint32(p1Packed >> (i * BITS_PER_MON_INDEX));
            unchecked {
                ++i;
            }
        }

        (MonStats[] memory stats, address[][] memory moves, address[][] memory abilities) = REGISTRY.getMonDataBatch(monIds);

        // Unpack into teams
        for (uint256 i; i < MONS_PER_TEAM;) {
            IMoveSet[] memory p0MovesToUse = new IMoveSet[](MOVES_PER_MON);
            IMoveSet[] memory p1MovesToUse = new IMoveSet[](MOVES_PER_MON);
            for (uint256 j; j < MOVES_PER_MON;) {
                p0MovesToUse[j] = IMoveSet(moves[i][j]);
                p1MovesToUse[j] = IMoveSet(moves[i + MONS_PER_TEAM][j]);
                unchecked {
                    ++j;
                }
            }
            p0Team[i] = Mon({stats: stats[i], ability: IAbility(abilities[i][0]), moves: p0MovesToUse});
            p1Team[i] = Mon({stats: stats[i + MONS_PER_TEAM], ability: IAbility(abilities[i + MONS_PER_TEAM][0]), moves: p1MovesToUse});
            unchecked {
                ++i;
            }
        }

        return (p0Team, p1Team);
    }

    function getTeamCount(address player) external view returns (uint256) {
        return numTeams[player];
    }

    function getMonRegistry() external view returns (IMonRegistry) {
        return REGISTRY;
    }
}
