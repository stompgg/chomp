// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract GildedRecovery is IMoveSet {
    int32 public constant HEAL_PERCENT = 50;
    int32 public constant STAMINA_BONUS = 1;

    function name() public pure override returns (string memory) {
        return "Gilded Recovery";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16 extraData,
        uint256
    ) external {
        // extraData contains the mon index as raw uint16
        uint256 targetMonIndex = uint256(extraData);

        // Remove the target mon's status (any class); heal + grant stamina only on success
        if (engine.clearMonStatus(attackerPlayerIndex, targetMonIndex, 0)) {
            // Give +1 stamina
            engine.updateMonState(attackerPlayerIndex, targetMonIndex, MonStateIndexName.Stamina, STAMINA_BONUS);

            // Heal 50% of max HP for self
            (uint32 maxHpRaw, int32 currentHpDelta) =
                engine.getMonHpState(battleKey, attackerPlayerIndex, attackerMonIndex);
            int32 maxHp = int32(maxHpRaw);
            int32 healAmount = (maxHp * HEAL_PERCENT) / 100;

            // Don't overheal
            if (currentHpDelta + healAmount > 0) {
                healAmount = -currentHpDelta;
            }

            if (healAmount != 0) {
                engine.updateMonState(attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp, healAmount);
            }
        }
        // If no status effect, do nothing
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Faith;
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
