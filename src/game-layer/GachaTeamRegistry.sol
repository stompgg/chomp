// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";
import "./Facets.sol";
import "./IExpAssigner.sol";
import "./IGachaPointsAssigner.sol";
import "./IPhantomTeamRegistry.sol";
import "./ITeamRegistry.sol";
import "./MonExp.sol";
import "./MonOwnership.sol";
import "./MonRegistry.sol";
import "./PackedTeamStore.sol";
import "./PlayerProfile.sol";
import "./Quests.sol";

import {
    CLEARED_MON_STATE_SENTINEL,
    EXP_PER_KOD_MON,
    EXP_PER_SURVIVING_MON,
    GACHA_FIRST_GAME_EVER_BONUS,
    GACHA_POINTS_PER_LOSS,
    GACHA_POINTS_PER_WIN,
    GACHA_ROLL_COST,
    GAME_EXP_MULT,
    QUEST_REWARD_MULT,
    STREAK_FLAT_BONUS_MAX,
    STREAK_GRACE_WINDOW
} from "../Constants.sol";
import {EngineHookStep, MonStateIndexName} from "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import {IEngineHook} from "../IEngineHook.sol";
import {EnumerableSetLib} from "../lib/EnumerableSetLib.sol";
import {IGachaRNG} from "../rng/IGachaRNG.sol";

