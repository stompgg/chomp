// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";

import "./IMonRegistry.sol";
import "./ITeamRegistry.sol";

contract DefaultTeamRegistry is ITeamRegistry {
    uint32 constant BITS_PER_MON_INDEX = 32;
    uint256 constant ONES_MASK = (2 ** BITS_PER_MON_INDEX) - 1;

    struct Args {
        IMonRegistry REGISTRY;
        uint256 MONS_PER_TEAM;
        uint256 MOVES_PER_MON;
    }

    error InvalidTeamSize();
    error InvalidNumMovesPerMon();
    error InvalidMove();
    error InvalidAbility();
    error DuplicateMonId();

    IMonRegistry immutable REGISTRY;
    uint256 immutable MONS_PER_TEAM;
    uint256 immutable MOVES_PER_MON;

    mapping(address => mapping(uint256 => Mon[])) public teams;
    mapping(address => mapping(uint256 => uint256)) public monRegistryIndicesForTeamPacked;
    mapping(address => uint256) public numTeams;

    constructor(Args memory args) {
        REGISTRY = args.REGISTRY;
        MONS_PER_TEAM = args.MONS_PER_TEAM;
        MOVES_PER_MON = args.MOVES_PER_MON;
    }

    function createTeam(uint256[] memory monIndices, IMoveSet[4][] memory moves, IAbility[] memory abilities)
        public
        virtual
    {
        _createTeamForUser(msg.sender, monIndices, moves, abilities);
    }

    function _createTeamForUser(
        address user,
        uint256[] memory monIndices,
        IMoveSet[4][] memory moves,
        IAbility[] memory abilities
    ) internal {
        if (monIndices.length != MONS_PER_TEAM) {
            revert InvalidTeamSize();
        }
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            for (uint256 j; j < MOVES_PER_MON; j++) {
                if (address(moves[i][j]) == address(0)) continue;
                if (!REGISTRY.isValidMove(monIndices[i], moves[i][j])) {
                    revert InvalidMove();
                }
            }
            if (!REGISTRY.isValidAbility(monIndices[i], abilities[i])) {
                revert InvalidAbility();
            }
        }

        // Check for duplicate mon indices
        _checkForDuplicates(monIndices);

        // Initialize team and set indices
        uint256 teamId = numTeams[user];
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            teams[user][teamId]
            .push(Mon({stats: REGISTRY.getMonStats(monIndices[i]), moves: moves[i], ability: abilities[i]}));
            _setMonRegistryIndices(teamId, uint32(monIndices[i]), i, user);
        }

        // Update the team index
        numTeams[user] += 1;
    }

    function updateTeam(
        uint256 teamIndex,
        uint256[] memory teamMonIndicesToOverride,
        uint256[] memory newMonIndices,
        IMoveSet[4][] memory newMoves,
        IAbility[] memory newAbilities
    ) public virtual {
        uint256 numMonsToOverride = teamMonIndicesToOverride.length;

        // Verify that the new moves and abilities are valid
        for (uint256 i; i < numMonsToOverride; i++) {
            uint256 monIndex = newMonIndices[i];
            for (uint256 j; j < MOVES_PER_MON; j++) {
                if (address(newMoves[i][j]) == address(0)) continue;
                if (!REGISTRY.isValidMove(monIndex, newMoves[i][j])) {
                    revert InvalidMove();
                }
            }
            if (!REGISTRY.isValidAbility(monIndex, newAbilities[i])) {
                revert InvalidAbility();
            }
        }

        // Check for duplicate mon indices
        _checkForDuplicates(newMonIndices);

        // Update the team
        for (uint256 i; i < numMonsToOverride; i++) {
            uint256 monIndexToOverride = teamMonIndicesToOverride[i];
            teams[msg.sender][teamIndex][monIndexToOverride] =
                Mon({stats: REGISTRY.getMonStats(newMonIndices[i]), moves: newMoves[i], ability: newAbilities[i]});
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

    function copyTeam(address playerToCopy, uint256 teamIndex) public virtual {
        // Initialize team and set indices
        uint256 teamId = numTeams[msg.sender];
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            teams[msg.sender][teamId].push(teams[playerToCopy][teamIndex][i]);
        }
        monRegistryIndicesForTeamPacked[msg.sender][teamIndex] =
            monRegistryIndicesForTeamPacked[playerToCopy][teamIndex];

        // Update the team index
        numTeams[msg.sender] += 1;
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
        uint256[] memory ids = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; ++i) {
            ids[i] = _getMonRegistryIndex(player, teamIndex, i);
        }
        return ids;
    }

    function getTeam(address player, uint256 teamIndex) external view returns (Mon[] memory) {
        return teams[player][teamIndex];
    }

    function getTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex) external view returns (Mon[] memory, Mon[] memory) {
        return (teams[p0][p0TeamIndex], teams[p1][p1TeamIndex]);
    }

    function getTeamCount(address player) external view returns (uint256) {
        return numTeams[player];
    }

    function getMonRegistry() external view returns (IMonRegistry) {
        return REGISTRY;
    }
}
