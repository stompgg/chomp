// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Enums.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

contract TestTypeCalculator is ITypeCalculator {
    uint256 private constant ZERO_VALUE = type(uint256).max - 1;

    mapping(uint256 attacker => mapping(uint256 defender => uint256 multiplier)) private typeOverride;

    function setTypeEffectiveness(Type attacker, Type defender, uint256 value) public {
        if (value == 0) {
            typeOverride[uint256(attacker)][uint256(defender)] = ZERO_VALUE;
        } else {
            typeOverride[uint256(attacker)][uint256(defender)] = value;
        }
    }

    function getTypeEffectiveness(Type attacker, Type defender, uint32 basePower) external view returns (uint32) {
        uint256 effectiveness = typeOverride[uint256(attacker)][uint256(defender)];
        if (effectiveness != 0) {
            if (effectiveness == ZERO_VALUE) {
                return 0;
            } else if (effectiveness == 5) {
                return basePower / 2;
            } else {
                return basePower * 2;
            }
        }
        return basePower;
    }
}