contract GachaTeamRegistry is
    IPhantomTeamRegistry,
    IEngineHook,
    IGachaRNG,
    MonOwnership,
    MonRegistry,
    PlayerProfile,
    MonExp,
    Quests
{
    /// @dev Disambiguates the PlayerProfile implementation against the ITeamRegistry surface.
    function isWhitelistedOpponent(address addr) public view override(PlayerProfile, ITeamRegistry) returns (bool) {
        return PlayerProfile.isWhitelistedOpponent(addr);
    }

    using EnumerableSetLib for *;

    // ----- Gacha constants -----
    uint256 public constant INITIAL_ROLLS = 4;
    uint256 public constant NUM_STARTERS = 3;
    uint256 public constant ROLL_COST = GACHA_ROLL_COST;
    uint256 public constant POINTS_PER_WIN = GACHA_POINTS_PER_WIN;
    uint256 public constant POINTS_PER_LOSS = GACHA_POINTS_PER_LOSS;
    uint256 public constant FIRST_GAME_EVER_BONUS = GACHA_FIRST_GAME_EVER_BONUS;
    uint256 public constant STREAK_BONUS_MAX = STREAK_FLAT_BONUS_MAX;
    uint256 public constant STREAK_GRACE = STREAK_GRACE_WINDOW;
    uint16 public constant STEPS_BITMAP = uint16(1) << uint8(EngineHookStep.OnBattleEnd);

    // ----- MON_STATE opcode arg layout: (slot << 4) | stateField; 4 bits each -----
    uint256 internal constant MON_STATE_SLOT_SHIFT = 4;
    uint256 internal constant MON_STATE_FIELD_MASK = 0xF;

    // ----- GachaEvent packing -----
    // One event per battle carries both players' packed payloads. Each payload is
    // a uint256 with the layout below; CPU sides are emitted as 0. Layout reserves
    // 8 lanes for per-mon data so MONS_PER_TEAM can grow up to 8 without a layout
    // migration. Bumping past 8 silently truncates per-mon fields and would
    // require an event-version bump.
    //   bits 0-15     pointsAwarded (uint16)
    //   bits 16-79    per-mon exp gain (8 lanes * 8 bits)
    //   bits 80-175   per-mon facets unlocked this battle (8 lanes * 12-bit bitmap, 1 bit per facet id)
    //   bits 176-183  bonus flags
    //   bits 184-191  combined exp multiplier (uint8)
    //   bits 192-199  outcome: 0=loss, 1=win, 2=draw
    //   bits 200-202  streakDay (3 bits, matches storage)
    //   bits 203-255  reserved
    uint256 internal constant GE_EXP_SHIFT = 16;
    uint256 internal constant GE_EXP_BITS_PER_MON = 8;
    uint256 internal constant GE_EXP_LANE_MASK = (1 << GE_EXP_BITS_PER_MON) - 1;
    uint256 internal constant GE_FACETS_SHIFT = 80;
    uint256 internal constant GE_FACETS_BITS_PER_MON = 12;
    uint256 internal constant GE_FACETS_LANE_MASK = (1 << GE_FACETS_BITS_PER_MON) - 1;
    uint256 internal constant GE_BONUS_SHIFT = 176;
    uint256 internal constant GE_MULT_SHIFT = 184;
    uint256 internal constant GE_OUTCOME_SHIFT = 192;
    uint256 internal constant GE_STREAK_SHIFT = 200;

    uint256 internal constant BONUS_FIRST_ROLL = 1 << 0;
    uint256 internal constant BONUS_FIRST_GAME = 1 << 1;
    // bit 2 reserved (formerly BONUS_HARD_CPU)
    uint256 internal constant BONUS_QUEST = 1 << 3;

    // ----- Errors -----
    error NotWhitelistedOpponent();
    error AlreadyFirstRolled();
    error InvalidStarterId();
    error NoMoreStock();
    error NotEngine();
    error NoPreviousRegistry();
    error AlreadyMigrated();

    // ----- Events -----
    event Roll(address indexed player, uint256[] monIds, uint256 pointsSpent);
    event GachaEvent(bytes32 indexed battleKey, uint256 p0Packed, uint256 p1Packed);
    // Multi battles: one lane per seat in canonical order [p0, p2, p1, p3]; CPU lanes zero.
    // Lane layout identical to GachaEvent (exp/facet lanes 0-3 used — seat teams are 4 mons).
    event GachaMultiEvent(
        bytes32 indexed battleKey, uint256 seat0Packed, uint256 seat1Packed, uint256 seat2Packed, uint256 seat3Packed
    );

    // ----- Immutables -----
    IEngine public immutable ENGINE;
    IGachaRNG immutable RNG;
    /// @notice Prior registry to import player state from via `migrate()`. Assumed to share
    /// this contract's storage layout (same ABI). `address(0)` on the genesis deploy disables
    /// migration. Set once at construction.
    GachaTeamRegistry public immutable PREVIOUS_REGISTRY;

    /// @notice One-shot guard: true once a player has imported their state from PREVIOUS_REGISTRY.
    mapping(address => bool) public migrated;

    // ----- Per-(user, opponent) CPU team facet config -----
    // Each user picks any facet (0-12) for each slot of a whitelisted opponent's phantom team.
    // Slot-indexed: 4 bits per slot, MONS_PER_TEAM slots fit comfortably in one uint256.
    // Keyed identically to monRegistryIndicesForTeamPacked phantom slots so a single SLOAD
    // resolves both the team's mon ids and its facet config at battle start.
    uint256 internal constant OPP_FACET_BITS_PER_SLOT = 4;
    uint256 internal constant OPP_FACET_SLOT_MASK = (1 << OPP_FACET_BITS_PER_SLOT) - 1;
    mapping(address opponent => mapping(uint256 phantomKey => uint256 packedFacets)) public opponentTeamFacetsPacked;

    // ----- Per-(user, opponent) CPU team move-loadout config -----
    // Mirrors opponentTeamFacetsPacked: each user picks an 8-bit move-selection bitmap for each
    // slot of a whitelisted opponent's phantom team. 8 bits per slot, MONS_PER_TEAM slots
    // (4 × 8 = 32 bits) fit in one uint256. Keyed by the same phantomKey so a single logical
    // config resolves the team's mon ids, facets, and moves at battle start. No ownership/unlock
    // checks — the user is configuring an opponent they will fight, and the resolver self-limits
    // (extra/empty-lane bits resolve to nothing; a 0 slot falls back to the default loadout).
    uint256 internal constant OPP_MOVE_BITS_PER_SLOT = 8;
    uint256 internal constant OPP_MOVE_SLOT_MASK = (1 << OPP_MOVE_BITS_PER_SLOT) - 1;
    mapping(address opponent => mapping(uint256 phantomKey => uint256 packedMoves)) public opponentTeamMovesPacked;

    constructor(
        uint256 _MONS_PER_TEAM,
        uint256 _MOVES_PER_MON,
        IEngine _ENGINE,
        IGachaRNG _RNG,
        GachaTeamRegistry _PREVIOUS_REGISTRY
    ) PackedTeamStore(_MONS_PER_TEAM, _MOVES_PER_MON) {
        ENGINE = _ENGINE;
        RNG = address(_RNG) == address(0) ? IGachaRNG(address(this)) : _RNG;
        PREVIOUS_REGISTRY = _PREVIOUS_REGISTRY;
        _initializeOwner(msg.sender);
        _seedInitialQuests();
    }

    /// @dev Seeds the day-rotated quest pool. Pool size and content fix the schedule, since
    /// active quest = keccak256(day) % poolLength. Owner can mutate later via add/edit/remove.
    function _seedInitialQuests() internal {
        int16 teamSize = int16(int256(MONS_PER_TEAM));
        Quests.Predicate[] memory preds = new Quests.Predicate[](1);

        // Flawless / Last Stand
        preds[0] =
            Quests.Predicate({op: Quests.Op.ALIVE_COUNT, cmp: Quests.Cmp.GE, negate: false, arg: 0, operand: teamSize});
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
        preds[0] =
            Quests.Predicate({op: Quests.Op.FACET_COUNT, cmp: Quests.Cmp.EQ, negate: false, arg: 0, operand: teamSize});
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

    /// @notice Admin: write `monIndices` into `user`'s `slot` and apply parallel
    /// `facetIds` for those mons in one tx. The slot is marked live if it wasn't
    /// already (so fresh-slot allocation and overwrite share one path). Facet writes
    /// bypass the ownership + unlock checks in `assignFacets` and also mark each
    /// non-zero facet bit as unlocked, so the user's own `assignFacets` won't revert
    /// `FacetNotUnlocked` later. Does NOT add the mons to `monsOwned` — the user
    /// still can't swap mons they don't own via `updateTeam`.
    function setTeamForUser(address user, uint256 slot, uint256[] memory monIndices, uint8[] memory facetIds)
        external
        onlyOwner
    {
        if (slot >= MAX_TEAMS_PER_PLAYER) {
            revert InvalidTeamIndex();
        }
        if (facetIds.length != monIndices.length) {
            revert FacetArgsLengthMismatch();
        }

        // Team write. _packTeam validates length + dedup.
        uint256 packedTeam = _packTeam(monIndices);
        _writeTeamLane(user, slot, packedTeam);
        uint256 packed = teamOrderPacked[user];
        uint256 liveBit = uint256(1) << (LIVE_BITMAP_SHIFT + slot);
        if ((packed & liveBit) == 0) {
            uint256 liveBitmap = (packed >> LIVE_BITMAP_SHIFT) & LIVE_BITMAP_MASK;
            packed |= (slot << (_popcount(liveBitmap) * ORDER_ENTRY_BITS)) | liveBit;
            teamOrderPacked[user] = packed;
        }

        // Facet write — bucket-coalesced, mirrors assignFacets but skips both checks.
        uint256 lastBucket = type(uint256).max;
        uint256 currentSlot;
        bool dirty;
        for (uint256 i; i < monIndices.length;) {
            uint8 facetId = facetIds[i];
            if (facetId > TOTAL_FACETS) {
                revert InvalidFacetId();
            }
            uint256 monId = monIndices[i];
            uint256 bucket = monId / MONS_PER_FACET_BUCKET;
            uint256 lane = monId % MONS_PER_FACET_BUCKET;
            if (bucket != lastBucket) {
                if (lastBucket != type(uint256).max && dirty) {
                    facetData[user][lastBucket] = currentSlot;
                }
                currentSlot = facetData[user][bucket];
                lastBucket = bucket;
                dirty = false;
            }
            (uint16 unlockedBitmap,) = _readFacetSlotForMon(currentSlot, lane);
            if (facetId != 0) {
                unlockedBitmap |= uint16(1 << (facetId - 1));
            }
            currentSlot = _writeFacetSlotForMon(currentSlot, lane, unlockedBitmap, facetId);
            dirty = true;
            unchecked {
                ++i;
            }
        }
        if (lastBucket != type(uint256).max && dirty) {
            facetData[user][lastBucket] = currentSlot;
        }
    }

    // Phantom teams: duplicate mon ids allowed; phantom key truncated to uint16 to match
    // BattleData.pXTeamIndex storage width. ~2^16 collision space — acceptable since exp accrual
    // is winner/human-only and uses the player's own (small) teamIndex, not the phantom key.
    //
    // facetIds / moveSelections are parallel arrays: for the CPU's slot i, facetIds[i] is the
    // facet (0=none, 1..12) and moveSelections[i] is the 8-bit move-loadout bitmap (0 = default
    // loadout). No ownership / unlock checks — the user is configuring an opponent they will fight,
    // not their own mons.
    function setOpponentTeam(
        address opponent,
        uint256[] memory monIndices,
        uint8[] memory facetIds,
        uint8[] memory moveSelections
    ) external {
        if (!isWhitelistedOpponent(opponent)) {
            revert NotWhitelistedOpponent();
        }
        _setOpponentTeam(opponent, msg.sender, monIndices, facetIds, moveSelections);
    }

    /// @notice Trusted-relayer entry: a whitelisted CPU writes a user's phantom team
    /// config on their behalf so the CPU's matchmaker can bundle config + start in one tx.
    /// Opponent is implicitly msg.sender — a CPU can only configure its own phantom slot.
    function setOpponentTeamFor(
        address user,
        uint256[] memory monIndices,
        uint8[] memory facetIds,
        uint8[] memory moveSelections
    ) external override {
        if (!isWhitelistedOpponent(msg.sender)) {
            revert NotWhitelistedOpponent();
        }
        _setOpponentTeam(msg.sender, user, monIndices, facetIds, moveSelections);
    }

    /// @notice Peer-relay variant: a whitelisted CPU writes a user's phantom config for
    /// ANOTHER whitelisted opponent, so one host can bundle a Multi battle's whole CPU
    /// seating (config + start) in one tx. Both ends must be owner-whitelisted.
    function setOpponentTeamForPeer(
        address user,
        address opponent,
        uint256[] memory monIndices,
        uint8[] memory facetIds,
        uint8[] memory moveSelections
    ) external override {
        if (!isWhitelistedOpponent(msg.sender) || !isWhitelistedOpponent(opponent)) {
            revert NotWhitelistedOpponent();
        }
        _setOpponentTeam(opponent, user, monIndices, facetIds, moveSelections);
    }

    function _setOpponentTeam(
        address opponent,
        address user,
        uint256[] memory monIndices,
        uint8[] memory facetIds,
        uint8[] memory moveSelections
    ) internal {
        if (monIndices.length != facetIds.length || monIndices.length != moveSelections.length) {
            revert FacetArgsLengthMismatch();
        }
        uint256 phantomKey = uint16(uint160(user));
        _writeTeamLane(opponent, phantomKey, _packIndices(monIndices));

        uint256 packedFacets;
        uint256 packedMoves;
        for (uint256 i; i < facetIds.length;) {
            uint8 facetId = facetIds[i];
            if (facetId > TOTAL_FACETS) {
                revert InvalidFacetId();
            }
            packedFacets |= uint256(facetId) << (i * OPP_FACET_BITS_PER_SLOT);
            packedMoves |= uint256(moveSelections[i]) << (i * OPP_MOVE_BITS_PER_SLOT);
            unchecked {
                ++i;
            }
        }
        opponentTeamFacetsPacked[opponent][phantomKey] = packedFacets;
        opponentTeamMovesPacked[opponent][phantomKey] = packedMoves;
    }

    /// @notice Unpack the caller's configured facets for a CPU opponent.
    function getOpponentTeamFacets(address user, address opponent) external view returns (uint8[] memory facetIds) {
        uint256 packed = opponentTeamFacetsPacked[opponent][uint16(uint160(user))];
        facetIds = new uint8[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            facetIds[i] = uint8((packed >> (i * OPP_FACET_BITS_PER_SLOT)) & OPP_FACET_SLOT_MASK);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Unpack the caller-configured move-loadout bitmaps for a CPU opponent.
    function getOpponentTeamMoves(address user, address opponent)
        external
        view
        returns (uint8[] memory moveSelections)
    {
        uint256 packed = opponentTeamMovesPacked[opponent][uint16(uint160(user))];
        moveSelections = new uint8[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            moveSelections[i] = uint8((packed >> (i * OPP_MOVE_BITS_PER_SLOT)) & OPP_MOVE_SLOT_MASK);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice One-call hydration of a player's whole collection: owned mon ids plus each mon's
    /// exp, level, facet unlock bitmap, equipped facet, and move-selection bitmap. Collapses the
    /// getOwned → per-mon-detail fan-out (previously two client round-trips) into a single read.
    function getOwnedMonDetails(address player)
        external
        view
        returns (
            uint256[] memory monIds,
            uint256[] memory exp,
            uint256[] memory levels,
            uint16[] memory facetUnlocked,
            uint8[] memory facetEquipped,
            uint8[] memory moveSelections
        )
    {
        monIds = monsOwned[player].values();
        uint256 len = monIds.length;
        exp = new uint256[](len);
        levels = new uint256[](len);
        facetUnlocked = new uint16[](len);
        facetEquipped = new uint8[](len);
        moveSelections = new uint8[](len);
        for (uint256 i; i < len;) {
            uint256 id = monIds[i];
            uint256 e = _getExp(player, id);
            exp[i] = e;
            levels[i] = _levelForExp(e);
            (facetUnlocked[i], facetEquipped[i]) = getFacetData(player, id);
            moveSelections[i] = _getMoveSelection(player, id);
            unchecked {
                ++i;
            }
        }
    }

    // Returns each side's team with active-facet ±5% deltas folded into stats. Engine consumes
    // these directly at startBattle — no separate delta channel. Whitelisted (CPU) sides pull
    // facets from the per-(user, opponent) phantom slot the human caller configured via
    // setOpponentTeam; human sides use per-mon facetData.
    function getTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex)
        external
        view
        returns (Mon[] memory, Mon[] memory)
    {
        // Read each side's CPU flag ONCE (playerData SLOAD) and thread it into both the liveness
        // check and the facet-source selection below (was: two reads per side).
        bool p0IsCpu = isWhitelistedOpponent(p0);
        bool p1IsCpu = isWhitelistedOpponent(p1);
        _assertTeamLive(p0, p0TeamIndex, p0IsCpu);
        _assertTeamLive(p1, p1TeamIndex, p1IsCpu);
        Mon[] memory p0Team = new Mon[](MONS_PER_TEAM);
        Mon[] memory p1Team = new Mon[](MONS_PER_TEAM);

        uint256 p0Packed = _readTeamLane(p0, p0TeamIndex);
        uint256 p1Packed = _readTeamLane(p1, p1TeamIndex);

        // Build all monIds for batch call
        uint256 totalMons = MONS_PER_TEAM * 2;
        uint256[] memory ids = new uint256[](totalMons);
        for (uint256 i; i < MONS_PER_TEAM;) {
            ids[i] = (p0Packed >> (i * BITS_PER_MON_INDEX)) & ONES_MASK;
            ids[i + MONS_PER_TEAM] = (p1Packed >> (i * BITS_PER_MON_INDEX)) & ONES_MASK;
            unchecked {
                ++i;
            }
        }

        // Full lane-indexed (8-wide) catalog rows so the move resolver can map selection bit i to
        // catalog lane i; abilities is one word per mon (0 = none).
        (MonStats[] memory stats, uint256[][] memory fullMoves, uint256[] memory abilities) = _getTeamMonData(ids);

        uint256 p0CpuFacets = p0IsCpu ? opponentTeamFacetsPacked[p0][p0TeamIndex] : 0;
        uint256 p1CpuFacets = p1IsCpu ? opponentTeamFacetsPacked[p1][p1TeamIndex] : 0;
        // CPU move loadouts come from the per-(user, CPU) phantom slot; human loadouts from
        // selectedMoveBitmap (cached per bucket, same as facets). 0 in either → default loadout.
        uint256 p0CpuMoves = p0IsCpu ? opponentTeamMovesPacked[p0][p0TeamIndex] : 0;
        uint256 p1CpuMoves = p1IsCpu ? opponentTeamMovesPacked[p1][p1TeamIndex] : 0;

        // Human-side facet + move buckets are cached across the loop: team mon ids usually share
        // the 16-mon bucket, so this collapses up to MONS_PER_TEAM reads into one per side.
        FacetBucketCache memory p0Bucket;
        FacetBucketCache memory p1Bucket;
        p0Bucket.idx = type(uint256).max;
        p1Bucket.idx = type(uint256).max;
        MoveBucketCache memory p0MoveBucket;
        MoveBucketCache memory p1MoveBucket;
        p0MoveBucket.idx = type(uint256).max;
        p1MoveBucket.idx = type(uint256).max;

        // Unpack into teams
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint8 p0FacetId = p0IsCpu
                ? uint8((p0CpuFacets >> (i * OPP_FACET_BITS_PER_SLOT)) & OPP_FACET_SLOT_MASK)
                : _facetIdForMonCached(p0, ids[i], p0Bucket);
            uint8 p1FacetId = p1IsCpu
                ? uint8((p1CpuFacets >> (i * OPP_FACET_BITS_PER_SLOT)) & OPP_FACET_SLOT_MASK)
                : _facetIdForMonCached(p1, ids[i + MONS_PER_TEAM], p1Bucket);
            _applyFacetToStats(stats[i], p0FacetId);
            _applyFacetToStats(stats[i + MONS_PER_TEAM], p1FacetId);

            uint8 p0MoveSel = p0IsCpu
                ? uint8((p0CpuMoves >> (i * OPP_MOVE_BITS_PER_SLOT)) & OPP_MOVE_SLOT_MASK)
                : _moveSelectionForMonCached(p0, ids[i], p0MoveBucket);
            uint8 p1MoveSel = p1IsCpu
                ? uint8((p1CpuMoves >> (i * OPP_MOVE_BITS_PER_SLOT)) & OPP_MOVE_SLOT_MASK)
                : _moveSelectionForMonCached(p1, ids[i + MONS_PER_TEAM], p1MoveBucket);

            p0Team[i] =
                Mon({stats: stats[i], ability: abilities[i], moves: _resolveBattleMoves(fullMoves[i], p0MoveSel)});
            p1Team[i] = Mon({
                stats: stats[i + MONS_PER_TEAM],
                ability: abilities[i + MONS_PER_TEAM],
                moves: _resolveBattleMoves(fullMoves[i + MONS_PER_TEAM], p1MoveSel)
            });
            unchecked {
                ++i;
            }
        }

        return (p0Team, p1Team);
    }

    struct MoveBucketCache {
        uint256 idx;
        uint256 word;
    }

    /// @dev Reads a human player's stored move-selection bitmap for `monId`, caching the bucket
    /// word. Returns the raw stored value (0 = unconfigured → _resolveBattleMoves applies default).
    function _moveSelectionForMonCached(address player, uint256 monId, MoveBucketCache memory cache)
        private
        view
        returns (uint8)
    {
        uint256 bucket = monId / MONS_PER_EXP_BUCKET;
        if (bucket != cache.idx) {
            cache.idx = bucket;
            cache.word = selectedMoveBitmap[player][bucket];
        }
        return uint8((cache.word >> ((monId % MONS_PER_EXP_BUCKET) * MOVE_SEL_BITS_PER_MON)) & MOVE_SEL_MASK);
    }

    struct FacetBucketCache {
        uint256 idx;
        uint256 word;
    }

    /// @dev _facetIdForMon with a caller-held bucket cache (cache.idx == uint256.max = empty).
    function _facetIdForMonCached(address player, uint256 monId, FacetBucketCache memory cache)
        private
        view
        returns (uint8 facetId)
    {
        uint256 bucket = monId / MONS_PER_FACET_BUCKET;
        if (bucket != cache.idx) {
            cache.idx = bucket;
            cache.word = facetData[player][bucket];
        }
        (, facetId) = _readFacetSlotForMon(cache.word, monId % MONS_PER_FACET_BUCKET);
    }

    function _applyFacetToStats(MonStats memory stats, uint8 facetId) private pure {
        if (facetId == 0) {
            return;
        }
        StatDelta memory d = _computeFacetDelta(stats, facetId);
        // Truncated ±5% can't underflow a uint32 stat for positive bases.
        if (d.hp != 0) {
            stats.hp = uint32(int32(stats.hp) + int32(d.hp));
        }
        if (d.atk != 0) {
            stats.attack = uint32(int32(stats.attack) + int32(d.atk));
        }
        if (d.spAtk != 0) {
            stats.specialAttack = uint32(int32(stats.specialAttack) + int32(d.spAtk));
        }
        if (d.def != 0) {
            stats.defense = uint32(int32(stats.defense) + int32(d.def));
        }
        if (d.spDef != 0) {
            stats.specialDefense = uint32(int32(stats.specialDefense) + int32(d.spDef));
        }
        if (d.speed != 0) {
            stats.speed = uint32(int32(stats.speed) + int32(d.speed));
        }
    }

    // =====================================================================
    // Gacha
    // =====================================================================

    function firstRoll(uint256 starterId) external returns (uint256[] memory rolledIds) {
        if (monsOwned[msg.sender].length() > 0) {
            revert AlreadyFirstRolled();
        }
        if (starterId >= NUM_STARTERS) {
            revert InvalidStarterId();
        }

        rolledIds = new uint256[](INITIAL_ROLLS);
        rolledIds[0] = starterId;
        monsOwned[msg.sender].add(starterId);
        // Remaining rolls are uniform across non-starter pool [NUM_STARTERS, numMons).
        _rollInto(rolledIds, 1, NUM_STARTERS);
        emit Roll(msg.sender, rolledIds, 0);
    }

    function roll(uint256 numRolls) external returns (uint256[] memory rolledIds) {
        if (monsOwned[msg.sender].length() == monIds.length()) {
            revert NoMoreStock();
        }
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

    // =====================================================================
    // Migration
    // =====================================================================

    /// @notice Self-service, one-shot import of the caller's progression state from
    /// `PREVIOUS_REGISTRY`. Copies, for `msg.sender`:
    ///   - the packed profile slot verbatim (points, streak, quest day, first-game bonus,
    ///     timestamps — and the CPU/whitelist flags, since the whole word is copied),
    ///   - mon ownership,
    ///   - per-mon exp and facet buckets (unlocked bitmaps + assigned facet),
    ///   - team slots (packed mon ids + the order/live-bitmap word).
    ///
    /// @dev Relies on `PREVIOUS_REGISTRY` sharing this contract's storage layout and on the
    /// new mon catalog using the same sequential ids, so packed mon-id data resolves to the
    /// same mons. The guard makes this idempotent-by-revert: a second call (or a call after
    /// the player has progressed on this registry) reverts rather than re-importing or
    /// clobbering. Run catalog setup (createMon) before players migrate.
    function migrate() external {
        GachaTeamRegistry prev = PREVIOUS_REGISTRY;
        if (address(prev) == address(0)) {
            revert NoPreviousRegistry();
        }
        address player = msg.sender;
        if (migrated[player]) {
            revert AlreadyMigrated();
        }
        migrated[player] = true;

        // Profile slot — verbatim whole word.
        playerData[player] = prev.playerData(player);

        // Ownership — monsOwned is an EnumerableSet, so re-add each id (no slot copy).
        uint256[] memory owned = prev.getOwned(player);
        for (uint256 i; i < owned.length;) {
            monsOwned[player].add(owned[i]);
            unchecked {
                ++i;
            }
        }

        // Exp, facets, and move selections share the same 16-mon bucketing, so one loop copies all
        // three. Caveat: a move-selection bit i refers to catalog *lane i*, so a migrated selection
        // resolves to the same moves only if the new catalog preserves each mon's move-lane order —
        // an extension of the existing "same sequential mon ids" migration assumption.
        uint256 numBuckets = (prev.getMonCount() + MONS_PER_EXP_BUCKET - 1) / MONS_PER_EXP_BUCKET;
        for (uint256 b; b < numBuckets;) {
            packedExpForMon[player][b] = prev.packedExpForMon(player, b);
            facetData[player][b] = prev.facetData(player, b);
            // selectedMoveBitmap postdates the earliest registries; tolerate a previous
            // registry that lacks the getter (the staticcall reverts) and leave the default.
            try prev.selectedMoveBitmap(player, b) returns (uint256 bitmap) {
                selectedMoveBitmap[player][b] = bitmap;
            } catch {}
            unchecked {
                ++b;
            }
        }

        // Teams — packed group words (4 teams × 64 bits each) plus the order/live-bitmap word.
        uint256 numGroups = (MAX_TEAMS_PER_PLAYER * BITS_PER_LANE + 255) / 256;
        for (uint256 g; g < numGroups;) {
            teamGroupsPacked[player][g] = prev.teamGroupsPacked(player, g);
            unchecked {
                ++g;
            }
        }
        teamOrderPacked[player] = prev.teamOrderPacked(player);
    }

    /// @notice True if `player` has unimported progress on `PREVIOUS_REGISTRY` — i.e. a
    /// client should call `migrate()` for them. Composes the whole decision so callers
    /// need not know a previous registry exists. False when migration is disabled
    /// (`PREVIOUS_REGISTRY` unset) or the player has already imported.
    function needsMigration(address player) external view returns (bool) {
        GachaTeamRegistry prev = PREVIOUS_REGISTRY;
        if (address(prev) == address(0)) {
            return false;
        }
        if (migrated[player]) {
            return false;
        }
        return prev.balanceOf(player) > 0;
    }

    // ----- IEngineHook -----
    function getStepsBitmap() external pure override returns (uint16) {
        return STEPS_BITMAP;
    }

    function onBattleStart(bytes32) external override {}

    function onRoundStart(bytes32) external override {}

    function onRoundEnd(bytes32) external override {}

    function onBattleEnd(bytes32 battleKey) external override {
        if (msg.sender != address(ENGINE)) {
            revert NotEngine();
        }

        BattleEndContext memory ctx = ENGINE.getBattleEndContext(battleKey);

        if (ctx.isMultiMode) {
            _onMultiBattleEnd(battleKey, ctx);
            return;
        }

        // No rewards on timeout/forfeit: at least one side must have all mons KO'd.
        uint8 allKOd = uint8((1 << MONS_PER_TEAM) - 1);
        if (ctx.p0KOBitmap != allKOd && ctx.p1KOBitmap != allKOd) {
            return;
        }

        uint256 packed0 = playerData[ctx.p0];
        uint256 packed1 = playerData[ctx.p1];

        QuestGate memory qg;
        uint256[2] memory packedEvents;
        if (packed0 & IS_CPU_BIT == 0) {
            packedEvents[0] = _settleHumanSeat(battleKey, ctx, 0, packed0, qg);
        }
        if (packed1 & IS_CPU_BIT == 0) {
            packedEvents[1] = _settleHumanSeat(battleKey, ctx, 1, packed1, qg);
        }

        emit GachaEvent(battleKey, packedEvents[0], packedEvents[1]);
    }

    /// @dev Multi settlement: same formulas per human seat, KO/exp over the seat's quarter of
    ///      the 8-mon side roster (the engine fixes seat teams at 4). CPU seats emit a zero lane.
    function _onMultiBattleEnd(bytes32 battleKey, BattleEndContext memory ctx) private {
        if (ctx.p0KOBitmap != 0xFF && ctx.p1KOBitmap != 0xFF) {
            return; // same timeout gate as above
        }

        QuestGate memory qg;
        uint256[4] memory lanes;
        for (uint256 seatIndex; seatIndex < 4; ++seatIndex) {
            (address player,,,) = _seatSettleParams(ctx, seatIndex);
            uint256 packed = playerData[player];
            if (packed & IS_CPU_BIT != 0) {
                continue;
            }
            lanes[seatIndex] = _settleHumanSeat(battleKey, ctx, seatIndex, packed, qg);
        }
        emit GachaMultiEvent(battleKey, lanes[0], lanes[1], lanes[2], lanes[3]);
    }

    // Lazily-shared quest config for the seat loop: the first human winner pays the one packed
    // SLOAD; losses to CPUs and draws never load it.
    struct QuestGate {
        uint32 day;
        uint256 poolLen;
        bool loaded;
    }

    /// @dev Seat identity for settlement and quest opcodes. Non-Multi: seatIndex 0/1 = p0/p1.
    ///      Multi: canonical order [p0, p2, p1, p3]; the KO bitmap is the seat's 4-bit quarter
    ///      slice and winning is by side.
    function _seatSettleParams(BattleEndContext memory ctx, uint256 seatIndex)
        private
        pure
        returns (address player, uint256 teamIdx, uint8 koBitmap, bool won)
    {
        if (!ctx.isMultiMode) {
            player = seatIndex == 0 ? ctx.p0 : ctx.p1;
            teamIdx = seatIndex == 0 ? ctx.p0TeamIndex : ctx.p1TeamIndex;
            koBitmap = seatIndex == 0 ? ctx.p0KOBitmap : ctx.p1KOBitmap;
            won = ctx.winner == player;
            return (player, teamIdx, koBitmap, won);
        }
        uint256 side = seatIndex >> 1;
        if (seatIndex == 0) {
            (player, teamIdx) = (ctx.p0, ctx.p0TeamIndex);
        } else if (seatIndex == 1) {
            (player, teamIdx) = (ctx.p2, ctx.p2TeamIndex);
        } else if (seatIndex == 2) {
            (player, teamIdx) = (ctx.p1, ctx.p1TeamIndex);
        } else {
            (player, teamIdx) = (ctx.p3, ctx.p3TeamIndex);
        }
        uint8 sideKO = side == 0 ? ctx.p0KOBitmap : ctx.p1KOBitmap;
        koBitmap = uint8((sideKO >> ((seatIndex & 1) * 4)) & 0x0F);
        won = ctx.winner != address(0) && ctx.winner == (side == 0 ? ctx.p0 : ctx.p1);
    }

    /// @dev One human seat's end-of-battle rewards (streak / quest / points / exp) and its
    ///      packed GachaEvent lane. `packed` is the seat's preloaded playerData word.
    function _settleHumanSeat(
        bytes32 battleKey,
        BattleEndContext memory ctx,
        uint256 seatIndex,
        uint256 packed,
        QuestGate memory qg
    ) private returns (uint256 eventLane) {
        (address player, uint256 teamIdx, uint8 koBitmap, bool won) = _seatSettleParams(ctx, seatIndex);
        uint256 basePts = won ? POINTS_PER_WIN : POINTS_PER_LOSS;
        uint32 currentTime = uint32(block.timestamp);

        uint256 preservedFlags = packed & (BONUS_AWARDED_BIT | IS_CPU_BIT);
        uint256 points = packed & POINTS_MASK_128;
        uint32 lastFirstGameTs = uint32(packed >> LAST_FIRST_GAME_TS_SHIFT);
        uint32 lastSeenTs = uint32(packed >> LAST_SEEN_TS_SHIFT);
        uint256 streakDay = (packed >> STREAK_DAY_SHIFT) & STREAK_DAY_MASK;
        uint32 lastQuestCompletedDay = uint32(packed >> LAST_QUEST_DAY_SHIFT);

        uint256 bonusFlags;
        uint256 streakFlat;
        // Flat per-mon exp multiplier on every battle, game-type agnostic. Quest stacks on top.
        uint256 expMult = GAME_EXP_MULT;
        uint256 gachaMult = 1;

        // The rolling 24h cooldown (measured from the last bonus-earning game) gates the
        // streak bonus to once per day. The 36h grace decides ratchet-vs-reset, but is
        // measured from the last battle of ANY kind (lastSeenTs) rather than the last
        // bonus: a sub-24h "early" play still counts as activity, so it can't strand the
        // anchor into a phantom multi-day gap that wrongly resets an active player's
        // streak. Pure timestamp delta avoids a UTC-midnight cliff.
        uint256 bonusGap = lastFirstGameTs == 0 ? type(uint256).max : currentTime - lastFirstGameTs;
        if (bonusGap >= FIRST_GAME_OF_DAY_COOLDOWN) {
            uint256 seenGap = lastSeenTs == 0 ? type(uint256).max : currentTime - lastSeenTs;
            if (seenGap > STREAK_GRACE_WINDOW) {
                streakDay = 1;
            } else if (streakDay < STREAK_FLAT_BONUS_MAX) {
                streakDay += 1;
            }
            streakFlat = streakDay;
            lastFirstGameTs = currentTime;
            bonusFlags |= BONUS_FIRST_GAME;
        }
        lastSeenTs = currentTime; // every counted battle marks activity for the grace window

        if (won) {
            if (!qg.loaded) {
                (qg.day, qg.poolLen) = _questDayAndPoolLen();
                qg.loaded = true;
            }
            if (
                lastQuestCompletedDay != qg.day && qg.poolLen > 0
                    && _evalActiveQuest(ctx, seatIndex, battleKey, qg.day, qg.poolLen)
            ) {
                gachaMult *= QUEST_REWARD_MULT;
                expMult *= QUEST_REWARD_MULT;
                lastQuestCompletedDay = qg.day;
                bonusFlags |= BONUS_QUEST;
            }
        }

        uint256 pointsThisBattle = (basePts + streakFlat) * gachaMult;
        if (preservedFlags & BONUS_AWARDED_BIT == 0) {
            pointsThisBattle += FIRST_GAME_EVER_BONUS;
            preservedFlags |= BONUS_AWARDED_BIT;
            bonusFlags |= BONUS_FIRST_ROLL;
        }
        points += pointsThisBattle;

        // points is bounded by uint128 invariant on the prior balance + a per-battle delta
        // that's far below 2^128, so no mask needed on writeback.
        playerData[player] = preservedFlags | (streakDay << STREAK_DAY_SHIFT)
            | (uint256(lastQuestCompletedDay) << LAST_QUEST_DAY_SHIFT) | (uint256(lastSeenTs) << LAST_SEEN_TS_SHIFT)
            | (uint256(lastFirstGameTs) << LAST_FIRST_GAME_TS_SHIFT) | points;

        // Lane prefix composed before the exp walk keeps its locals from living across the
        // call (stack pressure — the walk inlines here).
        uint256 outcome = won ? 1 : (ctx.winner == address(0) ? 2 : 0);
        eventLane = (pointsThisBattle & 0xFFFF) | (bonusFlags << GE_BONUS_SHIFT) | ((expMult & 0xFF) << GE_MULT_SHIFT)
            | (outcome << GE_OUTCOME_SHIFT) | (streakDay << GE_STREAK_SHIFT);
        eventLane |= _applyExpAndFacetDraws(player, teamIdx, koBitmap, expMult, streakFlat);
    }

    /// @dev Walks the team in one pass, sharing lastBucket across exp + facet slot reads.
    /// Returns the per-mon exp/facet portion of the GachaEvent (bits 16..111). Lanes are
    /// saturated at their packed widths so a future tuning blow-up can't bleed into other fields.
    function _applyExpAndFacetDraws(
        address player,
        uint256 teamIdx,
        uint8 koBitmap,
        uint256 expMult,
        uint256 streakFlat
    ) internal returns (uint256 expFacetPacked) {
        uint256 packedTeam = _readTeamLane(player, teamIdx);
        uint256 lastBucket = type(uint256).max;
        uint256 expSlot;
        uint256 facetSlot;
        bool facetLoaded;
        bool facetDirty;

        for (uint256 j; j < MONS_PER_TEAM;) {
            uint256 monId = (packedTeam >> (j * BITS_PER_MON_INDEX)) & ONES_MASK;
            uint256 bucket = monId / MONS_PER_EXP_BUCKET;
            uint256 lane = monId % MONS_PER_EXP_BUCKET;

            if (bucket != lastBucket) {
                if (lastBucket != type(uint256).max) {
                    packedExpForMon[player][lastBucket] = expSlot;
                    if (facetDirty) {
                        facetData[player][lastBucket] = facetSlot;
                    }
                }
                expSlot = packedExpForMon[player][bucket];
                facetLoaded = false;
                facetDirty = false;
                lastBucket = bucket;
            }

            uint256 oldExp = (expSlot >> (lane * EXP_BITS_PER_MON)) & EXP_PER_MON_MASK;
            uint256 alive = (koBitmap & (1 << j)) == 0 ? 1 : 0;
            uint256 baseExp = alive == 1 ? EXP_PER_SURVIVING_MON : EXP_PER_KOD_MON;
            uint256 gain = (baseExp + streakFlat) * expMult;
            uint256 newExp = oldExp + gain;
            if (newExp > EXP_PER_MON_CAP) {
                newExp = EXP_PER_MON_CAP;
            }
            expSlot =
                (expSlot & ~(EXP_PER_MON_MASK << (lane * EXP_BITS_PER_MON))) | (newExp << (lane * EXP_BITS_PER_MON));

            // Track actual gain for the event (post-cap), saturating at lane width.
            uint256 actualGain = newExp - oldExp;
            if (actualGain > GE_EXP_LANE_MASK) {
                actualGain = GE_EXP_LANE_MASK;
            }
            expFacetPacked |= actualGain << (GE_EXP_SHIFT + j * GE_EXP_BITS_PER_MON);

            // Facet draws on level crossings
            (uint256 newFacetSlot, uint256 drawnBitmap, bool drewAnyFacets) =
                _processLevelUps(player, monId, bucket, lane, oldExp, newExp, facetSlot, facetLoaded);
            if (drewAnyFacets) {
                facetSlot = newFacetSlot;
                facetLoaded = true;
                facetDirty = true;
                expFacetPacked |= drawnBitmap << (GE_FACETS_SHIFT + j * GE_FACETS_BITS_PER_MON);
            }

            unchecked {
                ++j;
            }
        }

        if (lastBucket != type(uint256).max) {
            packedExpForMon[player][lastBucket] = expSlot;
            if (facetDirty) {
                facetData[player][lastBucket] = facetSlot;
            }
        }
    }

    function _facetIdForMon(address player, uint256 monId) private view returns (uint8 facetId) {
        (, facetId) =
            _readFacetSlotForMon(facetData[player][monId / MONS_PER_FACET_BUCKET], monId % MONS_PER_FACET_BUCKET);
    }

    // =====================================================================
    // Subclass hook wiring
    // =====================================================================

    function _isFacetMonOwned(address player, uint256 monId) internal view override returns (bool) {
        return monsOwned[player].contains(monId);
    }

    function _getMonStatsForFacets(uint256 monId) internal view override returns (MonStats memory) {
        return monStats[monId];
    }

    function _packedTeamValidateOwnership(uint256[] memory monIndices) internal view override {
        _validateOwnership(monIndices);
    }

    function _packedTeamIsCpuOpponent(address player) internal view override returns (bool) {
        return isWhitelistedOpponent(player);
    }

    function _packedTeamGetMonData(uint256[] memory ids)
        internal
        view
        override
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities)
    {
        return _getMonDataBatch(ids);
    }

    function _assertExpAssigner() internal view override {
        if (!isAssigner[msg.sender]) {
            revert NotAssigner();
        }
    }

    function _monRegistrySize() internal view override returns (uint256) {
        return monIds.length();
    }

    function _fullMoveRow(uint256 monId) internal view override returns (uint256[] memory) {
        return _catalogMoveLanes(monId);
    }

    /// @dev Quest opcode dispatch. Has direct access to registry storage and the engine.
    ///      `playerIndex` is the seat index (Multi: canonical [p0, p2, p1, p3]). Team-shaped
    ///      opcodes read the seat's own 4-mon team and quarter KO slice; engine reads use the
    ///      seat's side with roster indices offset into its quarter.
    function _extract(uint8 op, uint16 arg, BattleEndContext memory ctx, uint256 playerIndex, bytes32 battleKey)
        internal
        view
        override
        returns (int256)
    {
        Op opcode = Op(op);
        (address player, uint256 teamIdx, uint8 koBitmap,) = _seatSettleParams(ctx, playerIndex);
        uint256 sideIndex = playerIndex;
        uint256 quarterShift;
        int256 activeMon; // seat-relative team index of the seat's own slot; -1 = empty lane
        if (ctx.isMultiMode) {
            sideIndex = playerIndex >> 1;
            quarterShift = (playerIndex & 1) * 4;
            uint8 lane = (playerIndex & 1) == 0
                ? (sideIndex == 0 ? ctx.p0ActiveMonIndex : ctx.p1ActiveMonIndex)
                : (sideIndex == 0 ? ctx.p0ActiveMonExtIndex : ctx.p1ActiveMonExtIndex);
            activeMon = lane == 0xFF ? int256(-1) : int256(uint256(lane) - quarterShift);
        } else {
            activeMon = int256(uint256(playerIndex == 0 ? ctx.p0ActiveMonIndex : ctx.p1ActiveMonIndex));
        }

        if (opcode == Op.TURNS) {
            return int256(uint256(ctx.turnId));
        }
        if (opcode == Op.ALIVE_COUNT) {
            return int256(uint256(MONS_PER_TEAM)) - int256(uint256(_popcount(koBitmap)));
        }
        if (opcode == Op.HAS_MON_ID) {
            uint256 packedTeam = _readTeamLane(player, teamIdx);
            for (uint256 i; i < MONS_PER_TEAM; ++i) {
                if (((packedTeam >> (i * BITS_PER_MON_INDEX)) & ONES_MASK) == uint256(arg)) {
                    return 1;
                }
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
            return activeMon;
        }
        if (opcode == Op.MON_STATE) {
            uint256 slot = (uint256(arg) >> MON_STATE_SLOT_SHIFT) & MON_STATE_FIELD_MASK;
            uint256 stateField = uint256(arg) & MON_STATE_FIELD_MASK;
            return int256(
                ENGINE.getMonStateForBattle(battleKey, sideIndex, quarterShift + slot, MonStateIndexName(stateField))
            );
        }
        if (opcode == Op.MIN_LEVEL || opcode == Op.MAX_LEVEL) {
            uint256 packedTeam = _readTeamLane(player, teamIdx);
            bool isMin = opcode == Op.MIN_LEVEL;
            uint256 acc = isMin ? type(uint256).max : 0;
            for (uint256 i; i < MONS_PER_TEAM;) {
                uint256 monId = (packedTeam >> (i * BITS_PER_MON_INDEX)) & ONES_MASK;
                uint256 lvl = _levelForExp(_getExp(player, monId));
                if (isMin ? lvl < acc : lvl > acc) {
                    acc = lvl;
                }
                unchecked {
                    ++i;
                }
            }
            return int256(acc);
        }
        if (opcode == Op.FACET_COUNT) {
            uint256 packedTeam = _readTeamLane(player, teamIdx);
            uint256 count;
            for (uint256 i; i < MONS_PER_TEAM;) {
                uint256 monId = (packedTeam >> (i * BITS_PER_MON_INDEX)) & ONES_MASK;
                uint256 bucket = monId / MONS_PER_FACET_BUCKET;
                uint256 lane = monId % MONS_PER_FACET_BUCKET;
                (, uint8 assignedFacet) = _readFacetSlotForMon(facetData[player][bucket], lane);
                if (assignedFacet != 0) {
                    ++count;
                }
                unchecked {
                    ++i;
                }
            }
            return int256(count);
        }
        if (opcode == Op.MIN_HP_DELTA || opcode == Op.MAX_HP_DELTA) {
            MonState[] memory states = ENGINE.getMonStatesForSide(battleKey, sideIndex);
            bool isMin = opcode == Op.MIN_HP_DELTA;
            int256 acc = isMin ? type(int256).max : type(int256).min;
            uint256 hi = ctx.isMultiMode ? quarterShift + 4 : states.length;
            for (uint256 i = quarterShift; i < hi;) {
                int256 d = states[i].hpDelta == CLEARED_MON_STATE_SENTINEL ? int256(0) : int256(states[i].hpDelta);
                if (isMin ? d < acc : d > acc) {
                    acc = d;
                }
                unchecked {
                    ++i;
                }
            }
            return acc;
        }
        revert InvalidOpcode();
    }

    // MonExp concretizes assignFacets / getFacetData / getFacetDeltaForMon; the leaf still
    // needs these stubs because MonRegistry's ITeamRegistry inheritance brings parallel
    // abstract declarations Solidity won't auto-resolve.

    function assignFacets(uint256[] calldata monIdsToAssign, uint8[] calldata facetIds)
        public
        override(MonExp, ITeamRegistry)
    {
        super.assignFacets(monIdsToAssign, facetIds);
    }

    function getFacetData(address player, uint256 monId)
        public
        view
        override(MonExp, ITeamRegistry)
        returns (uint16, uint8)
    {
        return super.getFacetData(player, monId);
    }

    function getFacetDeltaForMon(address player, uint256 monId)
        public
        view
        override(MonExp, ITeamRegistry)
        returns (StatDelta memory)
    {
        return super.getFacetDeltaForMon(player, monId);
    }
}
