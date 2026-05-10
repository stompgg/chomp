// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {DEFAULT_PRIORITY, MOVE_INDEX_MASK, NO_OP_MOVE_INDEX} from "../../Constants.sol";
import {ExtraDataType, MonStateIndexName, MoveClass, Type} from "../../Enums.sol";
import {EffectInstance, MoveDecision, MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {SwitchTargetLib} from "../../lib/SwitchTargetLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract HardReset is IMoveSet, BasicEffect {
    int32 public constant HP_DENOM = 16;

    // extraData layout:
    //   bit 0 = casterIndex (0 or 1)
    //   bit 1 = ownTeamFired
    //   bit 2 = oppTeamFired
    uint256 private constant CASTER_INDEX_BIT = 0x1;
    uint256 private constant OWN_FIRED_BIT = 0x2;
    uint256 private constant OPP_FIRED_BIT = 0x4;

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Hard Reset";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256,
        uint16,
        uint256
    ) external {
        // Per-caster uniqueness: addEffect(2, _, ...) discards monIndex and getEffects(2, _) ignores
        // its filter, so caster identity must be carried in extraData and decoded here.
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 2, 0);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)
                && (uint256(effects[i].data) & CASTER_INDEX_BIT) == attackerPlayerIndex) {
                return;
            }
        }
        engine.addEffect(2, 0, IEffect(address(this)), bytes32(attackerPlayerIndex));
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Math;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
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

    // Steps: AfterMove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x80;
    }

    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256,
        uint256
    ) external override returns (bytes32, bool) {
        MoveDecision memory dec = engine.getMoveDecisionForBattleState(battleKey, targetIndex);
        if ((dec.packedMoveIndex & MOVE_INDEX_MASK) != NO_OP_MOVE_INDEX) {
            return (extraData, false);
        }

        uint256 ed = uint256(extraData);
        bool ownFired = (ed & OWN_FIRED_BIT) != 0;
        bool oppFired = (ed & OPP_FIRED_BIT) != 0;
        bool isOwnTeam = (targetIndex == (ed & CASTER_INDEX_BIT));

        if (isOwnTeam && !ownFired) {
            int32 cur = engine.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Stamina);
            if (cur < 0) {
                engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, 1);
            }
            int32 maxHp = int32(engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp));
            int32 healAmt = maxHp / HP_DENOM;
            int32 curHp = engine.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp);
            if (curHp + healAmt > 0) {
                healAmt = -curHp;
            }
            if (healAmt > 0) {
                engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Hp, healAmt);
            }
            _forceSwap(engine, battleKey, targetIndex, monIndex, rng);
            ed |= OWN_FIRED_BIT;
            ownFired = true;
        } else if (!isOwnTeam && !oppFired) {
            int32 cur = engine.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Stamina);
            int32 baseStam =
                int32(engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Stamina));
            if (cur > -baseStam) {
                engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, -1);
            }
            uint32 maxHp = engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp);
            int32 dmg = int32(uint32(maxHp)) / HP_DENOM;
            if (dmg > 0) {
                engine.dealDamage(targetIndex, monIndex, dmg);
            }
            // _forceSwap's per-candidate KO check + the (candidate != currentMonIndex) guard mean a
            // post-dealDamage KO read here would be pure overhead — the helper just no-ops if the
            // damaged mon is the only live one.
            _forceSwap(engine, battleKey, targetIndex, monIndex, rng);
            ed |= OPP_FIRED_BIT;
            oppFired = true;
        } else {
            return (extraData, false);
        }

        return (bytes32(ed), ownFired && oppFired);
    }

    function _forceSwap(
        IEngine engine,
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 currentMonIndex,
        uint256 rng
    ) internal {
        int32 target = SwitchTargetLib.findRandomNonKOed(engine, battleKey, playerIndex, currentMonIndex, rng);
        if (target != -1) {
            engine.switchActiveMon(playerIndex, uint256(uint32(target)));
        }
    }
}
