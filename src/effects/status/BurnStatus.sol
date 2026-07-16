// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {StatBoostToApply} from "../../Structs.sol";

import {StatusEffect} from "./StatusEffect.sol";
import {StatusEffectLib} from "./StatusEffectLib.sol";

contract BurnStatus is StatusEffect {
    uint256 public constant MAX_BURN_DEGREE = 3;

    uint8 public constant ATTACK_PERCENT = 50;

    int32 public constant DEG1_DAMAGE_DENOM = 16;
    int32 public constant DEG2_DAMAGE_DENOM = 8;
    int32 public constant DEG3_DAMAGE_DENOM = 4;

    function name() public pure override returns (string memory) {
        return "Burn";
    }

    // Steps: OnApply, RoundEnd, OnRemove (no RoundStart behavior — the bit would only buy a
    // no-op external call per burned turn)
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x0D;
    }

    // extraData layout: [burn degree: bits 0-7 | cached max HP: bits 32-63]. Base HP is fixed
    // for the battle, so caching it at apply saves the per-tick engine read.

    function shouldApply(IEngine engine, bytes32 battleKey, bytes32, uint256 targetIndex, uint256 monIndex)
        public
        view
        override
        returns (bool)
    {
        uint64 keyForMon = StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex);

        // Get value from engine KV
        uint192 monStatusFlag = engine.getGlobalKV(battleKey, keyForMon);

        // Check if a status already exists for the mon (or if it's already burned)
        bool noStatus = monStatusFlag == 0;
        bool hasBurnAlready = monStatusFlag == uint192(uint160(address(this)));
        return (noStatus || hasBurnAlready);
    }

    function onApply(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) public override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        bool hasBurnAlready;
        {
            uint64 keyForMon = StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex);
            uint192 monStatusFlag = engine.getGlobalKV(battleKey, keyForMon);
            hasBurnAlready = monStatusFlag == uint192(uint160(address(this)));
            // Set the burn flag only when fresh — this single read replaces both super.onApply's
            // guard re-read and its redundant same-value write on the escalation path.
            if (!hasBurnAlready) {
                engine.setGlobalKV(keyForMon, uint192(uint160(address(this))));
            }
        }

        // Set stat debuff or increase burn degree
        if (!hasBurnAlready) {
            // Reduce attack by 1/ATTACK_DENOM of base attack stat
            StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
            statBoosts[0] = StatBoostToApply({
                stat: MonStateIndexName.Attack, boostPercent: ATTACK_PERCENT, boostType: StatBoostType.Divide
            });
            engine.addStatBoost(targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);
        } else {
            // Single burn per mon (one-status invariant), so the first by-address match is the one.
            (, uint256 indexOfBurnEffect, bytes32 burnData) =
                engine.getEffectData(battleKey, targetIndex, monIndex, address(this));
            uint256 burnDegree = uint256(burnData) & 0xFF;
            bytes32 newExtraData = burnData;
            if (burnDegree < MAX_BURN_DEGREE) {
                newExtraData = bytes32((uint256(newExtraData) & ~uint256(0xFF)) | (burnDegree + 1));
            }
            engine.editEffect(targetIndex, indexOfBurnEffect, newExtraData);
            return (bytes32(0), true);
        }

        uint256 maxHp = uint256(engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp));
        return (bytes32(uint256(1) | (maxHp << 32)), false);
    }

    function onRemove(
        IEngine engine,
        bytes32 battleKey,
        bytes32,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) public override {
        // Remove the base status flag
        super.onRemove(engine, battleKey, bytes32(0), targetIndex, monIndex, activesPacked);

        // Reset the attack reduction
        engine.removeStatBoost(targetIndex, monIndex, StatBoostFlag.Perm);
        // NOTE: no burn-degree KV reset — the degree lives in effect extraData (see onApply /
        // onRoundEnd), and the old per-mon degree key was never written nor read anywhere.
    }

    // Deal damage over time
    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) external override returns (bytes32, bool) {
        uint256 burnDegree = uint256(extraData) & 0xFF;
        int32 damageDenom = DEG1_DAMAGE_DENOM;
        if (burnDegree == 2) {
            damageDenom = DEG2_DAMAGE_DENOM;
        }
        if (burnDegree == 3) {
            damageDenom = DEG3_DAMAGE_DENOM;
        }
        int32 damage = int32(uint32(uint256(extraData) >> 32)) / damageDenom;
        engine.dealDamage(targetIndex, monIndex, damage);
        return (extraData, false);
    }
}
