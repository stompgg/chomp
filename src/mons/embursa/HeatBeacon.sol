// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {HeatBeaconLib} from "./HeatBeaconLib.sol";
import {MoveMeta} from "../../Structs.sol";

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
        bytes32,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 defenderMonIndex,
        uint240,
        uint256
    ) external {
        // Apply burn to opposing mon
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        engine.addEffect(defenderPlayerIndex, defenderMonIndex, BURN_STATUS, "");

        // Clear the priority boost
        if (HeatBeaconLib._getPriorityBoost(engine, attackerPlayerIndex) == 1) {
            HeatBeaconLib._clearPriorityBoost(engine, attackerPlayerIndex);
        }

        // Set a new priority boost
        HeatBeaconLib._setPriorityBoost(engine, attackerPlayerIndex);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine engine, bytes32, uint256 attackerPlayerIndex) public view returns (uint32) {
        return DEFAULT_PRIORITY + HeatBeaconLib._getPriorityBoost(engine, attackerPlayerIndex);
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Fire;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
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
