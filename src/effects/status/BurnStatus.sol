// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../Enums.sol";
import {StatBoostToApply, EffectInstance} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";

import {StatBoosts} from "../StatBoosts.sol";
import {StatusEffect} from "./StatusEffect.sol";
import {StatusEffectLib} from "./StatusEffectLib.sol";

contract BurnStatus is StatusEffect {

    uint256 public constant MAX_BURN_DEGREE = 3;

    uint8 public constant ATTACK_PERCENT = 50;

    int32 public constant DEG1_DAMAGE_DENOM = 16;
    int32 public constant DEG2_DAMAGE_DENOM = 8;
    int32 public constant DEG3_DAMAGE_DENOM = 4;

    StatBoosts immutable STAT_BOOSTS;

    constructor(IEngine engine, StatBoosts statBoosts) StatusEffect(engine) {
        STAT_BOOSTS = statBoosts;
    }

    function name() public pure override returns (string memory) {
        return "Burn";
    }

    // Steps: OnApply, RoundStart, RoundEnd, OnRemove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x0F;
    }

    function shouldApply(bytes32 battleKey, bytes32, uint256 targetIndex, uint256 monIndex) public view override returns (bool) {
        bytes32 keyForMon = StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex);

        // Get value from ENGINE KV
        uint192 monStatusFlag = ENGINE.getGlobalKV(battleKey, keyForMon);

        // Check if a status already exists for the mon (or if it's already burned)
        bool noStatus = monStatusFlag == 0;
        bool hasBurnAlready = monStatusFlag == uint192(uint160(address(this)));
        return (noStatus || hasBurnAlready);
    }

    function getKeyForMonIndex(uint256 targetIndex, uint256 monIndex) public pure returns (bytes32) {
        return keccak256(abi.encode(targetIndex, monIndex, name()));
    }

    function onApply(
        bytes32 battleKey,
        uint256 rng,
        bytes32,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    )
        public
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        bool hasBurnAlready;
        {
            bytes32 keyForMon = StatusEffectLib.getKeyForMonIndex(targetIndex, monIndex);
            uint192 monStatusFlag = ENGINE.getGlobalKV(battleKey, keyForMon);
            hasBurnAlready = monStatusFlag == uint192(uint160(address(this)));
        }

        // Set burn flag
        super.onApply(battleKey, rng, bytes32(0), targetIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);

        // Set stat debuff or increase burn degree
        if (!hasBurnAlready) {
            // Reduce attack by 1/ATTACK_DENOM of base attack stat
            StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
            statBoosts[0] = StatBoostToApply({
                stat: MonStateIndexName.Attack,
                boostPercent: ATTACK_PERCENT,
                boostType: StatBoostType.Divide
            });
            STAT_BOOSTS.addStatBoosts(targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);
        } else {
            (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, targetIndex, monIndex);
            uint256 indexOfBurnEffect;
            uint256 burnDegree;
            bytes32 newExtraData;
            for (uint256 i = 0; i < effects.length; i++) {
                if (address(effects[i].effect) == address(this)) {
                    indexOfBurnEffect = indices[i];
                    burnDegree = uint256(effects[i].data);
                    newExtraData = effects[i].data;
                }
            }
            if (burnDegree < MAX_BURN_DEGREE) {
                newExtraData = bytes32(burnDegree + 1);
            }
            ENGINE.editEffect(targetIndex, monIndex, indexOfBurnEffect, newExtraData);
        }

        return (bytes32(uint256(1)), hasBurnAlready);
    }

    function onRemove(
        bytes32 battleKey,
        bytes32,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) public override {
        // Remove the base status flag
        super.onRemove(battleKey, bytes32(0), targetIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);

        // Reset the attack reduction
        STAT_BOOSTS.removeStatBoosts(targetIndex, monIndex, StatBoostFlag.Perm);

        // Reset the burn degree
        ENGINE.setGlobalKV(getKeyForMonIndex(targetIndex, monIndex), 0);
    }

    // Deal damage over time
    function onRoundEnd(
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256,
        uint256
    )
        external
        override
        returns (bytes32, bool)
    {
        uint256 burnDegree = uint256(extraData);
        int32 damageDenom = DEG1_DAMAGE_DENOM;
        if (burnDegree == 2) {
            damageDenom = DEG2_DAMAGE_DENOM;
        }
        if (burnDegree == 3) {
            damageDenom = DEG3_DAMAGE_DENOM;
        }
        int32 damage =
            int32(ENGINE.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp))
            / damageDenom;
        ENGINE.dealDamage(targetIndex, monIndex, damage);
        return (extraData, false);
    }
}
