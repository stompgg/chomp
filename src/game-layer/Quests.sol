// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MAX_PREDICATES_PER_QUEST} from "../Constants.sol";
import "../Structs.sol";
import {Ownable} from "../lib/Ownable.sol";

abstract contract Quests is Ownable {
    error TooManyPredicates();
    error InvalidQuestId();
    error EmptyPool();
    error InvalidOpcode();

    enum Op {
        TURNS,
        ALIVE_COUNT,
        HAS_MON_ID,
        MON_LEVEL,
        MON_FACET,
        MON_KO_AT_SLOT,
        MON_ALIVE_AT_SLOT,
        ACTIVE_SLOT_INDEX,
        MON_STATE,
        // Aggregates over the team — read existing storage, no new state required.
        MIN_LEVEL, // min level across all team slots
        MAX_LEVEL, // max level across all team slots
        FACET_COUNT, // count of slots with non-zero assignedFacetId
        MIN_HP_DELTA, // min hpDelta across team (sentinel normalized to 0)
        MAX_HP_DELTA // max hpDelta across team (sentinel normalized to 0)
    }
    enum Cmp {
        EQ,
        NE,
        LT,
        LE,
        GT,
        GE
    }

    // Memory-only struct for ergonomic admin authoring. Compiles down to the packed encoding below.
    struct Predicate {
        Op op;
        Cmp cmp;
        bool negate;
        uint16 arg;
        int16 operand;
    }

    // Storage struct: packed bit layout, 1 SLOAD per quest eval regardless of predicate count.
    // bits 0..245   : 6 × 41-bit predicates (lane i at bits [i*41 .. i*41+40])
    // bits 246..248 : predicate count (0..6)
    // bits 249..255 : reserved
    struct Quest {
        uint256 packed;
    }

    // Flat pool storage: mapping + explicit packed length. _questPoolLength and _dayOffset are
    // adjacent uint32s, so Solidity packs them into ONE slot — the battle-end quest gate reads
    // both (pool size + effective day) for a single cold SLOAD instead of two.
    mapping(uint256 => Quest) internal questPool;
    uint32 private _questPoolLength;

    /// @dev Admin-controlled forward-only offset added to `block.timestamp / 1 days` in
    /// every quest-day read. Lets the owner advance the daily quest rotation without
    /// having to wait wall-clock time on a long-running chain. Packs with _questPoolLength.
    uint32 internal _dayOffset;

    event DayAdvanced(uint32 by, uint32 newOffset, uint32 newEffectiveDay);

    uint256 internal constant PRED_BITS = 41;
    uint256 internal constant PRED_LANE_MASK = (uint256(1) << PRED_BITS) - 1;
    uint256 internal constant COUNT_SHIFT = 246;
    uint256 internal constant COUNT_MASK = 0x7; // 3 bits

    // ----- Encoding -----

    function _encodeQuest(Predicate[] memory preds) internal pure returns (uint256 packed) {
        uint256 count = preds.length;
        if (count > MAX_PREDICATES_PER_QUEST) revert TooManyPredicates();
        for (uint256 i; i < count;) {
            Predicate memory p = preds[i];
            uint256 lane = uint256(uint8(p.op)) | (uint256(uint8(p.cmp)) << 5) | (uint256(p.negate ? 1 : 0) << 8)
                | (uint256(p.arg) << 9) | (uint256(uint16(p.operand)) << 25);
            packed |= (lane << (i * PRED_BITS));
            unchecked {
                ++i;
            }
        }
        packed |= (count << COUNT_SHIFT);
    }

    function _decodePredicate(uint256 lane)
        internal
        pure
        returns (uint8 op, uint8 cmp, bool negate, uint16 arg, int16 operand)
    {
        op = uint8(lane & 0x1F);
        cmp = uint8((lane >> 5) & 0x07);
        negate = ((lane >> 8) & 1) == 1;
        arg = uint16((lane >> 9) & 0xFFFF);
        operand = int16(int256(uint256((lane >> 25) & 0xFFFF)));
    }

    // ----- Admin -----

    function addQuest(Predicate[] memory preds) external onlyOwner returns (uint256 questId) {
        return _addQuest(preds);
    }

    /// @dev Owner-bypassing internal hook so subclass constructors can seed an initial pool
    /// before _initializeOwner is meaningful from outside. External callers must go through
    /// the onlyOwner-gated `addQuest`.
    function _addQuest(Predicate[] memory preds) internal returns (uint256 questId) {
        questId = _questPoolLength;
        questPool[questId] = Quest({packed: _encodeQuest(preds)});
        _questPoolLength = uint32(questId + 1);
    }

    function editQuest(uint256 questId, Predicate[] memory preds) external onlyOwner {
        if (questId >= _questPoolLength) revert InvalidQuestId();
        questPool[questId].packed = _encodeQuest(preds);
    }

    function removeQuest(uint256 questId) external onlyOwner {
        uint256 last = _questPoolLength;
        if (questId >= last) revert InvalidQuestId();
        last -= 1;
        if (questId != last) {
            questPool[questId] = questPool[last];
        }
        delete questPool[last];
        _questPoolLength = uint32(last);
    }

    function getQuestPoolLength() external view returns (uint256) {
        return _questPoolLength;
    }

    function dayOffset() external view returns (uint32) {
        return _dayOffset;
    }

    /// @notice Bumps the day-offset forward by `n` days. Forward-only by design — every
    /// quest-day read (`getActiveQuest`, battle-end completion gating) immediately sees
    /// the new effective day on the next call.
    function advanceDays(uint32 n) external onlyOwner {
        _dayOffset += n;
        emit DayAdvanced(n, _dayOffset, _currentDay());
    }

    /// @dev Single choke point for "what day is it for quest purposes". All callers
    /// route through this so a future offset semantics change (signed, resettable, etc.)
    /// only needs to touch one place.
    function _currentDay() internal view returns (uint32) {
        return uint32(block.timestamp / 1 days) + _dayOffset;
    }

    function getQuest(uint256 questId) external view returns (uint256 packed, uint256 count) {
        if (questId >= _questPoolLength) revert InvalidQuestId();
        packed = questPool[questId].packed;
        count = (packed >> COUNT_SHIFT) & COUNT_MASK;
    }

    /// @notice Day-deterministic active quest. Selection is `keccak256(day) % poolLength`,
    /// so all callers within the same UTC day see the same quest — no race between concurrent
    /// battles, and no SSTORE on rotation. Returns activeQuestId = 0 when the pool is empty;
    /// callers must gate quest evaluation on `getQuestPoolLength() > 0`.
    function getActiveQuest() external view returns (uint32 activeDay, uint32 activeQuestId) {
        activeDay = _currentDay();
        uint256 len = _questPoolLength;
        if (len == 0) return (activeDay, 0);
        activeQuestId = uint32(uint256(keccak256(abi.encode(activeDay))) % len);
    }

    /// @dev Caller supplies the pool length (already read from the packed slot) and must
    ///      ensure it is > 0 (the `% len` would otherwise revert).
    function _activeQuestIdForDay(uint32 day, uint256 poolLen) internal pure returns (uint32) {
        return uint32(uint256(keccak256(abi.encode(day))) % poolLen);
    }

    /// @dev One-SLOAD read of the packed (poolLength, dayOffset) slot plus the derived quest day —
    ///      the battle-end gate's single entry point for quest config.
    function _questDayAndPoolLen() internal view returns (uint32 day, uint256 poolLen) {
        poolLen = _questPoolLength;
        day = uint32(block.timestamp / 1 days) + _dayOffset;
    }

    // ----- Eval -----

    function _compare(int256 extracted, uint8 cmp, int256 operand) internal pure returns (bool) {
        if (cmp == uint8(Cmp.EQ)) return extracted == operand;
        if (cmp == uint8(Cmp.NE)) return extracted != operand;
        if (cmp == uint8(Cmp.LT)) return extracted < operand;
        if (cmp == uint8(Cmp.LE)) return extracted <= operand;
        if (cmp == uint8(Cmp.GT)) return extracted > operand;
        if (cmp == uint8(Cmp.GE)) return extracted >= operand;
        revert InvalidOpcode();
    }

    /// @dev Caller (onBattleEnd) is responsible for gating with `questPool.length > 0` —
    /// no internal check here so we don't pay the array-length SLOAD twice per battle.
    function _evalActiveQuest(
        BattleEndContext memory ctx,
        uint256 playerIndex,
        bytes32 battleKey,
        uint32 day,
        uint256 poolLen
    ) internal view returns (bool) {
        uint32 activeQuestId = _activeQuestIdForDay(day, poolLen);
        uint256 packed = questPool[activeQuestId].packed; // 1 SLOAD
        uint256 count = (packed >> COUNT_SHIFT) & COUNT_MASK;
        for (uint256 i; i < count;) {
            uint256 lane = (packed >> (i * PRED_BITS)) & PRED_LANE_MASK;
            (uint8 op, uint8 cmp, bool negate, uint16 arg, int16 operand) = _decodePredicate(lane);
            int256 extracted = _extract(op, arg, ctx, playerIndex, battleKey);
            bool ok = _compare(extracted, cmp, int256(operand));
            if (negate) ok = !ok;
            if (!ok) return false;
            unchecked {
                ++i;
            }
        }
        return true;
    }

    /// @dev Subclass implements opcode dispatch. Has access to registry storage (exp, facets,
    ///      monRegistryIndicesForTeamPacked) and can extcall ENGINE for MON_STATE.
    function _extract(uint8 op, uint16 arg, BattleEndContext memory ctx, uint256 playerIndex, bytes32 battleKey)
        internal
        view
        virtual
        returns (int256);
}
