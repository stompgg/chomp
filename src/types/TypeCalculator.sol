// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import {ITypeCalculator} from "./ITypeCalculator.sol";
import {TypeCalcLib} from "./TypeCalcLib.sol";

contract TypeCalculator is ITypeCalculator {
    function getTypeEffectiveness(Type attackerType, Type defenderType, uint32 basePower)
        external
        pure
        returns (uint32)
    {
        return TypeCalcLib.getTypeEffectiveness(attackerType, defenderType, basePower);
    }
}
