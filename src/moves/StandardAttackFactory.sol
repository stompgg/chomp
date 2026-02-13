// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";

import {Ownable} from "../lib/Ownable.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {StandardAttack} from "./StandardAttack.sol";
import {ATTACK_PARAMS} from "./StandardAttackStructs.sol";

contract StandardAttackFactory is Ownable {
    IEngine public ENGINE;
    ITypeCalculator public TYPE_CALCULATOR;

    event StandardAttackCreated(address a);

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR) {
        ENGINE = _ENGINE;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        _initializeOwner(msg.sender);
    }

    function createAttack(ATTACK_PARAMS calldata params) external returns (StandardAttack attack) {
        attack = new StandardAttack(msg.sender, ENGINE, TYPE_CALCULATOR, params);
        emit StandardAttackCreated(address(attack));
    }

    function setEngine(IEngine _ENGINE) external onlyOwner {
        ENGINE = _ENGINE;
    }

    function setTypeCalculator(ITypeCalculator _TYPE_CALCULATOR) external onlyOwner {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }
}
