// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

import {MoveMeta} from "../../Structs.sol";
import {Baselight} from "./Baselight.sol";

/**
 * Loop Move for Iblivion
 * - Boosts all 5 stats by a Baselight-scaled percentage (Temp, so removed on switch-out)
 * - Usable once per switch-in: `move()` marks a self-effect as used; its onMonSwitchOut hook
 *   re-arms it, so a fresh switch-in lets Loop fire again. The used flag is the active check.
 */
contract Loop is IMoveSet, BasicEffect {
    uint8 public constant BOOST_PERCENT_LEVEL_1 = 15;
    uint8 public constant BOOST_PERCENT_LEVEL_2 = 30;
    uint8 public constant BOOST_PERCENT_LEVEL_3 = 40;

    Baselight immutable BASELIGHT;

    constructor(Baselight _BASELIGHT) {
        BASELIGHT = _BASELIGHT;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Loop";
    }

    // The marker effect is planted once (first Loop of the battle) and never removed; its extraData
    // is the armed/used flag (1 = used this switch-in, 0 = armed). onMonSwitchOut resets it to 0,
    // so the slot count stays at 1 for the whole battle instead of churning tombstones every cycle.
    function isLoopActive(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        public
        view
        returns (bool)
    {
        (,, bytes32 data) = engine.getEffectData(battleKey, playerIndex, monIndex, address(this));
        return data != bytes32(0);
    }

    function clearLoopActive(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        (bool exists, uint256 effectIndex,) = engine.getEffectData(battleKey, playerIndex, monIndex, address(this));
        if (exists) {
            engine.editEffect(playerIndex, effectIndex, bytes32(0));
        }
    }

    function _getBoostPercent(uint256 baselightLevel) internal pure returns (uint8) {
        if (baselightLevel >= 3) {
            return BOOST_PERCENT_LEVEL_3;
        } else if (baselightLevel == 2) {
            return BOOST_PERCENT_LEVEL_2;
        } else if (baselightLevel == 1) {
            return BOOST_PERCENT_LEVEL_1;
        } else {
            return 0;
        }
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256,
        uint16,
        uint256
    ) external {
        // Loop can only fire once per switch-in; the marker's flag is set until switch-out re-arms it
        (bool markerExists, uint256 markerIndex, bytes32 markerData) =
            engine.getEffectData(battleKey, attackerPlayerIndex, attackerMonIndex, address(this));
        if (markerData != bytes32(0)) {
            return;
        }

        uint256 baselightLevel = BASELIGHT.getBaselightLevel(engine, battleKey, attackerPlayerIndex, attackerMonIndex);
        uint8 boostPercent = _getBoostPercent(baselightLevel);

        // If baselight level is 0, no boost to apply (leave Loop un-armed so it can retry later)
        if (boostPercent == 0) {
            return;
        }

        // Mark Loop as used this switch-in: set the flag on the existing marker, or plant it once
        if (markerExists) {
            engine.editEffect(attackerPlayerIndex, markerIndex, bytes32(uint256(1)));
        } else {
            engine.addEffect(attackerPlayerIndex, attackerMonIndex, IEffect(address(this)), bytes32(uint256(1)));
        }

        // Apply stat boosts to all 5 stats (Attack, Defense, SpecialAttack, SpecialDefense, Speed)
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](5);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack, boostPercent: boostPercent, boostType: StatBoostType.Multiply
        });
        statBoosts[1] = StatBoostToApply({
            stat: MonStateIndexName.Defense, boostPercent: boostPercent, boostType: StatBoostType.Multiply
        });
        statBoosts[2] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack, boostPercent: boostPercent, boostType: StatBoostType.Multiply
        });
        statBoosts[3] = StatBoostToApply({
            stat: MonStateIndexName.SpecialDefense, boostPercent: boostPercent, boostType: StatBoostType.Multiply
        });
        statBoosts[4] = StatBoostToApply({
            stat: MonStateIndexName.Speed, boostPercent: boostPercent, boostType: StatBoostType.Multiply
        });

        // Use Temp flag so boosts are removed on switch out
        engine.addStatBoost(attackerPlayerIndex, attackerMonIndex, statBoosts, StatBoostFlag.Temp);
    }

    // ALWAYS_APPLIES | OnMonSwitchOut (bit 5): the marker only listens for switch-out to re-arm
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8020;
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // Re-arm Loop for the next switch-in by clearing the used flag (marker stays planted).
        // If the flag was already 0 the Engine skips the write (updatedExtraData == data).
        return (bytes32(0), false);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Yang;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
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
}
