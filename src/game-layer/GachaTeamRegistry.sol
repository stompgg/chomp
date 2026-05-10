// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";
import "./ITeamRegistry.sol";
import "./Facets.sol";
import "./Quests.sol";

import {
    GACHA_ROLL_COST,
    GACHA_POINTS_PER_WIN,
    GACHA_POINTS_PER_LOSS,
    EXP_PER_SURVIVING_MON,
    EXP_PER_KOD_MON,
    EXP_FIRST_GAME_OF_DAY_MULT,
    EXP_FIRST_PVP_OF_DAY_MULT,
    QUEST_REWARD_POINTS,
    QUEST_REWARD_EXP_MULT,
    CLEARED_MON_STATE_SENTINEL
} from "../Constants.sol";
import {EngineHookStep, MonStateIndexName} from "../Enums.sol";
import {EnumerableSetLib} from "../lib/EnumerableSetLib.sol";
import {IEngine} from "../IEngine.sol";
import {IEngineHook} from "../IEngineHook.sol";
import {IGachaRNG} from "../rng/IGachaRNG.sol";

contract GachaTeamRegistry is ITeamRegistry, IEngineHook, IGachaRNG, Facets, Quests {
    using EnumerableSetLib for *;

    // ----- Team layout -----
    uint32 constant BITS_PER_MON_INDEX = 32;
    uint256 constant ONES_MASK = (2 ** BITS_PER_MON_INDEX) - 1;

    // ----- Gacha constants -----
    uint256 public constant INITIAL_ROLLS = 4;
    uint256 public constant NUM_STARTERS = 3;
    uint256 public constant ROLL_COST = GACHA_ROLL_COST;
    uint256 public constant POINTS_PER_WIN = GACHA_POINTS_PER_WIN;
    uint256 public constant POINTS_PER_LOSS = GACHA_POINTS_PER_LOSS;
    uint16 public constant STEPS_BITMAP = uint16(1) << uint8(EngineHookStep.OnBattleEnd);

    // ----- playerData[address] bit layout -----
    //   bit 255       : bonusAwarded (first-roll bonus has been awarded)
    //   bit 254       : isWhitelistedAsOpponent (admin-set, replaces old separate mapping)
    //   bits 192-223  : lastQuestCompletedDay (uint32)
    //   bits 160-191  : lastPvPGameDay (uint32, day = block.timestamp / 1 days)
    //   bits 128-159  : lastGameDay (uint32)
    //   bits 0-127    : pointsBalance (uint128)
    uint256 private constant BONUS_AWARDED_BIT = 1 << 255;
    uint256 private constant IS_CPU_BIT = 1 << 254;
    uint256 private constant POINTS_MASK_128 = (1 << 128) - 1;

    // ----- Exp packing (per (player, mon-bucket); 16 mons per slot, 16 bits each) -----
    uint256 internal constant MONS_PER_EXP_BUCKET = 16;
    uint256 internal constant EXP_BITS_PER_MON = 16;
    uint256 internal constant EXP_PER_MON_MASK = (1 << EXP_BITS_PER_MON) - 1;
    uint256 internal constant EXP_PER_MON_CAP = EXP_PER_MON_MASK; // 65535

    // ----- MON_STATE opcode arg layout: (slot << 4) | stateField; 4 bits each -----
    uint256 internal constant MON_STATE_SLOT_SHIFT = 4;
    uint256 internal constant MON_STATE_FIELD_MASK = 0xF;

    // ----- GachaEvent packing -----
    // Layout reserves 8 lanes for per-mon data so MONS_PER_TEAM can grow up to 8 without
    // a layout migration. Bumping past 8 silently truncates per-mon fields and would
    // require an event-version bump.
    //   bits 0-15    pointsAwarded (uint16)
    //   bits 16-79   per-mon exp gain (8 lanes * 8 bits)
    //   bits 80-111  per-mon facets unlocked this battle (8 lanes * 4 bits)
    //   bits 112-119 bonus flags
    //   bits 120-127 multiplier (uint8)
    //   bits 128-135 outcome: 0=loss, 1=win, 2=draw
    //   bits 136-255 reserved
    uint256 internal constant GE_EXP_SHIFT = 16;
    uint256 internal constant GE_EXP_BITS_PER_MON = 8;
    uint256 internal constant GE_EXP_LANE_MASK = (1 << GE_EXP_BITS_PER_MON) - 1;
    uint256 internal constant GE_FACETS_SHIFT = 80;
    uint256 internal constant GE_FACETS_BITS_PER_MON = 4;
    uint256 internal constant GE_FACETS_LANE_MASK = (1 << GE_FACETS_BITS_PER_MON) - 1;
    uint256 internal constant GE_BONUS_SHIFT = 112;
    uint256 internal constant GE_MULT_SHIFT = 120;
    uint256 internal constant GE_OUTCOME_SHIFT = 128;

    uint256 internal constant BONUS_FIRST_ROLL = 1 << 0;
    uint256 internal constant BONUS_FIRST_GAME = 1 << 1;
    uint256 internal constant BONUS_FIRST_PVP  = 1 << 2;
    uint256 internal constant BONUS_QUEST      = 1 << 3;

    // ----- Errors -----
    error InvalidTeamSize();
    error DuplicateMonId();
    error InvalidTeamIndex();
    error NotOwner();
    error NotWhitelistedOpponent();
    error MonAlreadyCreated();
    error MonNotyetCreated();
    error NonSequentialMonId();
    error AlreadyFirstRolled();
    error InvalidStarterId();
    error NoMoreStock();
    error NotEngine();

    // ----- Events -----
    event Roll(address indexed player, uint256[] monIds, uint256 pointsSpent);
    event GachaEvent(address indexed player, uint256 packed);

    // ----- Immutables -----
    uint256 immutable MONS_PER_TEAM;
    uint256 immutable MOVES_PER_MON;
    IEngine public immutable ENGINE;
    IGachaRNG immutable RNG;

    // ----- Team state -----
    mapping(address => mapping(uint256 => uint256)) public monRegistryIndicesForTeamPacked;
    mapping(address => uint256) public numTeams;

    // ----- Mon registry state -----
    EnumerableSetLib.Uint256Set private monIds;
    mapping(uint256 monId => MonStats) public monStats;
    mapping(uint256 monId => EnumerableSetLib.Uint256Set) private monMoves;
    mapping(uint256 monId => EnumerableSetLib.Uint256Set) private monAbilities;
    mapping(uint256 monId => mapping(bytes32 => bytes32)) private monMetadata;

    // ----- Gacha state -----
    mapping(address => EnumerableSetLib.Uint256Set) private monsOwned;
    mapping(address => uint256) private playerData;

    // ----- Per-mon exp packing -----
    mapping(address player => mapping(uint256 monBucket => uint256 packedExp)) public packedExpForMon;

    // ----- Per-(user, opponent) CPU team facet config -----
    // Each user picks any facet (0-12) for each slot of a whitelisted opponent's phantom team.
    // Slot-indexed: 4 bits per slot, MONS_PER_TEAM slots fit comfortably in one uint256.
    // Keyed identically to monRegistryIndicesForTeamPacked phantom slots so a single SLOAD
    // resolves both the team's mon ids and its facet config at battle start.
    uint256 internal constant OPP_FACET_BITS_PER_SLOT = 4;
    uint256 internal constant OPP_FACET_SLOT_MASK = (1 << OPP_FACET_BITS_PER_SLOT) - 1;
    mapping(address opponent => mapping(uint256 phantomKey => uint256 packedFacets)) public opponentTeamFacetsPacked;

    constructor(uint256 _MONS_PER_TEAM, uint256 _MOVES_PER_MON, IEngine _ENGINE, IGachaRNG _RNG) {
        MONS_PER_TEAM = _MONS_PER_TEAM;
        MOVES_PER_MON = _MOVES_PER_MON;
        ENGINE = _ENGINE;
        RNG = address(_RNG) == address(0) ? IGachaRNG(address(this)) : _RNG;
        _initializeOwner(msg.sender);
        _seedInitialQuests();
    }

    /// @dev Seeds the day-rotated quest pool. Pool size and content fix the schedule, since
    /// active quest = keccak256(day) % poolLength. Owner can mutate later via add/edit/remove.
    function _seedInitialQuests() internal {
        int16 teamSize = int16(int256(MONS_PER_TEAM));
        Quests.Predicate[] memory preds = new Quests.Predicate[](1);

        // Flawless / Last Stand
        preds[0] = Quests.Predicate({op: Quests.Op.ALIVE_COUNT, cmp: Quests.Cmp.GE, negate: false, arg: 0, operand: teamSize});
        _addQuest(preds);
        preds[0] = Quests.Predicate({op: Quests.Op.ALIVE_COUNT, cmp: Quests.Cmp.EQ, negate: false, arg: 0, operand: 1});
        _addQuest(preds);

        // Untouchable: at least one mon at base HP at end.
        preds[0] = Quests.Predicate({op: Quests.Op.MAX_HP_DELTA, cmp: Quests.Cmp.EQ, negate: false, arg: 0, operand: 0});
        _addQuest(preds);

        // Have mon X in team — three variants (starter ids 0..NUM_STARTERS-1).
        preds[0] = Quests.Predicate({op: Quests.Op.HAS_MON_ID, cmp: Quests.Cmp.EQ, negate: false, arg: 0, operand: 1});
        _addQuest(preds);
        preds[0] = Quests.Predicate({op: Quests.Op.HAS_MON_ID, cmp: Quests.Cmp.EQ, negate: false, arg: 1, operand: 1});
        _addQuest(preds);
        preds[0] = Quests.Predicate({op: Quests.Op.HAS_MON_ID, cmp: Quests.Cmp.EQ, negate: false, arg: 2, operand: 1});
        _addQuest(preds);

        // Fully Equipped / Veteran Squad / Star Student
        preds[0] = Quests.Predicate({op: Quests.Op.FACET_COUNT, cmp: Quests.Cmp.EQ, negate: false, arg: 0, operand: teamSize});
        _addQuest(preds);
        preds[0] = Quests.Predicate({op: Quests.Op.MIN_LEVEL, cmp: Quests.Cmp.GT, negate: false, arg: 0, operand: 3});
        _addQuest(preds);
        preds[0] = Quests.Predicate({op: Quests.Op.MAX_LEVEL, cmp: Quests.Cmp.GT, negate: false, arg: 0, operand: 6});
        _addQuest(preds);

        // Lightning rounds — three difficulty tiers.
        preds[0] = Quests.Predicate({op: Quests.Op.TURNS, cmp: Quests.Cmp.LT, negate: false, arg: 0, operand: 30});
        _addQuest(preds);
        preds[0] = Quests.Predicate({op: Quests.Op.TURNS, cmp: Quests.Cmp.LT, negate: false, arg: 0, operand: 25});
        _addQuest(preds);
        preds[0] = Quests.Predicate({op: Quests.Op.TURNS, cmp: Quests.Cmp.LT, negate: false, arg: 0, operand: 20});
        _addQuest(preds);
    }

    // =====================================================================
    // Team management
    // =====================================================================

    function _validateOwnership(uint256[] memory monIndices) internal view {
        if (!_isOwnerBatch(msg.sender, monIndices)) revert NotOwner();
    }

    function createTeam(uint256[] memory monIndices) external {
        _validateOwnership(monIndices);
        _createTeamForUser(msg.sender, monIndices);
    }

    function createTeamForUser(address user, uint256[] memory monIndices) external onlyOwner {
        _createTeamForUser(user, monIndices);
    }

    // Whitelist lives in bit 254 of playerData[addr] so per-battle eval rides the existing SLOAD.
    function setWhitelistedOpponents(address[] memory toAllow, address[] memory toDisallow) external onlyOwner {
        for (uint256 i; i < toAllow.length;) {
            playerData[toAllow[i]] |= IS_CPU_BIT;
            unchecked { ++i; }
        }
        for (uint256 i; i < toDisallow.length;) {
            playerData[toDisallow[i]] &= ~IS_CPU_BIT;
            unchecked { ++i; }
        }
    }

    function isWhitelistedOpponent(address addr) public view returns (bool) {
        return playerData[addr] & IS_CPU_BIT != 0;
    }

    // Phantom teams: duplicate mon ids allowed; phantom key truncated to uint16 to match
    // BattleData.pXTeamIndex storage width. ~2^16 collision space — acceptable since exp accrual
    // is winner/human-only and uses the player's own (small) teamIndex, not the phantom key.
    //
    // facetIds is a parallel array: facetIds[i] is the facet (0=none, 1..12) the caller wants
    // applied to the CPU's slot i. No ownership / unlock checks — the user is configuring an
    // opponent they will fight, not their own mons.
    function setOpponentTeam(
        address opponent,
        uint256[] memory monIndices,
        uint8[] memory facetIds
    ) external {
        if (!isWhitelistedOpponent(opponent)) revert NotWhitelistedOpponent();
        if (monIndices.length != facetIds.length) revert FacetArgsLengthMismatch();
        uint256 phantomKey = uint16(uint160(msg.sender));
        monRegistryIndicesForTeamPacked[opponent][phantomKey] = _packIndices(monIndices);

        uint256 packedFacets;
        for (uint256 i; i < facetIds.length;) {
            uint8 facetId = facetIds[i];
            if (facetId > TOTAL_FACETS) revert InvalidFacetId();
            packedFacets |= uint256(facetId) << (i * OPP_FACET_BITS_PER_SLOT);
            unchecked { ++i; }
        }
        opponentTeamFacetsPacked[opponent][phantomKey] = packedFacets;
    }

    /// @notice Unpack the caller's configured facets for a CPU opponent.
    function getOpponentTeamFacets(address user, address opponent)
        external
        view
        returns (uint8[] memory facetIds)
    {
        uint256 packed = opponentTeamFacetsPacked[opponent][uint16(uint160(user))];
        facetIds = new uint8[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            facetIds[i] = uint8((packed >> (i * OPP_FACET_BITS_PER_SLOT)) & OPP_FACET_SLOT_MASK);
            unchecked { ++i; }
        }
    }

    function _createTeamForUser(address user, uint256[] memory monIndices) internal {
        uint256 packed = _packTeam(monIndices);

        uint256 teamId = numTeams[user];
        monRegistryIndicesForTeamPacked[user][teamId] = packed;

        // Update the team index
        numTeams[user] = teamId + 1;
    }

    function _packTeam(uint256[] memory monIndices) internal view returns (uint256 packed) {
        packed = _packIndices(monIndices);
        _checkForDuplicates(monIndices);
    }

    function _packIndices(uint256[] memory monIndices) internal view returns (uint256 packed) {
        if (monIndices.length != MONS_PER_TEAM) {
            revert InvalidTeamSize();
        }
        for (uint256 i; i < MONS_PER_TEAM;) {
            packed |= uint256(uint32(monIndices[i])) << (i * BITS_PER_MON_INDEX);
            unchecked {
                ++i;
            }
        }
    }

    function _unpackTeam(uint256 packed) internal view returns (uint256[] memory ids) {
        ids = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            ids[i] = uint32(packed >> (i * BITS_PER_MON_INDEX));
            unchecked {
                ++i;
            }
        }
    }

    function updateTeam(uint256 teamIndex, uint256[] memory teamMonIndicesToOverride, uint256[] memory newMonIndices)
        external
    {
        _validateOwnership(newMonIndices);

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
        if (!isWhitelistedOpponent(player) && teamIndex >= numTeams[player]) {
            revert InvalidTeamIndex();
        }
        return _unpackTeam(monRegistryIndicesForTeamPacked[player][teamIndex]);
    }

    function getTeam(address player, uint256 teamIndex) external view returns (Mon[] memory) {
        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        uint256[] memory ids = _unpackTeam(monRegistryIndicesForTeamPacked[player][teamIndex]);

        (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities) = _getMonDataBatch(ids);

        // Unpack into team
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256[] memory movesToUse = new uint256[](MOVES_PER_MON);
            for (uint256 j; j < MOVES_PER_MON;) {
                movesToUse[j] = moves[i][j];
                unchecked {
                    ++j;
                }
            }
            team[i] = Mon({stats: stats[i], ability: abilities[i][0], moves: movesToUse});
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
        uint256[] memory ids = new uint256[](totalMons);
        for (uint256 i; i < MONS_PER_TEAM;) {
            ids[i] = uint32(p0Packed >> (i * BITS_PER_MON_INDEX));
            ids[i + MONS_PER_TEAM] = uint32(p1Packed >> (i * BITS_PER_MON_INDEX));
            unchecked {
                ++i;
            }
        }

        (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities) = _getMonDataBatch(ids);

        // Unpack into teams
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256[] memory p0MovesToUse = new uint256[](MOVES_PER_MON);
            uint256[] memory p1MovesToUse = new uint256[](MOVES_PER_MON);
            for (uint256 j; j < MOVES_PER_MON;) {
                p0MovesToUse[j] = moves[i][j];
                p1MovesToUse[j] = moves[i + MONS_PER_TEAM][j];
                unchecked {
                    ++j;
                }
            }
            p0Team[i] = Mon({stats: stats[i], ability: abilities[i][0], moves: p0MovesToUse});
            p1Team[i] = Mon({stats: stats[i + MONS_PER_TEAM], ability: abilities[i + MONS_PER_TEAM][0], moves: p1MovesToUse});
            unchecked {
                ++i;
            }
        }

        return (p0Team, p1Team);
    }

    function getTeamCount(address player) external view returns (uint256) {
        return numTeams[player];
    }

    // =====================================================================
    // Mon registry
    // =====================================================================

    function createMon(
        uint256 monId,
        MonStats memory _monStats,
        uint256[] memory allowedMoves,
        uint256[] memory allowedAbilities,
        bytes32[] memory keys,
        bytes32[] memory values
    ) external onlyOwner {
        // Sequential monIds required so packedExpForMon / facetData buckets stay dense.
        if (monId != monIds.length()) revert NonSequentialMonId();
        MonStats storage existingMon = monStats[monId];
        // No mon has 0 hp and 0 stamina
        if (existingMon.hp != 0 && existingMon.stamina != 0) {
            revert MonAlreadyCreated();
        }
        monIds.add(monId);
        monStats[monId] = _monStats;
        EnumerableSetLib.Uint256Set storage moves = monMoves[monId];
        uint256 numMoves = allowedMoves.length;
        for (uint256 i; i < numMoves; ++i) {
            moves.add(allowedMoves[i]);
        }
        EnumerableSetLib.Uint256Set storage abilities = monAbilities[monId];
        uint256 numAbilities = allowedAbilities.length;
        for (uint256 i; i < numAbilities; ++i) {
            abilities.add(allowedAbilities[i]);
        }
        _modifyMonMetadata(monId, keys, values);
    }

    function modifyMon(
        uint256 monId,
        MonStats memory _monStats,
        uint256[] memory movesToAdd,
        uint256[] memory movesToRemove,
        uint256[] memory abilitiesToAdd,
        uint256[] memory abilitiesToRemove
    ) external onlyOwner {
        MonStats storage existingMon = monStats[monId];
        if (existingMon.hp == 0 && existingMon.stamina == 0) {
            revert MonNotyetCreated();
        }
        monStats[monId] = _monStats;
        EnumerableSetLib.Uint256Set storage moves = monMoves[monId];
        {
            uint256 numMovesToAdd = movesToAdd.length;
            for (uint256 i; i < numMovesToAdd; ++i) {
                moves.add(movesToAdd[i]);
            }
        }
        {
            uint256 numMovesToRemove = movesToRemove.length;
            for (uint256 i; i < numMovesToRemove; ++i) {
                moves.remove(movesToRemove[i]);
            }
        }
        EnumerableSetLib.Uint256Set storage abilities = monAbilities[monId];
        {
            uint256 numAbilitiesToAdd = abilitiesToAdd.length;
            for (uint256 i; i < numAbilitiesToAdd; ++i) {
                abilities.add(abilitiesToAdd[i]);
            }
        }
        {
            uint256 numAbilitiesToRemove = abilitiesToRemove.length;
            for (uint256 i; i < numAbilitiesToRemove; ++i) {
                abilities.remove(abilitiesToRemove[i]);
            }
        }
    }

    function modifyMonMetadata(uint256 monId, bytes32[] memory keys, bytes32[] memory values) external onlyOwner {
        _modifyMonMetadata(monId, keys, values);
    }

    function _modifyMonMetadata(uint256 monId, bytes32[] memory keys, bytes32[] memory values) internal {
        mapping(bytes32 => bytes32) storage metadata = monMetadata[monId];
        for (uint256 i; i < keys.length; ++i) {
            metadata[keys[i]] = values[i];
        }
    }

    function getMonMetadata(uint256 monId, bytes32 key) external view returns (bytes32) {
        return monMetadata[monId][key];
    }

    function validateMon(Mon memory m, uint256 monId) public view returns (bool) {
        // Check that the mon's stats match the current mon ID's stats
        if (
            m.stats.attack != monStats[monId].attack || m.stats.defense != monStats[monId].defense
                || m.stats.specialAttack != monStats[monId].specialAttack
                || m.stats.specialDefense != monStats[monId].specialDefense || m.stats.speed != monStats[monId].speed
                || m.stats.hp != monStats[monId].hp || m.stats.stamina != monStats[monId].stamina
        ) {
            return false;
        }
        // Check that the mon's moves are valid for the current mon ID
        for (uint256 i; i < m.moves.length; ++i) {
            if (!monMoves[monId].contains(m.moves[i])) {
                return false;
            }
        }
        // Check that the mon's ability is valid for the current mon ID
        if (!monAbilities[monId].contains(m.ability)) {
            return false;
        }
        return true;
    }

    function validateMonBatch(Mon[] calldata mons, uint256[] calldata ids) external view returns (bool) {
        uint256 len = mons.length;
        for (uint256 i; i < len;) {
            if (!validateMon(mons[i], ids[i])) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function getMonData(uint256 monId)
        external
        view
        returns (MonStats memory _monStats, uint256[] memory moves, uint256[] memory abilities)
    {
        _monStats = monStats[monId];
        moves = monMoves[monId].values();
        abilities = monAbilities[monId].values();
    }

    function getMonDataBatch(uint256[] calldata ids)
        external
        view
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities)
    {
        return _getMonDataBatch(ids);
    }

    function _getMonDataBatch(uint256[] memory ids)
        internal
        view
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities)
    {
        uint256 len = ids.length;
        stats = new MonStats[](len);
        moves = new uint256[][](len);
        abilities = new uint256[][](len);
        for (uint256 i; i < len;) {
            uint256 monId = ids[i];
            stats[i] = monStats[monId];
            moves[i] = monMoves[monId].values();
            abilities[i] = monAbilities[monId].values();
            unchecked {
                ++i;
            }
        }
    }

    function getMonIds(uint256 start, uint256 end) external view returns (uint256[] memory) {
        if (start == end) {
            uint256[] memory allIds = new uint256[](monIds.length());
            for (uint256 i; i < monIds.length(); ++i) {
                allIds[i] = monIds.at(i);
            }
            return allIds;
        }
        uint256[] memory ids = new uint256[](end - start);
        for (uint256 i; i < end - start; ++i) {
            ids[i] = monIds.at(start + i);
        }
        return ids;
    }

    function getMonStats(uint256 monId) external view returns (MonStats memory) {
        return monStats[monId];
    }

    function isValidMove(uint256 monId, uint256 moveSlot) external view returns (bool) {
        return monMoves[monId].contains(moveSlot);
    }

    function isValidAbility(uint256 monId, uint256 ability) external view returns (bool) {
        return monAbilities[monId].contains(ability);
    }

    function getMonCount() external view returns (uint256) {
        return monIds.length();
    }

    // =====================================================================
    // Gacha
    // =====================================================================

    function pointsBalance(address player) public view returns (uint256) {
        return uint128(playerData[player]);
    }

    function firstRoll(uint256 starterId) external returns (uint256[] memory rolledIds) {
        if (monsOwned[msg.sender].length() > 0) revert AlreadyFirstRolled();
        if (starterId >= NUM_STARTERS) revert InvalidStarterId();

        rolledIds = new uint256[](INITIAL_ROLLS);
        rolledIds[0] = starterId;
        monsOwned[msg.sender].add(starterId);
        // Remaining rolls are uniform across non-starter pool [NUM_STARTERS, numMons).
        _rollInto(rolledIds, 1, NUM_STARTERS);
        emit Roll(msg.sender, rolledIds, 0);
    }

    function roll(uint256 numRolls) external returns (uint256[] memory rolledIds) {
        if (monsOwned[msg.sender].length() == monIds.length()) revert NoMoreStock();
        uint256 cost = numRolls * ROLL_COST;
        uint256 data = playerData[msg.sender];
        uint256 currentPoints = uint128(data);
        playerData[msg.sender] = (data & ~POINTS_MASK_128) | (currentPoints - cost);
        rolledIds = new uint256[](numRolls);
        _rollInto(rolledIds, 0, 0);
        emit Roll(msg.sender, rolledIds, cost);
    }

    /// @dev Fills `out[startIdx..]` with unowned mon ids drawn uniformly from `[minId, numMons)`.
    /// Linear probing stays inside the same window so it never lands on a starter.
    function _rollInto(uint256[] memory out, uint256 startIdx, uint256 minId) internal {
        uint256 numMons = monIds.length();
        uint256 range = numMons - minId;
        bytes32 seed = keccak256(abi.encodePacked(blockhash(block.number - 1), msg.sender));
        uint256 prng = RNG.getRNG(seed);
        for (uint256 i = startIdx; i < out.length; ++i) {
            uint256 monId = (prng % range) + minId;
            while (monsOwned[msg.sender].contains(monId)) {
                monId = ((monId + 1 - minId) % range) + minId;
            }
            out[i] = monId;
            monsOwned[msg.sender].add(monId);
            seed = keccak256(abi.encodePacked(seed));
            prng = RNG.getRNG(seed);
        }
    }

    // Default RNG implementation (used when constructed with address(0) RNG)
    function getRNG(bytes32 seed) public view returns (uint256) {
        return uint256(keccak256(abi.encode(blockhash(block.number - 1), seed)));
    }

    // ----- Ownership -----
    function isOwner(address player, uint256 monId) external view returns (bool) {
        return monsOwned[player].contains(monId);
    }

    function isOwnerBatch(address player, uint256[] calldata ids) external view returns (bool) {
        return _isOwnerBatch(player, ids);
    }

    function _isOwnerBatch(address player, uint256[] memory ids) internal view returns (bool) {
        EnumerableSetLib.Uint256Set storage owned = monsOwned[player];
        uint256 len = ids.length;
        for (uint256 i; i < len;) {
            if (!owned.contains(ids[i])) {
                return false;
            }
            unchecked {
                ++i;
            }
        }
        return true;
    }

    function balanceOf(address player) external view returns (uint256) {
        return monsOwned[player].length();
    }

    function getOwned(address player) external view returns (uint256[] memory) {
        return monsOwned[player].values();
    }

    // ----- IEngineHook -----
    function getStepsBitmap() external pure override returns (uint16) {
        return STEPS_BITMAP;
    }

    function onBattleStart(bytes32) external override {}

    function onRoundStart(bytes32) external override {}

    function onRoundEnd(bytes32) external override {}

    function onBattleEnd(bytes32 battleKey) external override {
        if (msg.sender != address(ENGINE)) revert NotEngine();

        BattleEndContext memory ctx = ENGINE.getBattleEndContext(battleKey);
        uint32 currentDay = uint32(block.timestamp / 1 days);

        uint256 packed0 = playerData[ctx.p0];
        uint256 packed1 = playerData[ctx.p1];
        bool isCpu0 = packed0 & IS_CPU_BIT != 0;
        bool isCpu1 = packed1 & IS_CPU_BIT != 0;
        bool isPvP = !(isCpu0 || isCpu1);

        for (uint256 playerIndex; playerIndex < 2; ++playerIndex) {
            bool isCPU = playerIndex == 0 ? isCpu0 : isCpu1;
            if (isCPU) continue; // CPU side: no SSTORE, no exp/facet writes, no quest reward, no event

            address player = playerIndex == 0 ? ctx.p0 : ctx.p1;
            uint256 teamIdx = playerIndex == 0 ? ctx.p0TeamIndex : ctx.p1TeamIndex;
            uint8 koBitmap = playerIndex == 0 ? ctx.p0KOBitmap : ctx.p1KOBitmap;
            uint256 pts = ctx.winner == player ? POINTS_PER_WIN : POINTS_PER_LOSS;
            uint256 packed = playerIndex == 0 ? packed0 : packed1;

            uint256 bonus = packed & BONUS_AWARDED_BIT;
            uint256 cpuBit = packed & IS_CPU_BIT; // always 0 here; preserved on writeback for safety
            uint256 points = packed & POINTS_MASK_128;
            uint32 lastGameDay = uint32(packed >> 128);
            uint32 lastPvPDay = uint32(packed >> 160);
            uint32 lastQuestCompletedDay = uint32(packed >> 192);

            uint256 bonusFlags;
            uint256 pointsThisBattle;

            if (bonus == 0) {
                points += ROLL_COST;
                pointsThisBattle += ROLL_COST;
                bonus = BONUS_AWARDED_BIT;
                bonusFlags |= BONUS_FIRST_ROLL;
            }
            points += pts;
            pointsThisBattle += pts;

            uint256 multiplier = 1;
            if (lastGameDay != currentDay) {
                multiplier *= EXP_FIRST_GAME_OF_DAY_MULT;
                lastGameDay = currentDay;
                bonusFlags |= BONUS_FIRST_GAME;
            }
            if (isPvP && lastPvPDay != currentDay) {
                multiplier *= EXP_FIRST_PVP_OF_DAY_MULT;
                lastPvPDay = currentDay;
                bonusFlags |= BONUS_FIRST_PVP;
            }

            // Quest reward stacks multiplicatively. Winner only, one-shot per day.
            if (
                ctx.winner == player
                && lastQuestCompletedDay != currentDay
                && questPool.length > 0
                && _evalActiveQuest(ctx, playerIndex, battleKey)
            ) {
                points += QUEST_REWARD_POINTS;
                pointsThisBattle += QUEST_REWARD_POINTS;
                multiplier *= QUEST_REWARD_EXP_MULT;
                lastQuestCompletedDay = currentDay;
                bonusFlags |= BONUS_QUEST;
            }

            playerData[player] = bonus
                | cpuBit
                | (points & POINTS_MASK_128)
                | (uint256(lastGameDay) << 128)
                | (uint256(lastPvPDay) << 160)
                | (uint256(lastQuestCompletedDay) << 192);

            uint256 expFacetPacked = _applyExpAndFacetDraws(player, teamIdx, koBitmap, multiplier);

            uint256 outcome = ctx.winner == player ? 1 : (ctx.winner == address(0) ? 2 : 0);
            uint256 evt = (pointsThisBattle & 0xFFFF)
                | expFacetPacked
                | (bonusFlags << GE_BONUS_SHIFT)
                | ((multiplier & 0xFF) << GE_MULT_SHIFT)
                | (outcome << GE_OUTCOME_SHIFT);
            emit GachaEvent(player, evt);
        }
    }

    /// @dev Walks the team in one pass, sharing lastBucket across exp + facet slot reads.
    /// Returns the per-mon exp/facet portion of the GachaEvent (bits 16..111). Lanes are
    /// saturated at their packed widths so a future tuning blow-up can't bleed into other fields.
    function _applyExpAndFacetDraws(
        address player,
        uint256 teamIdx,
        uint8 koBitmap,
        uint256 multiplier
    ) internal returns (uint256 expFacetPacked) {
        uint256 packedTeam = monRegistryIndicesForTeamPacked[player][teamIdx];
        uint256 lastBucket = type(uint256).max;
        uint256 expSlot;
        uint256 facetSlot;
        bool facetLoaded;
        bool facetDirty;

        for (uint256 j; j < MONS_PER_TEAM;) {
            uint256 monId = uint32(packedTeam >> (j * BITS_PER_MON_INDEX));
            uint256 bucket = monId / MONS_PER_EXP_BUCKET;
            uint256 lane = monId % MONS_PER_EXP_BUCKET;

            if (bucket != lastBucket) {
                if (lastBucket != type(uint256).max) {
                    packedExpForMon[player][lastBucket] = expSlot;
                    if (facetDirty) facetData[player][lastBucket] = facetSlot;
                }
                expSlot = packedExpForMon[player][bucket];
                facetLoaded = false;
                facetDirty = false;
                lastBucket = bucket;
            }

            // Exp update with cap
            uint256 oldExp = (expSlot >> (lane * EXP_BITS_PER_MON)) & EXP_PER_MON_MASK;
            uint256 alive = (koBitmap & (1 << j)) == 0 ? 1 : 0;
            uint256 gain = (alive == 1 ? EXP_PER_SURVIVING_MON : EXP_PER_KOD_MON) * multiplier;
            uint256 newExp = oldExp + gain;
            if (newExp > EXP_PER_MON_CAP) newExp = EXP_PER_MON_CAP;
            expSlot = (expSlot & ~(EXP_PER_MON_MASK << (lane * EXP_BITS_PER_MON)))
                | (newExp << (lane * EXP_BITS_PER_MON));

            // Track actual gain for the event (post-cap), saturating at lane width.
            uint256 actualGain = newExp - oldExp;
            if (actualGain > GE_EXP_LANE_MASK) actualGain = GE_EXP_LANE_MASK;
            expFacetPacked |= actualGain << (GE_EXP_SHIFT + j * GE_EXP_BITS_PER_MON);

            // Facet draws on level crossings
            uint256 oldLevel = _levelForExp(oldExp);
            uint256 newLevel = _levelForExp(newExp);
            if (newLevel > oldLevel) {
                if (!facetLoaded) {
                    facetSlot = facetData[player][bucket];
                    facetLoaded = true;
                }
                (uint16 unlockedBitmap, uint8 assignedFacet) = _readFacetSlotForMon(facetSlot, lane);
                uint8 priorPop = _popcount(unlockedBitmap);
                for (uint256 levelNum = oldLevel + 1; levelNum <= newLevel;) {
                    if (_popcount(unlockedBitmap) == TOTAL_FACETS) break;
                    uint256 entropy = uint256(keccak256(abi.encode(monId, blockhash(block.number - 1), player, levelNum)));
                    (unlockedBitmap,) = _drawNextFacet(unlockedBitmap, entropy);
                    unchecked { ++levelNum; }
                }
                uint256 drawn = _popcount(unlockedBitmap) - priorPop;
                if (drawn > GE_FACETS_LANE_MASK) drawn = GE_FACETS_LANE_MASK;
                expFacetPacked |= drawn << (GE_FACETS_SHIFT + j * GE_FACETS_BITS_PER_MON);
                facetSlot = _writeFacetSlotForMon(facetSlot, lane, unlockedBitmap, assignedFacet);
                facetDirty = true;
            }

            unchecked { ++j; }
        }

        if (lastBucket != type(uint256).max) {
            packedExpForMon[player][lastBucket] = expSlot;
            if (facetDirty) facetData[player][lastBucket] = facetSlot;
        }
    }

    // =====================================================================
    // Exp / Level public API
    // =====================================================================

    function getExp(address player, uint256 monId) external view returns (uint256) {
        return _getExp(player, monId);
    }

    function getLevel(address player, uint256 monId) external view returns (uint256) {
        return _levelForExp(_getExp(player, monId));
    }

    function levelForExp(uint256 exp) external pure returns (uint256) {
        return _levelForExp(exp);
    }

    function _getExp(address player, uint256 monId) internal view returns (uint256) {
        uint256 bucket = monId / MONS_PER_EXP_BUCKET;
        uint256 lane = monId % MONS_PER_EXP_BUCKET;
        return (packedExpForMon[player][bucket] >> (lane * EXP_BITS_PER_MON)) & EXP_PER_MON_MASK;
    }

    /// @dev Linear-gap curve: gap from level N-1 to level N is 2*(N-1) + 4 exp (= 2N+2).
    /// Caps at level 12 — matches the 12 Facets, so no need to compute beyond.
    /// Cumulative thresholds: lv1=4, lv2=10, lv3=18, lv4=28, lv5=40, lv6=54, lv7=70,
    /// lv8=88, lv9=108, lv10=130, lv11=154, lv12=180.
    function _levelForExp(uint256 exp) internal pure returns (uint256) {
        if (exp < 4)   return 0;
        if (exp < 10)  return 1;
        if (exp < 18)  return 2;
        if (exp < 28)  return 3;
        if (exp < 40)  return 4;
        if (exp < 54)  return 5;
        if (exp < 70)  return 6;
        if (exp < 88)  return 7;
        if (exp < 108) return 8;
        if (exp < 130) return 9;
        if (exp < 154) return 10;
        if (exp < 180) return 11;
        return 12;
    }

    function getExpAndLevelsForMons(address player, uint256[] calldata ids)
        external
        view
        returns (uint256[] memory exp, uint256[] memory levels)
    {
        uint256 len = ids.length;
        exp = new uint256[](len);
        levels = new uint256[](len);
        for (uint256 i; i < len;) {
            uint256 e = _getExp(player, ids[i]);
            exp[i] = e;
            levels[i] = _levelForExp(e);
            unchecked { ++i; }
        }
    }

    function getExpAndLevelsForTeam(address player, uint256 teamIndex)
        external
        view
        returns (uint256[] memory ids, uint256[] memory exp, uint256[] memory levels)
    {
        ids = _unpackTeam(monRegistryIndicesForTeamPacked[player][teamIndex]);
        exp = new uint256[](MONS_PER_TEAM);
        levels = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256 e = _getExp(player, ids[i]);
            exp[i] = e;
            levels[i] = _levelForExp(e);
            unchecked { ++i; }
        }
    }

    function getExpAndLevelsForTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex)
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
        p0MonIds = _unpackTeam(monRegistryIndicesForTeamPacked[p0][p0TeamIndex]);
        p1MonIds = _unpackTeam(monRegistryIndicesForTeamPacked[p1][p1TeamIndex]);
        p0Exp = new uint256[](MONS_PER_TEAM);
        p0Levels = new uint256[](MONS_PER_TEAM);
        p1Exp = new uint256[](MONS_PER_TEAM);
        p1Levels = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256 e0 = _getExp(p0, p0MonIds[i]);
            uint256 e1 = _getExp(p1, p1MonIds[i]);
            p0Exp[i] = e0;
            p1Exp[i] = e1;
            p0Levels[i] = _levelForExp(e0);
            p1Levels[i] = _levelForExp(e1);
            unchecked { ++i; }
        }
    }

    // =====================================================================
    // Teams + deltas (Engine consumes at startBattle)
    // =====================================================================

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
        p0Team = new Mon[](MONS_PER_TEAM);
        p1Team = new Mon[](MONS_PER_TEAM);
        p0Deltas = new StatDelta[](MONS_PER_TEAM);
        p1Deltas = new StatDelta[](MONS_PER_TEAM);

        uint256 p0Packed = monRegistryIndicesForTeamPacked[p0][p0TeamIndex];
        uint256 p1Packed = monRegistryIndicesForTeamPacked[p1][p1TeamIndex];

        // Build all monIds for the batch stat lookup
        uint256 totalMons = MONS_PER_TEAM * 2;
        uint256[] memory ids = new uint256[](totalMons);
        for (uint256 i; i < MONS_PER_TEAM;) {
            ids[i] = uint32(p0Packed >> (i * BITS_PER_MON_INDEX));
            ids[i + MONS_PER_TEAM] = uint32(p1Packed >> (i * BITS_PER_MON_INDEX));
            unchecked { ++i; }
        }

        (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities) = _getMonDataBatch(ids);

        // Whitelisted (CPU) sides pull facets from the per-(user, opponent) phantom slot the
        // human caller configured via setOpponentTeam. Human sides keep using per-mon facetData.
        bool p0IsCpu = isWhitelistedOpponent(p0);
        bool p1IsCpu = isWhitelistedOpponent(p1);
        uint256 p0CpuFacets = p0IsCpu ? opponentTeamFacetsPacked[p0][p0TeamIndex] : 0;
        uint256 p1CpuFacets = p1IsCpu ? opponentTeamFacetsPacked[p1][p1TeamIndex] : 0;

        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256[] memory p0MovesToUse = new uint256[](MOVES_PER_MON);
            uint256[] memory p1MovesToUse = new uint256[](MOVES_PER_MON);
            for (uint256 j; j < MOVES_PER_MON;) {
                p0MovesToUse[j] = moves[i][j];
                p1MovesToUse[j] = moves[i + MONS_PER_TEAM][j];
                unchecked { ++j; }
            }
            p0Team[i] = Mon({stats: stats[i], ability: abilities[i][0], moves: p0MovesToUse});
            p1Team[i] = Mon({stats: stats[i + MONS_PER_TEAM], ability: abilities[i + MONS_PER_TEAM][0], moves: p1MovesToUse});

            uint8 p0FacetId = p0IsCpu
                ? uint8((p0CpuFacets >> (i * OPP_FACET_BITS_PER_SLOT)) & OPP_FACET_SLOT_MASK)
                : _facetIdForMon(p0, ids[i]);
            uint8 p1FacetId = p1IsCpu
                ? uint8((p1CpuFacets >> (i * OPP_FACET_BITS_PER_SLOT)) & OPP_FACET_SLOT_MASK)
                : _facetIdForMon(p1, ids[i + MONS_PER_TEAM]);
            p0Deltas[i] = _computeFacetDelta(stats[i], p0FacetId);
            p1Deltas[i] = _computeFacetDelta(stats[i + MONS_PER_TEAM], p1FacetId);
            unchecked { ++i; }
        }
    }

    function _facetIdForMon(address player, uint256 monId) private view returns (uint8 facetId) {
        (, facetId) = _readFacetSlotForMon(
            facetData[player][monId / MONS_PER_FACET_BUCKET],
            monId % MONS_PER_FACET_BUCKET
        );
    }

    // =====================================================================
    // Facets / Quests subclass hooks
    // =====================================================================

    function _isFacetMonOwned(address player, uint256 monId) internal view override returns (bool) {
        return monsOwned[player].contains(monId);
    }

    function _getMonStatsForFacets(uint256 monId) internal view override returns (MonStats memory) {
        return monStats[monId];
    }

    /// @dev Quest opcode dispatch. Has direct access to registry storage and the engine.
    function _extract(
        uint8 op,
        uint16 arg,
        BattleEndContext memory ctx,
        uint256 playerIndex,
        bytes32 battleKey
    ) internal view override returns (int256) {
        Op opcode = Op(op);
        address player = playerIndex == 0 ? ctx.p0 : ctx.p1;
        uint256 teamIdx = playerIndex == 0 ? ctx.p0TeamIndex : ctx.p1TeamIndex;
        uint8 koBitmap = playerIndex == 0 ? ctx.p0KOBitmap : ctx.p1KOBitmap;
        uint8 activeMon = playerIndex == 0 ? ctx.p0ActiveMonIndex : ctx.p1ActiveMonIndex;

        if (opcode == Op.TURNS) {
            return int256(uint256(ctx.turnId));
        }
        if (opcode == Op.ALIVE_COUNT) {
            return int256(uint256(MONS_PER_TEAM)) - int256(uint256(_popcount(koBitmap)));
        }
        if (opcode == Op.HAS_MON_ID) {
            uint256 packedTeam = monRegistryIndicesForTeamPacked[player][teamIdx];
            for (uint256 i; i < MONS_PER_TEAM; ++i) {
                if (uint32(packedTeam >> (i * BITS_PER_MON_INDEX)) == uint256(arg)) return 1;
            }
            return 0;
        }
        if (opcode == Op.MON_LEVEL) {
            return int256(_levelForExp(_getExp(player, uint256(arg))));
        }
        if (opcode == Op.MON_FACET) {
            uint256 bucket = uint256(arg) / MONS_PER_FACET_BUCKET;
            uint256 lane = uint256(arg) % MONS_PER_FACET_BUCKET;
            (, uint8 facetId) = _readFacetSlotForMon(facetData[player][bucket], lane);
            return int256(uint256(facetId));
        }
        if (opcode == Op.MON_KO_AT_SLOT) {
            return (koBitmap & (1 << uint256(arg))) != 0 ? int256(1) : int256(0);
        }
        if (opcode == Op.MON_ALIVE_AT_SLOT) {
            return (koBitmap & (1 << uint256(arg))) == 0 ? int256(1) : int256(0);
        }
        if (opcode == Op.ACTIVE_SLOT_INDEX) {
            return int256(uint256(activeMon));
        }
        if (opcode == Op.MON_STATE) {
            uint256 slot = (uint256(arg) >> MON_STATE_SLOT_SHIFT) & MON_STATE_FIELD_MASK;
            uint256 stateField = uint256(arg) & MON_STATE_FIELD_MASK;
            return int256(ENGINE.getMonStateForBattle(battleKey, playerIndex, slot, MonStateIndexName(stateField)));
        }
        if (opcode == Op.MIN_LEVEL || opcode == Op.MAX_LEVEL) {
            uint256 packedTeam = monRegistryIndicesForTeamPacked[player][teamIdx];
            bool isMin = opcode == Op.MIN_LEVEL;
            uint256 acc = isMin ? type(uint256).max : 0;
            for (uint256 i; i < MONS_PER_TEAM;) {
                uint256 monId = uint32(packedTeam >> (i * BITS_PER_MON_INDEX));
                uint256 lvl = _levelForExp(_getExp(player, monId));
                if (isMin ? lvl < acc : lvl > acc) acc = lvl;
                unchecked { ++i; }
            }
            return int256(acc);
        }
        if (opcode == Op.FACET_COUNT) {
            uint256 packedTeam = monRegistryIndicesForTeamPacked[player][teamIdx];
            uint256 count;
            for (uint256 i; i < MONS_PER_TEAM;) {
                uint256 monId = uint32(packedTeam >> (i * BITS_PER_MON_INDEX));
                uint256 bucket = monId / MONS_PER_FACET_BUCKET;
                uint256 lane = monId % MONS_PER_FACET_BUCKET;
                (, uint8 assignedFacet) = _readFacetSlotForMon(facetData[player][bucket], lane);
                if (assignedFacet != 0) ++count;
                unchecked { ++i; }
            }
            return int256(count);
        }
        if (opcode == Op.MIN_HP_DELTA || opcode == Op.MAX_HP_DELTA) {
            MonState[] memory states = ENGINE.getMonStatesForSide(battleKey, playerIndex);
            bool isMin = opcode == Op.MIN_HP_DELTA;
            int256 acc = isMin ? type(int256).max : type(int256).min;
            for (uint256 i; i < states.length;) {
                int256 d = states[i].hpDelta == CLEARED_MON_STATE_SENTINEL ? int256(0) : int256(states[i].hpDelta);
                if (isMin ? d < acc : d > acc) acc = d;
                unchecked { ++i; }
            }
            return acc;
        }
        revert InvalidOpcode();
    }

    // ITeamRegistry redeclares these — required override stubs delegate to Facets.

    function assignFacets(uint256[] calldata monIdsToAssign, uint8[] calldata facetIds)
        public
        override(Facets, ITeamRegistry)
    {
        super.assignFacets(monIdsToAssign, facetIds);
    }

    function getFacetData(address player, uint256 monId)
        public
        view
        override(Facets, ITeamRegistry)
        returns (uint16, uint8)
    {
        return super.getFacetData(player, monId);
    }

    function getFacetDeltaForMon(address player, uint256 monId)
        public
        view
        override(Facets, ITeamRegistry)
        returns (StatDelta memory)
    {
        return super.getFacetDeltaForMon(player, monId);
    }
}
