// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {MoveMeta} from "../../Structs.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {StatusEffectLib} from "../../effects/status/StatusEffectLib.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {HeatBeaconLib} from "./HeatBeaconLib.sol";

contract HeatBeacon is IMoveSet {
    IEffect immutable BURN_STATUS;

    constructor(IEffect _BURN_STATUS) {
        BURN_STATUS = _BURN_STATUS;
    }

    function name() public pure override returns (string memory) {
        return "Heat Beacon";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        // Only spread Burn to the opponent if Embursa is itself Burned.
        uint64 selfStatusKey = StatusEffectLib.getKeyForMonIndex(attackerPlayerIndex, attackerMonIndex);
        if (engine.getGlobalKV(battleKey, selfStatusKey) == uint192(uint160(address(BURN_STATUS)))) {
            uint256 targetSlot = TargetLib.lowestSlot(targetBits);
            if (targetSlot != NO_SLOT) {
                uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
                uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
                engine.addEffect(defenderPlayerIndex, defenderMonIndex, BURN_STATUS, "");
            }
        }

        // Grant +1 priority to next turn's move (idempotent refresh; consumed by the payoff move).
        HeatBeaconLib._setPriorityBoost(engine, attackerPlayerIndex);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function priority(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex) public view returns (uint32) {
        return DEFAULT_PRIORITY + HeatBeaconLib._getPriorityBoost(engine, battleKey, attackerPlayerIndex);
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Fire;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
