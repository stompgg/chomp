// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";

contract AfterDamageReboundEffect is BasicEffect {
    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    // Should run at end of round
    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        return r == EffectStep.AfterDamage;
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onAfterDamage(EffectContext calldata ctx, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, int32)
        external
        override
        returns (bytes32, bool)
    {
        // Heals for all damage done
        int32 currentDamage =
            ENGINE.getMonStateForBattle(ctx.battleKey, targetIndex, monIndex, MonStateIndexName.Hp);
        ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Hp, currentDamage * -1);
        return (extraData, false);
    }
}
