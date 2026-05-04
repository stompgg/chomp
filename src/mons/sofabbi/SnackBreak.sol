// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {MoveMeta} from "../../Structs.sol";

contract SnackBreak is IMoveSet {
    uint256 public constant DEFAULT_HEAL_DENOM = 2;
    uint256 public constant MAX_DIVISOR = 3;

    function name() public pure override returns (string memory) {
        return "Snack Break";
    }

    function _snackKey(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, monIndex, name()))));
    }

    function _getSnackLevel(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        internal
        view
        returns (uint256)
    {
        return uint256(engine.getGlobalKV(battleKey, _snackKey(playerIndex, monIndex)));
    }

    function _increaseSnackLevel(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal {
        uint256 snackLevel = _getSnackLevel(engine, battleKey, playerIndex, monIndex);
        if (snackLevel < MAX_DIVISOR) {
            engine.setGlobalKV(_snackKey(playerIndex, monIndex), uint192(snackLevel + 1));
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
        uint256 snackLevel = _getSnackLevel(engine, battleKey, attackerPlayerIndex, attackerMonIndex);
        uint32 maxHp =
            engine.getMonValueForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);

        // Heal active mon by max HP / 2**snackLevel
        int32 healAmount = int32(uint32(maxHp / (DEFAULT_HEAL_DENOM * (2 ** snackLevel))));
        int32 currentDamage =
            engine.getMonStateForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);
        if (currentDamage + healAmount > 0) {
            healAmount = -1 * currentDamage;
        }
        engine.updateMonState(attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp, healAmount);

        // Update the snack level
        _increaseSnackLevel(engine, battleKey, attackerPlayerIndex, attackerMonIndex);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 1;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Nature;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
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
