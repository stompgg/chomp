// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Structs.sol";

abstract contract Facets {
    error NotFacetOwner();
    error InvalidFacetId();
    error FacetNotUnlocked();
    error FacetArgsLengthMismatch();

    enum StatGroup { HP, Atk, Def, Speed }

    uint256 internal constant MONS_PER_FACET_BUCKET = 16;
    uint256 internal constant FACET_BITS_PER_MON = 16;
    uint256 internal constant FACET_PER_MON_MASK = (1 << FACET_BITS_PER_MON) - 1;
    uint16  internal constant FACET_UNLOCKED_MASK = 0xFFF;
    uint256 internal constant FACET_ASSIGNED_SHIFT = 12;
    uint256 internal constant FACET_ASSIGNED_MASK = 0xF;
    uint8   internal constant TOTAL_FACETS = 12;

    // Per-mon (16 bits): bits 0-11 = unlockedBitmap, bits 12-15 = assignedFacetId (0 = none, 1-12).
    // 16 mons per uint256 slot, keyed by monId / MONS_PER_FACET_BUCKET.
    mapping(address player => mapping(uint256 monBucket => uint256 packed)) public facetData;

    // ----- 12-Facet table: derived systematically from facetId ∈ [1, 12] -----
    // boostIdx = (facetId-1)/3 ; nerfOffset = (facetId-1)%3 ;
    // nerfIdx = nerfOffset < boostIdx ? nerfOffset : nerfOffset + 1
    function _facetDef(uint8 facetId) internal pure returns (StatGroup boost, StatGroup nerf) {
        if (facetId < 1 || facetId > TOTAL_FACETS) revert InvalidFacetId();
        unchecked {
            uint256 idx = uint256(facetId) - 1;
            uint256 boostIdx = idx / 3;
            uint256 nerfOffset = idx % 3;
            uint256 nerfIdx = nerfOffset < boostIdx ? nerfOffset : nerfOffset + 1;
            boost = StatGroup(boostIdx);
            nerf = StatGroup(nerfIdx);
        }
    }

    // ----- Slot helpers (pure bit ops) -----

    function _readFacetSlotForMon(uint256 facetSlot, uint256 lane)
        internal
        pure
        returns (uint16 unlockedBitmap, uint8 assignedFacetId)
    {
        uint256 perMon = (facetSlot >> (lane * FACET_BITS_PER_MON)) & FACET_PER_MON_MASK;
        unlockedBitmap = uint16(perMon & FACET_UNLOCKED_MASK);
        assignedFacetId = uint8((perMon >> FACET_ASSIGNED_SHIFT) & FACET_ASSIGNED_MASK);
    }

    function _writeFacetSlotForMon(
        uint256 facetSlot,
        uint256 lane,
        uint16 unlockedBitmap,
        uint8 assignedFacetId
    ) internal pure returns (uint256) {
        uint256 perMon = uint256(unlockedBitmap) | (uint256(assignedFacetId) << FACET_ASSIGNED_SHIFT);
        uint256 cleared = facetSlot & ~(FACET_PER_MON_MASK << (lane * FACET_BITS_PER_MON));
        return cleared | (perMon << (lane * FACET_BITS_PER_MON));
    }

    // ----- Level-up draw: pick the next Facet from the unclaimed pool using entropy. -----
    // Returns updated unlockedBitmap and the drawn facetId (0 if all unlocked).
    function _drawNextFacet(uint16 unlockedBitmap, uint256 entropy)
        internal
        pure
        returns (uint16 newBitmap, uint8 facetId)
    {
        uint8 unclaimed = TOTAL_FACETS - _popcount(unlockedBitmap);
        if (unclaimed == 0) {
            return (unlockedBitmap, 0);
        }
        uint8 index = uint8(entropy % unclaimed);
        uint8 seenUnset = 0;
        for (uint8 i = 0; i < TOTAL_FACETS;) {
            if (unlockedBitmap & uint16(1 << i) == 0) {
                if (seenUnset == index) {
                    return (unlockedBitmap | uint16(1 << i), i + 1);
                }
                unchecked { ++seenUnset; }
            }
            unchecked { ++i; }
        }
        return (unlockedBitmap, 0); // unreachable
    }

    function _popcount(uint256 x) internal pure returns (uint8 count) {
        unchecked {
            for (uint256 v = x; v != 0; v >>= 1) {
                if (v & 1 == 1) ++count;
            }
        }
    }

    // ----- Stat delta computation (pure) -----

    function _computeFacetDelta(MonStats memory base, uint8 facetId)
        internal
        pure
        returns (StatDelta memory delta)
    {
        if (facetId == 0) {
            return delta; // all zeros
        }
        (StatGroup boost, StatGroup nerf) = _facetDef(facetId);
        _applyGroupDelta(delta, boost, base, true);
        _applyGroupDelta(delta, nerf, base, false);
    }

    function _applyGroupDelta(
        StatDelta memory delta,
        StatGroup group,
        MonStats memory base,
        bool isBoost
    ) private pure {
        // ±5% of base, integer-truncated.
        if (group == StatGroup.HP) {
            int16 d = int16(int256(uint256(base.hp) * 5 / 100));
            delta.hp = isBoost ? d : -d;
        } else if (group == StatGroup.Atk) {
            int16 dAtk = int16(int256(uint256(base.attack) * 5 / 100));
            int16 dSpAtk = int16(int256(uint256(base.specialAttack) * 5 / 100));
            delta.atk = isBoost ? dAtk : -dAtk;
            delta.spAtk = isBoost ? dSpAtk : -dSpAtk;
        } else if (group == StatGroup.Def) {
            int16 dDef = int16(int256(uint256(base.defense) * 5 / 100));
            int16 dSpDef = int16(int256(uint256(base.specialDefense) * 5 / 100));
            delta.def = isBoost ? dDef : -dDef;
            delta.spDef = isBoost ? dSpDef : -dSpDef;
        } else {
            // Speed
            int16 d = int16(int256(uint256(base.speed) * 5 / 100));
            delta.speed = isBoost ? d : -d;
        }
    }

    // ----- Public view getters -----

    function getFacetData(address player, uint256 monId)
        public
        view
        virtual
        returns (uint16 unlockedBitmap, uint8 assignedFacetId)
    {
        uint256 bucket = monId / MONS_PER_FACET_BUCKET;
        uint256 lane = monId % MONS_PER_FACET_BUCKET;
        return _readFacetSlotForMon(facetData[player][bucket], lane);
    }

    function getFacetDeltaForMon(address player, uint256 monId)
        public
        view
        virtual
        returns (StatDelta memory)
    {
        uint256 bucket = monId / MONS_PER_FACET_BUCKET;
        uint256 lane = monId % MONS_PER_FACET_BUCKET;
        (, uint8 facetId) = _readFacetSlotForMon(facetData[player][bucket], lane);
        if (facetId == 0) return StatDelta(0, 0, 0, 0, 0, 0);
        return _computeFacetDelta(_getMonStatsForFacets(monId), facetId);
    }

    // ----- Bulk assignment (free swap) -----

    function assignFacets(uint256[] calldata monIds, uint8[] calldata facetIds) public virtual {
        if (monIds.length != facetIds.length) revert FacetArgsLengthMismatch();
        uint256 len = monIds.length;
        uint256 lastBucket = type(uint256).max;
        uint256 currentSlot;
        bool dirty;
        for (uint256 i; i < len;) {
            uint256 monId = monIds[i];
            uint8 facetId = facetIds[i];
            if (facetId > TOTAL_FACETS) revert InvalidFacetId();
            if (!_isFacetMonOwned(msg.sender, monId)) revert NotFacetOwner();
            uint256 bucket = monId / MONS_PER_FACET_BUCKET;
            uint256 lane = monId % MONS_PER_FACET_BUCKET;
            if (bucket != lastBucket) {
                if (lastBucket != type(uint256).max && dirty) {
                    facetData[msg.sender][lastBucket] = currentSlot;
                }
                currentSlot = facetData[msg.sender][bucket];
                lastBucket = bucket;
                dirty = false;
            }
            (uint16 unlockedBitmap,) = _readFacetSlotForMon(currentSlot, lane);
            if (facetId != 0 && (unlockedBitmap & uint16(1 << (facetId - 1))) == 0) revert FacetNotUnlocked();
            currentSlot = _writeFacetSlotForMon(currentSlot, lane, unlockedBitmap, facetId);
            dirty = true;
            unchecked { ++i; }
        }
        if (lastBucket != type(uint256).max && dirty) {
            facetData[msg.sender][lastBucket] = currentSlot;
        }
    }

    // ----- Subclass hooks -----
    /// @dev Called by assignFacets to gate caller authority. Subclass plumbs into its
    ///      ownership tracking (e.g. monsOwned set on GachaTeamRegistry).
    function _isFacetMonOwned(address player, uint256 monId) internal view virtual returns (bool);

    /// @dev Called by getFacetDeltaForMon to look up base stats for the delta computation.
    function _getMonStatsForFacets(uint256 monId) internal view virtual returns (MonStats memory);
}
