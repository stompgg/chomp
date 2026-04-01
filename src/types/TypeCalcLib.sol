// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";

library TypeCalcLib {
    uint256 private constant MULTIPLIERS_1 =
        98387940970013939441334902218489111171706662712193966632938886332804419114328;
    uint256 private constant MULTIPLIERS_2 = 8859915444081173009646859022170283285020904064171667527525;

    function getTypeEffectiveness(Type attackerType, Type defenderType, uint32 basePower)
        internal
        pure
        returns (uint32)
    {
        uint256 index = uint256(attackerType) * 15 + uint256(defenderType);
        uint256 shift;
        uint256 multipliers;

        if (index < 128) {
            shift = index * 2;
            multipliers = MULTIPLIERS_1;
        } else {
            shift = (index - 128) * 2;
            multipliers = MULTIPLIERS_2;
        }

        uint256 typeEffectivenessValue = uint32((multipliers >> shift) & 3);

        if (typeEffectivenessValue == 0) {
            return 0;
        } else if (typeEffectivenessValue == 1) {
            return basePower;
        } else if (typeEffectivenessValue == 2) {
            return basePower * 2;
        } else {
            return basePower / 2;
        }
    }
}
