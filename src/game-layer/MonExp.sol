// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";
import {Facets} from "./Facets.sol";
import {IExpAssigner} from "./IExpAssigner.sol";
import {ITeamRegistry} from "./ITeamRegistry.sol";
import {PackedTeamStore} from "./PackedTeamStore.sol";

/// @notice Per-(player, mon) exp accrual, level curve, and the public read API. Storage is
/// bit-packed: 16 mons per uint256, 16 bits per mon (cap = 65535).
abstract contract MonExp is IExpAssigner, Facets, PackedTeamStore {
    error LengthMismatch();
    error InvalidMonId();

    // ----- Move-loadout errors -----
    error NotMoveOwner();
    error EmptyMoveSelection();
    error TooManyMovesSelected();
    error InvalidMoveLane();
    error MoveNotUnlocked();

    event MovesAssigned(address indexed player, uint256[] monIds);

    uint256 internal constant MONS_PER_EXP_BUCKET = 16;
    uint256 internal constant EXP_BITS_PER_MON = 16;
    uint256 internal constant EXP_PER_MON_MASK = (1 << EXP_BITS_PER_MON) - 1;
    uint256 internal constant EXP_PER_MON_CAP = EXP_PER_MON_MASK; // 65535

    mapping(address player => mapping(uint256 monBucket => uint256 packedExp)) public packedExpForMon;

    // ----- Move loadout (per-(player, mon) battle-slot selection) -----
    // Deterministic level-gated learnset: a mon's higher catalog lanes become selectable once the
    // player's copy reaches the lane's unlock level. "Unlocked" is a pure function of level + the
    // by-lane curve below — no per-player unlock storage.
    uint256 internal constant FIRST_UNLOCK_LEVEL = 6;

    // Per-mon selection field: an 8-bit *set* bitmap (bit i = "catalog lane i is in my battle set").
    // Battle-slot order is derived (ascending lane), not stored. Whole-mon value 0 = unconfigured →
    // resolves to the default lanes [0, MOVES_PER_MON). Stride is 16 bits / 16 mons per bucket to
    // align with the exp & facet buckets (only the low 8 bits are used; high 8 reserved), so
    // migrate() copies all three in one bucket loop and the getTeams/assignMoves bucket math is shared.
    uint256 internal constant MOVE_SEL_BITS_PER_MON = 16;
    uint256 internal constant MOVE_SEL_MASK = 0xFF;
    mapping(address player => mapping(uint256 monBucket => uint256 packed)) public selectedMoveBitmap;

    // =====================================================================
    // Public view API (ITeamRegistry)
    // =====================================================================

    function getExp(address player, uint256 monId) external view override returns (uint256) {
        return _getExp(player, monId);
    }

    function getLevel(address player, uint256 monId) external view override returns (uint256) {
        return _levelForExp(_getExp(player, monId));
    }

    function levelForExp(uint256 exp) external pure override returns (uint256) {
        return _levelForExp(exp);
    }

    function getExpAndLevelsForMons(address player, uint256[] calldata ids)
        external
        view
        override
        returns (uint256[] memory exp, uint256[] memory levels)
    {
        uint256 len = ids.length;
        exp = new uint256[](len);
        levels = new uint256[](len);
        for (uint256 i; i < len;) {
            uint256 e = _getExp(player, ids[i]);
            exp[i] = e;
            levels[i] = _levelForExp(e);
            unchecked {
                ++i;
            }
        }
    }

    function getExpAndLevelsForTeam(address player, uint256 teamIndex)
        external
        view
        override
        returns (uint256[] memory ids, uint256[] memory exp, uint256[] memory levels)
    {
        _assertTeamLive(player, teamIndex);
        ids = _unpackTeam(_readTeamLane(player, teamIndex));
        exp = new uint256[](MONS_PER_TEAM);
        levels = new uint256[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM;) {
            uint256 e = _getExp(player, ids[i]);
            exp[i] = e;
            levels[i] = _levelForExp(e);
            unchecked {
                ++i;
            }
        }
    }

    function getExpAndLevelsForTeams(address p0, uint256 p0TeamIndex, address p1, uint256 p1TeamIndex)
        external
        view
        override
        returns (
            uint256[] memory p0MonIds,
            uint256[] memory p0Exp,
            uint256[] memory p0Levels,
            uint256[] memory p1MonIds,
            uint256[] memory p1Exp,
            uint256[] memory p1Levels
        )
    {
        _assertTeamLive(p0, p0TeamIndex);
        _assertTeamLive(p1, p1TeamIndex);
        p0MonIds = _unpackTeam(_readTeamLane(p0, p0TeamIndex));
        p1MonIds = _unpackTeam(_readTeamLane(p1, p1TeamIndex));
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
            unchecked {
                ++i;
            }
        }
    }

    // =====================================================================
    // Assigner API (IExpAssigner)
    // =====================================================================

    /// @dev Unsorted monIds work but pay extra SLOAD/SSTORE per bucket revisit.
    function assignExp(address player, uint256[] calldata monIds_, uint256[] calldata amounts) external override {
        _assertExpAssigner();
        if (monIds_.length != amounts.length) revert LengthMismatch();

        uint256 monRegistrySize = _monRegistrySize();
        uint256 lastBucket = type(uint256).max;
        uint256 expSlot;
        uint256 facetSlot;
        bool facetLoaded;
        bool facetDirty;

        for (uint256 i; i < monIds_.length;) {
            uint256 monId = monIds_[i];
            if (monId >= monRegistrySize) revert InvalidMonId();
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

            uint256 oldExp = (expSlot >> (lane * EXP_BITS_PER_MON)) & EXP_PER_MON_MASK;
            uint256 newExp = oldExp + amounts[i];
            if (newExp > EXP_PER_MON_CAP) newExp = EXP_PER_MON_CAP;
            expSlot =
                (expSlot & ~(EXP_PER_MON_MASK << (lane * EXP_BITS_PER_MON))) | (newExp << (lane * EXP_BITS_PER_MON));

            (uint256 newFacetSlot,, bool drew) =
                _processLevelUps(player, monId, bucket, lane, oldExp, newExp, facetSlot, facetLoaded);
            if (drew) {
                facetSlot = newFacetSlot;
                facetLoaded = true;
                facetDirty = true;
            }

            unchecked {
                ++i;
            }
        }

        if (lastBucket != type(uint256).max) {
            packedExpForMon[player][lastBucket] = expSlot;
            if (facetDirty) facetData[player][lastBucket] = facetSlot;
        }
    }

    // =====================================================================
    // Move loadout (ITeamRegistry)
    // =====================================================================

    /// @notice Uniform-across-mons unlock curve. Lane order = learnset order: lanes
    /// [0, MOVES_PER_MON) are the default moves (level 0); higher lanes unlock at FIRST_UNLOCK_LEVEL.
    function _unlockLevelForLane(uint256 lane) internal view returns (uint256) {
        if (lane < MOVES_PER_MON) return 0;
        return FIRST_UNLOCK_LEVEL;
    }

    /// @dev OR of (1 << lane) for every catalog lane with a non-zero move whose unlock level is
    /// <= the player's current level for the mon. Excludes empty lanes via the non-zero check.
    function _unlockedMoveMask(address player, uint256 monId) internal view returns (uint8 mask) {
        uint256[] memory fullRow = _fullMoveRow(monId);
        uint256 level = _levelForExp(_getExp(player, monId));
        for (uint256 lane; lane < fullRow.length;) {
            if (fullRow[lane] != 0 && _unlockLevelForLane(lane) <= level) {
                mask |= uint8(1 << lane);
            }
            unchecked {
                ++lane;
            }
        }
    }

    /// @notice The set of catalog lanes currently usable by `player` for `monId` (pure function of
    /// level). The frontend ANDs the move picker against this.
    function getUnlockedMoves(address player, uint256 monId) external view override returns (uint8) {
        return _unlockedMoveMask(player, monId);
    }

    /// @notice The player's selected battle-slot set for `monId` as an 8-bit lane bitmap. Returns
    /// the default (lanes [0, MOVES_PER_MON)) when unconfigured (stored value 0).
    function getMoveSelection(address player, uint256 monId) external view override returns (uint8) {
        return _getMoveSelection(player, monId);
    }

    function _getMoveSelection(address player, uint256 monId) internal view returns (uint8) {
        uint256 bucket = monId / MONS_PER_EXP_BUCKET;
        uint256 lane = monId % MONS_PER_EXP_BUCKET;
        uint8 stored = uint8((selectedMoveBitmap[player][bucket] >> (lane * MOVE_SEL_BITS_PER_MON)) & MOVE_SEL_MASK);
        if (stored == 0) return uint8((uint256(1) << MOVES_PER_MON) - 1);
        return stored;
    }

    /// @notice Learnset display: a mon's non-empty catalog moves (in lane order) and each move's
    /// unlock level.
    function getMovePool(uint256 monId)
        external
        view
        override
        returns (uint256[] memory moves, uint8[] memory unlockLevels)
    {
        uint256[] memory fullRow = _fullMoveRow(monId);
        uint256 n;
        for (uint256 i; i < fullRow.length; ++i) {
            if (fullRow[i] != 0) ++n;
        }
        moves = new uint256[](n);
        unlockLevels = new uint8[](n);
        uint256 w;
        for (uint256 lane; lane < fullRow.length;) {
            if (fullRow[lane] != 0) {
                moves[w] = fullRow[lane];
                unlockLevels[w] = uint8(_unlockLevelForLane(lane));
                unchecked {
                    ++w;
                }
            }
            unchecked {
                ++lane;
            }
        }
    }

    /// @notice Pick which of an owned mon's unlocked moves occupy its 4 battle slots. Parallel
    /// arrays: `selectionBitmaps[i]` is the 8-bit lane set for `monIds[i]`. Bucket-coalesced write
    /// mirroring assignFacets. Unlock is monotonic (level only rises), so a stored selection can
    /// never later become un-unlocked — no read-time re-validation needed.
    function assignMoves(uint256[] calldata monIds_, uint8[] calldata selectionBitmaps) external override {
        if (monIds_.length != selectionBitmaps.length) revert LengthMismatch();
        uint256 lastBucket = type(uint256).max;
        uint256 currentSlot;
        bool dirty;
        for (uint256 i; i < monIds_.length;) {
            uint256 monId = monIds_[i];
            uint8 bitmap = selectionBitmaps[i];
            if (!_isFacetMonOwned(msg.sender, monId)) revert NotMoveOwner();
            if (bitmap == 0) revert EmptyMoveSelection();
            if (_popcount(bitmap) > MOVES_PER_MON) revert TooManyMovesSelected();

            // Every set bit must point at a non-empty, unlocked catalog lane. Split the two
            // failure modes for precise errors (empty lane vs out-leveled lane).
            {
                uint256[] memory fullRow = _fullMoveRow(monId);
                uint256 level = _levelForExp(_getExp(msg.sender, monId));
                for (uint256 b; b < fullRow.length;) {
                    if ((bitmap & uint8(1 << b)) != 0) {
                        if (fullRow[b] == 0) revert InvalidMoveLane();
                        if (_unlockLevelForLane(b) > level) revert MoveNotUnlocked();
                    }
                    unchecked {
                        ++b;
                    }
                }
            }

            uint256 bucket = monId / MONS_PER_EXP_BUCKET;
            uint256 lane = monId % MONS_PER_EXP_BUCKET;
            if (bucket != lastBucket) {
                if (lastBucket != type(uint256).max && dirty) {
                    selectedMoveBitmap[msg.sender][lastBucket] = currentSlot;
                }
                currentSlot = selectedMoveBitmap[msg.sender][bucket];
                lastBucket = bucket;
                dirty = false;
            }
            uint256 shift = lane * MOVE_SEL_BITS_PER_MON;
            currentSlot = (currentSlot & ~(MOVE_SEL_MASK << shift)) | (uint256(bitmap) << shift);
            dirty = true;
            unchecked {
                ++i;
            }
        }
        if (lastBucket != type(uint256).max && dirty) {
            selectedMoveBitmap[msg.sender][lastBucket] = currentSlot;
        }
        emit MovesAssigned(msg.sender, monIds_);
    }

    /// @dev Resolve a mon's MOVES_PER_MON battle slots from its full lane-indexed catalog row and
    /// an 8-bit selection bitmap. bitmap == 0 → default (first MOVES_PER_MON non-zero lanes); else
    /// the set non-zero lanes in ascending order. Trailing slots stay 0 (Engine: "no move").
    function _resolveBattleMoves(uint256[] memory fullRow, uint8 bitmap) internal view returns (uint256[] memory out) {
        out = new uint256[](MOVES_PER_MON);
        uint256 w;
        for (uint256 lane; lane < fullRow.length && w < MOVES_PER_MON;) {
            uint256 word = fullRow[lane];
            bool take = bitmap == 0 ? true : (bitmap & uint8(1 << lane)) != 0;
            if (take && word != 0) {
                out[w] = word;
                unchecked {
                    ++w;
                }
            }
            unchecked {
                ++lane;
            }
        }
    }

    // =====================================================================
    // Shared internals
    // =====================================================================

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
        if (exp < 4) return 0;
        if (exp < 10) return 1;
        if (exp < 18) return 2;
        if (exp < 28) return 3;
        if (exp < 40) return 4;
        if (exp < 54) return 5;
        if (exp < 70) return 6;
        if (exp < 88) return 7;
        if (exp < 108) return 8;
        if (exp < 130) return 9;
        if (exp < 154) return 10;
        if (exp < 180) return 11;
        return 12;
    }

    /// @dev `facetLoaded` lets the caller reuse a previously-loaded facet bucket so we don't
    /// re-SLOAD facetData on every mon. Caller is responsible for SSTOREing `newFacetSlot`.
    function _processLevelUps(
        address player,
        uint256 monId,
        uint256 bucket,
        uint256 lane,
        uint256 oldExp,
        uint256 newExp,
        uint256 facetSlot,
        bool facetLoaded
    ) internal view returns (uint256 newFacetSlot, uint256 drawnBitmap, bool drew) {
        uint256 oldLevel = _levelForExp(oldExp);
        uint256 newLevel = _levelForExp(newExp);
        if (newLevel <= oldLevel) {
            return (facetSlot, 0, false);
        }
        if (!facetLoaded) {
            facetSlot = facetData[player][bucket];
        }
        (uint16 unlockedBitmap, uint8 assignedFacet) = _readFacetSlotForMon(facetSlot, lane);
        uint16 priorBitmap = unlockedBitmap;
        for (uint256 levelNum = oldLevel + 1; levelNum <= newLevel;) {
            if (_popcount(unlockedBitmap) == TOTAL_FACETS) break;
            uint256 entropy = uint256(keccak256(abi.encode(monId, blockhash(block.number - 1), player, levelNum)));
            (unlockedBitmap,) = _drawNextFacet(unlockedBitmap, entropy);
            unchecked {
                ++levelNum;
            }
        }
        drawnBitmap = uint256(unlockedBitmap & ~priorBitmap) & ((uint256(1) << TOTAL_FACETS) - 1);
        newFacetSlot = _writeFacetSlotForMon(facetSlot, lane, unlockedBitmap, assignedFacet);
        drew = true;
    }

    // Diamond resolution: Facets and PackedTeamStore both declare _popcount; Facets and the
    // ITeamRegistry decl reached through PackedTeamStore both surface the three facet functions.
    function _popcount(uint256 x) internal pure virtual override(Facets, PackedTeamStore) returns (uint8) {
        return Facets._popcount(x);
    }

    function assignFacets(uint256[] calldata monIds_, uint8[] calldata facetIds)
        public
        virtual
        override(Facets, ITeamRegistry)
    {
        super.assignFacets(monIds_, facetIds);
    }

    function getFacetData(address player, uint256 monId)
        public
        view
        virtual
        override(Facets, ITeamRegistry)
        returns (uint16, uint8)
    {
        return super.getFacetData(player, monId);
    }

    function getFacetDeltaForMon(address player, uint256 monId)
        public
        view
        virtual
        override(Facets, ITeamRegistry)
        returns (StatDelta memory)
    {
        return super.getFacetDeltaForMon(player, monId);
    }

    // ----- Subclass hooks -----

    function _assertExpAssigner() internal view virtual;

    function _monRegistrySize() internal view virtual returns (uint256);

    /// @dev Full lane-indexed catalog move row (length CATALOG_MOVE_LANES, zeros included) for
    /// `monId`. Wired by the leaf to MonRegistry's catalog.
    function _fullMoveRow(uint256 monId) internal view virtual returns (uint256[] memory);
}
