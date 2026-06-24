// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, DEFAULT_PRIORITY} from "../../Constants.sol";
import {ExtraDataType, MoveClass, Type, MonStateIndexName} from "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";

/// @notice Somniphobia punishes recovering stamina. When used, it places an effect on BOTH active
///         mons that lasts DURATION turns. While the effect is active, any time that mon gains
///         stamina from *any* source (resting, the round-end stamina regen, a stamina-steal move,
///         etc.) it immediately takes 1/DAMAGE_DENOM of its max HP as damage.
/// @dev Detecting "any stamina gain" is done via the OnUpdateMonState hook (the same hook
///      Dreamcatcher uses to heal on stamina gain). That hook only fires for *local* (per-mon)
///      effects — global effects never receive it — so Somniphobia is registered locally on each
///      active mon rather than as a single battlefield-wide global effect. It is cleared when the
///      mon switches out, scoping it to the mons that were active when it was invoked.
contract Somniphobia is IMoveSet, BasicEffect {
    uint256 public constant DURATION = 8;
    int32 public constant DAMAGE_DENOM = 8;

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Somniphobia";
    }

    function move(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex, uint256 defenderMonIndex, uint16, uint256) external {
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        _applyTo(engine, battleKey, attackerPlayerIndex, attackerMonIndex);
        _applyTo(engine, battleKey, defenderPlayerIndex, defenderMonIndex);
    }

    /// @dev Add (or refresh) the effect on a single mon. Re-invoking while it is already present
    ///      resets the remaining duration rather than stacking a second copy.
    function _applyTo(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal {
        (bool exists, uint256 effectIndex,) = engine.getEffectData(battleKey, playerIndex, monIndex, address(this));
        if (exists) {
            engine.editEffect(playerIndex, effectIndex, bytes32(DURATION));
        } else {
            engine.addEffect(playerIndex, monIndex, this, bytes32(DURATION));
        }
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Cosmic;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    // Steps: RoundEnd (0x04), OnMonSwitchOut (0x20), OnUpdateMonState (0x100), ALWAYS_APPLIES (0x8000)
    function getStepsBitmap() external pure override returns (uint16) {
        return ALWAYS_APPLIES_BIT | 0x0124;
    }

    /// @notice Damage the mon whenever its stamina is increased.
    function onUpdateMonState(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 playerIndex,
        uint256 monIndex,
        uint256,
        uint256,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) external override returns (bytes32, bool) {
        // Only trigger on a stamina *gain*. The damage below routes back through updateMonState
        // (as an Hp delta), which re-enters this hook — the stat guard makes that re-entry a no-op,
        // so there is no recursion.
        if (stateVarIndex == MonStateIndexName.Stamina && valueToAdd > 0) {
            uint32 maxHp = engine.getMonValueForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Hp);
            int32 damage = int32(uint32(maxHp)) / DAMAGE_DENOM;
            if (damage > 0) {
                engine.dealDamage(playerIndex, monIndex, damage);
            }
        }
        return (extraData, false);
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool removeAfterRun)
    {
        uint256 turnsLeft = uint256(extraData);
        if (turnsLeft == 1) {
            return (extraData, true);
        } else {
            return (bytes32(turnsLeft - 1), false);
        }
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        // Clear when the mon leaves the field.
        return (extraData, true);
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }

}
