// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Enums.sol";
import "../../Structs.sol";

import {ALWAYS_APPLIES_BIT} from "../../Constants.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";

/// @notice For a fixed number of active turns after its first entry, Mulong halves the damage it
///         takes and the damage it deals. Arms once per battle; the countdown only advances on
///         rounds Mulong is on the field, so bench time and forced-switch turns don't burn it.
contract KingsLeisure is IAbility, BasicEffect {
    uint256 public constant DURATION = 3;
    uint8 public constant ATTACK_DEBUFF_PERCENT = 50;
    int32 public constant DAMAGE_DENOM = 2;

    function _armedKey(uint256 playerIndex, uint256 monIndex) internal view returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, monIndex, address(this)))));
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        uint64 armedKey = _armedKey(playerIndex, monIndex);
        if (engine.getGlobalKV(battleKey, armedKey) != 0) {
            return;
        }
        engine.setGlobalKV(armedKey, 1);

        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](2);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack, boostPercent: ATTACK_DEBUFF_PERCENT, boostType: StatBoostType.Divide
        });
        statBoosts[1] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack, boostPercent: ATTACK_DEBUFF_PERCENT, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(playerIndex, monIndex, statBoosts, StatBoostFlag.Perm);

        engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(DURATION));
    }

    // Steps: RoundEnd, OnRemove, PreDamage, ALWAYS_APPLIES; fresh PreDamage context.
    // No OnApply — activateOnSwitch seeds the countdown and applies the debuff itself.
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x0200820C;
    }

    function onPreDamage(
        IEngine engine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256,
        uint256,
        uint256 hookContext,
        uint256
    ) external override returns (bytes32, bool) {
        engine.setPreDamage(TargetLib.hookPreDamage(hookContext) / DAMAGE_DENOM);
        return (extraData, false);
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        uint256 turnsLeft = uint256(extraData);
        if (turnsLeft <= 1) {
            return (extraData, true);
        }
        return (bytes32(turnsLeft - 1), false);
    }

    function onRemove(IEngine engine, bytes32, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        external
        override
    {
        engine.removeStatBoost(targetIndex, monIndex, StatBoostFlag.Perm);
    }
}
