// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";
import {ITeamRegistry} from "./ITeamRegistry.sol";

/// @notice Bit-packed per-player team storage. 4 teams pack into one storage slot (64 bits each,
/// 8 bits per mon id × MAX_MONS_PER_TEAM = 64). A separate single slot per player holds the
/// ordered slot-id list (16 × 4 bits) plus the 16-bit live bitmap.
abstract contract PackedTeamStore is ITeamRegistry {
    error InvalidTeamSize();
    error DuplicateMonId();
    error InvalidTeamIndex();
    error TeamCapReached();
    error TeamNotLive();
    error MonIdTooLarge();

    // ----- Team layout -----
    // 4 teams pack into one storage slot: 256 bits / 64 bits per lane = 4 lanes.
    // Each lane holds up to MAX_MONS_PER_TEAM (8) mons × BITS_PER_MON_INDEX (8) = 64 bits.
    // slot id S → group = S >> 2, lane = S & 0x3 (occupies bits [lane*64, (lane+1)*64)).
    uint32 internal constant BITS_PER_MON_INDEX = 8;
    uint256 internal constant ONES_MASK = (2 ** BITS_PER_MON_INDEX) - 1;
    uint256 internal constant BITS_PER_LANE = 64;
    uint256 internal constant LANE_MASK = (uint256(1) << BITS_PER_LANE) - 1;

    // ----- Team allocator -----
    // Live bitmap supports 16 slots → 4-bit slot ids, matches BattleData.pXTeamIndex's uint16 width.
    uint256 public constant MAX_TEAMS_PER_PLAYER = 16;
    uint256 public constant MAX_MONS_PER_TEAM = 8;
    uint256 internal constant LIVE_BITMAP_SHIFT = 64; // teamOrderPacked: bits 64..79 hold liveBitmap
    uint256 internal constant LIVE_BITMAP_MASK = (uint256(1) << MAX_TEAMS_PER_PLAYER) - 1;
    uint256 internal constant ORDER_ENTRY_BITS = 4;
    uint256 internal constant ORDER_ENTRY_MASK = (uint256(1) << ORDER_ENTRY_BITS) - 1;
    uint256 internal constant ORDER_REGION_MASK = (uint256(1) << LIVE_BITMAP_SHIFT) - 1;

    // ----- Immutables -----
    uint256 internal immutable MONS_PER_TEAM;
    uint256 internal immutable MOVES_PER_MON;

    // ----- Team state -----
    // 4 teams per slot. Outer key = group (slot >> 2); lane (slot & 0x3) occupies 64 bits per team.
    mapping(address => mapping(uint256 => uint256)) public teamGroupsPacked;
    // Per-player single slot: bits 0..63 = ordered slot-id list (16 × 4 bits),
    // bits 64..79 = liveBitmap, bits 80..255 reserved.
    mapping(address => uint256) public teamOrderPacked;

    constructor(uint256 _MONS_PER_TEAM, uint256 _MOVES_PER_MON) {
        require(_MONS_PER_TEAM <= MAX_MONS_PER_TEAM, "MONS_PER_TEAM > MAX_MONS_PER_TEAM");
        MONS_PER_TEAM = _MONS_PER_TEAM;
        MOVES_PER_MON = _MOVES_PER_MON;
    }

    // =====================================================================
    // Team CRUD (ITeamRegistry)
    // =====================================================================

    function createTeam(uint256[] memory monIndices) external virtual override returns (uint256 slot) {
        _packedTeamValidateOwnership(monIndices);
        return _createTeamForUser(msg.sender, monIndices);
    }

    function deleteTeam(uint256 slot) external virtual override {
        if (slot >= MAX_TEAMS_PER_PLAYER) {
            revert InvalidTeamIndex();
        }
        uint256 packed = teamOrderPacked[msg.sender];
        uint256 liveBit = uint256(1) << (LIVE_BITMAP_SHIFT + slot);
        if (packed & liveBit == 0) {
            revert TeamNotLive();
        }

        // Operate on the order region in isolation so the splice can't pull liveBitmap bits
        // into positions ≥ count. The invariant "positions ≥ live count == 0" lets createTeam
        // append without masking.
        uint256 order = packed & ORDER_REGION_MASK;
        uint256 count = _popcount((packed >> LIVE_BITMAP_SHIFT) & LIVE_BITMAP_MASK);
        uint256 position;
        for (uint256 i; i < count;) {
            if (((order >> (i * ORDER_ENTRY_BITS)) & ORDER_ENTRY_MASK) == slot) {
                position = i;
                break;
            }
            unchecked {
                ++i;
            }
        }

        uint256 below = order & ((uint256(1) << (position * ORDER_ENTRY_BITS)) - 1);
        uint256 above = (order >> ((position + 1) * ORDER_ENTRY_BITS)) << (position * ORDER_ENTRY_BITS);
        teamOrderPacked[msg.sender] = (packed & ~ORDER_REGION_MASK & ~liveBit) | below | above;
    }

    function updateTeam(uint256 teamIndex, uint256[] memory teamMonIndicesToOverride, uint256[] memory newMonIndices)
        external
        virtual
        override
    {
        _packedTeamValidateOwnership(newMonIndices);
        if ((_liveBitmap(msg.sender) & (uint256(1) << teamIndex)) == 0) {
            revert TeamNotLive();
        }
        _checkForDuplicates(newMonIndices);

        uint256 groupKey = teamIndex >> 2;
        uint256 laneShift = (teamIndex & 0x3) * BITS_PER_LANE;
        uint256 group = teamGroupsPacked[msg.sender][groupKey];
        uint256 n = teamMonIndicesToOverride.length;
        for (uint256 i; i < n;) {
            uint256 monId = newMonIndices[i];
            if (monId > ONES_MASK) {
                revert MonIdTooLarge();
            }
            uint256 monShift = laneShift + teamMonIndicesToOverride[i] * BITS_PER_MON_INDEX;
            group = (group & ~(ONES_MASK << monShift)) | (monId << monShift);
            unchecked {
                ++i;
            }
        }
        teamGroupsPacked[msg.sender][groupKey] = group;
    }

    function _createTeamForUser(address user, uint256[] memory monIndices) internal returns (uint256 slot) {
        uint256 packed = teamOrderPacked[user];
        uint256 liveBitmap = (packed >> LIVE_BITMAP_SHIFT) & LIVE_BITMAP_MASK;
        uint256 free = (~liveBitmap) & LIVE_BITMAP_MASK;
        if (free == 0) {
            revert TeamCapReached();
        }
        slot = _ctz(free);

        _writeTeamLane(user, slot, _packTeam(monIndices));

        // Position == popcount(liveBitmap); positions ≥ count are 0 by deleteTeam's splice invariant.
        packed |= (slot << (_popcount(liveBitmap) * ORDER_ENTRY_BITS)) | (uint256(1) << (LIVE_BITMAP_SHIFT + slot));
        teamOrderPacked[user] = packed;
    }

    // =====================================================================
    // Lane-level helpers (packed teamGroupsPacked I/O)
    // =====================================================================

    function _readTeamLane(address user, uint256 slot) internal view returns (uint256 packedTeam) {
        uint256 group = teamGroupsPacked[user][slot >> 2];
        packedTeam = (group >> ((slot & 0x3) * BITS_PER_LANE)) & LANE_MASK;
    }

    function _writeTeamLane(address user, uint256 slot, uint256 packedTeam) internal {
        uint256 laneShift = (slot & 0x3) * BITS_PER_LANE;
        uint256 group = teamGroupsPacked[user][slot >> 2];
        teamGroupsPacked[user][slot >> 2] =
            (group & ~(LANE_MASK << laneShift)) | ((packedTeam & LANE_MASK) << laneShift);
    }

    function _liveBitmap(address user) internal view returns (uint256) {
        return (teamOrderPacked[user] >> LIVE_BITMAP_SHIFT) & LIVE_BITMAP_MASK;
    }

    function _assertTeamLive(address player, uint256 teamIndex) internal view {
        if (_packedTeamIsCpuOpponent(player)) {
            return;
        }
        if (teamIndex >= MAX_TEAMS_PER_PLAYER || (_liveBitmap(player) & (uint256(1) << teamIndex)) == 0) {
            revert InvalidTeamIndex();
        }
    }

    /// @dev Variant for callers that already resolved the CPU-opponent flag (saves the
    ///      _packedTeamIsCpuOpponent playerData re-read when checking both sides in one call).
    function _assertTeamLive(address player, uint256 teamIndex, bool isCpuOpponent) internal view {
        if (isCpuOpponent) {
            return;
        }
        if (teamIndex >= MAX_TEAMS_PER_PLAYER || (_liveBitmap(player) & (uint256(1) << teamIndex)) == 0) {
            revert InvalidTeamIndex();
        }
    }

    /// @dev Count trailing zeros of a nonzero value (caller-bounded to LIVE_BITMAP_MASK).
    function _ctz(uint256 x) internal pure returns (uint256 n) {
        unchecked {
            while ((x & 1) == 0) {
                x >>= 1;
                ++n;
            }
        }
    }

    function _popcount(uint256 x) internal pure virtual returns (uint8 count) {
        unchecked {
            for (uint256 v = x; v != 0; v >>= 1) {
                if (v & 1 == 1) {
                    ++count;
                }
            }
        }
    }

    // =====================================================================
    // Pack / unpack
    // =====================================================================

    function _packTeam(uint256[] memory monIndices) internal view returns (uint256 packed) {
        packed = _packIndices(monIndices);
        _checkForDuplicates(monIndices);
    }

    function _packIndices(uint256[] memory monIndices) internal view returns (uint256 packed) {
        if (monIndices.length != MONS_PER_TEAM) {
            revert InvalidTeamSize();
        }
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256 id = monIndices[i];
            if (id > ONES_MASK) {
                revert MonIdTooLarge();
            }
            packed |= id << (i * BITS_PER_MON_INDEX);
            unchecked {
                ++i;
            }
        }
    }

    function _unpackTeam(uint256 packed) internal view returns (uint256[] memory ids) {
        ids = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            ids[i] = (packed >> (i * BITS_PER_MON_INDEX)) & ONES_MASK;
            unchecked {
                ++i;
            }
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

    function _getMonRegistryIndex(address player, uint256 teamIndex, uint256 position) internal view returns (uint256) {
        return (_readTeamLane(player, teamIndex) >> (position * BITS_PER_MON_INDEX)) & ONES_MASK;
    }

    // =====================================================================
    // Read views
    // =====================================================================

    function getMonRegistryIndicesForTeam(address player, uint256 teamIndex)
        public
        view
        virtual
        override
        returns (uint256[] memory)
    {
        _assertTeamLive(player, teamIndex);
        return _unpackTeam(_readTeamLane(player, teamIndex));
    }

    function getTeam(address player, uint256 teamIndex) external view virtual override returns (Mon[] memory) {
        _assertTeamLive(player, teamIndex);
        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        uint256[] memory ids = _unpackTeam(_readTeamLane(player, teamIndex));

        (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities) = _packedTeamGetMonData(ids);

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

    function getTeamCount(address player) external view virtual override returns (uint256) {
        return _popcount(_liveBitmap(player));
    }

    /// @dev Returns the player's live slot ids in display order.
    function getOrderedLiveTeams(address player) external view virtual override returns (uint256[] memory slots) {
        uint256 packed = teamOrderPacked[player];
        uint256 count = _popcount((packed >> LIVE_BITMAP_SHIFT) & LIVE_BITMAP_MASK);
        slots = new uint256[](count);
        for (uint256 i; i < count;) {
            slots[i] = (packed >> (i * ORDER_ENTRY_BITS)) & ORDER_ENTRY_MASK;
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Returns slot ids in display order + unpacked mon ids per slot. Single call for hydration.
    function getPlayerTeams(address player)
        external
        view
        virtual
        override
        returns (uint256[] memory slots, uint256[][] memory teamMonIds)
    {
        uint256 packed = teamOrderPacked[player];
        uint256 count = _popcount((packed >> LIVE_BITMAP_SHIFT) & LIVE_BITMAP_MASK);
        slots = new uint256[](count);
        teamMonIds = new uint256[][](count);
        for (uint256 i; i < count;) {
            uint256 slot = (packed >> (i * ORDER_ENTRY_BITS)) & ORDER_ENTRY_MASK;
            slots[i] = slot;
            teamMonIds[i] = _unpackTeam(_readTeamLane(player, slot));
            unchecked {
                ++i;
            }
        }
    }

    // ----- Subclass hooks -----

    function _packedTeamValidateOwnership(uint256[] memory monIndices) internal view virtual;

    /// @dev CPU opponents skip the live-bitmap check since their teams live in phantom slots
    /// keyed by the human user's address, not the CPU's own live-team list.
    function _packedTeamIsCpuOpponent(address player) internal view virtual returns (bool);

    function _packedTeamGetMonData(uint256[] memory ids)
        internal
        view
        virtual
        returns (MonStats[] memory stats, uint256[][] memory moves, uint256[][] memory abilities);
}
