// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/// @dev Distinct msg.sender per boost source (sources are keyed by caller). Memory prep happens
///      before the gas bracket so the measurement is the engine call alone (+ ~constant CALL
///      overhead, identical across K).
contract BoostSatellite {
    function boost(IEngine engine, uint256 playerIndex, uint256 monIndex, uint8 pct) external returns (uint256 g) {
        StatBoostToApply[] memory b = new StatBoostToApply[](1);
        b[0] = StatBoostToApply({stat: MonStateIndexName.Attack, boostPercent: pct, boostType: StatBoostType.Multiply});
        uint256 g0 = gasleft();
        engine.addStatBoost(playerIndex, monIndex, b, StatBoostFlag.Perm);
        g = g0 - gasleft();
    }

    function unboost(IEngine engine, uint256 playerIndex, uint256 monIndex) external returns (uint256 g) {
        uint256 g0 = gasleft();
        engine.removeStatBoost(playerIndex, monIndex, StatBoostFlag.Perm);
        g = g0 - gasleft();
    }
}

/// @dev R1.0 microbench driver: extraData = K (0..5) existing sources to install, then measures
///      one more add (the K+1th source) and its removal. Results parked in public storage.
contract BoostBenchMove is IMoveSet {
    BoostSatellite[6] public sats;
    uint256 public lastAddGas;
    uint256 public lastRemoveGas;

    constructor() {
        for (uint256 i; i < 6; i++) {
            sats[i] = new BoostSatellite();
        }
    }

    function name() external pure returns (string memory) {
        return "Boost Bench";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256, uint256, uint256, uint16 extraData, uint256)
        external
    {
        uint256 k = uint256(extraData) & 0x7;
        for (uint256 i; i < k; i++) {
            sats[i].boost(engine, attackerPlayerIndex, 0, uint8(10 + i));
        }
        lastAddGas = sats[k].boost(engine, attackerPlayerIndex, 0, 50);
        lastRemoveGas = sats[k].unboost(engine, attackerPlayerIndex, 0);
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return 0;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Air;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}
