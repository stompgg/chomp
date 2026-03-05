// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../Structs.sol";

import {Ownable} from "../lib/Ownable.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {StandardAttack} from "./StandardAttack.sol";
import {ATTACK_PARAMS} from "./StandardAttackStructs.sol";

contract StandardAttackFactory is Ownable {
    ITypeCalculator public TYPE_CALCULATOR;

    event StandardAttackCreated(address a);

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        _initializeOwner(msg.sender);
    }

    function createAttack(ATTACK_PARAMS memory params) external returns (StandardAttack attack) {
        attack = new StandardAttack(msg.sender, TYPE_CALCULATOR, params);
        emit StandardAttackCreated(address(attack));
    }

    function setTypeCalculator(ITypeCalculator _TYPE_CALCULATOR) external onlyOwner {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }
}
