// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {MoveClass, Type} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract PreemptiveShock is IAbility {
    ITypeCalculator immutable TYPE_CALCULATOR;

    uint32 public constant BASE_POWER = 15;
    uint32 public constant DEFAULT_VOL = 10;

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override returns (string memory) {
        return "Preemptive Shock";
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        external
        override
    {
        // Fold the mon identity into the turn rng so same-side/same-turn activations (and the
        // side's slot-0 attacker, which keeps the raw stream) roll independently.
        uint256 shockRng = uint256(keccak256(abi.encode(engine.tempRNG(), playerIndex, monIndex, "PREEMPTIVE_SHOCK")));
        AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            playerIndex,
            monIndex,
            TargetLib.impliedSinglesTargetBits(playerIndex),
            BASE_POWER,
            100,
            DEFAULT_VOL,
            Type.Lightning,
            MoveClass.Physical,
            shockRng,
            0
        );

        // Arm Quickstorm's "first acting turn" window. Turn 0 is always a send-in (moves are coerced
        // to switches), so a mon that enters on turn T first *acts* on turn T+1 for every entry path
        // (lead or mid-battle switch). Store firstActTurn+1 = T+2 so 0 stays "unset".
        uint256 t = engine.getTurnIdForBattleState(battleKey);
        engine.setGlobalKV(_windowKey(playerIndex, monIndex), uint192(t + 2));
    }

    // Shared with Quickstorm: keyed per (side, mon) so it re-arms cleanly on every switch-in.
    function _windowKey(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, monIndex, "QUICKSTORM"))));
    }
}
