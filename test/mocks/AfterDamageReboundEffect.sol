// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract AfterDamageReboundEffect is BasicEffect {

    // Steps: AfterDamage
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x40;
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onAfterDamage(IEngine engine, bytes32 battleKey, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256, uint256, int32)
        external
        override
        returns (bytes32, bool)
    {
        // Heals for all damage done
        int32 currentDamage =
            engine.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp);
        engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Hp, currentDamage * -1);
        return (extraData, false);
    }
}
