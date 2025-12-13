// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract SnackBreak is IMoveSet {
    uint256 public constant DEFAULT_HEAL_DENOM = 2;
    uint256 public constant MAX_DIVISOR = 3;

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() public pure override returns (string memory) {
        return "Snack Break";
    }

    function _getSnackLevel(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal view returns (uint256) {
        return uint256(ENGINE.getGlobalKV(battleKey, keccak256(abi.encode(playerIndex, monIndex, name()))));
    }

    function _increaseSnackLevel(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal {
        uint256 snackLevel = _getSnackLevel(battleKey, playerIndex, monIndex);
        if (snackLevel < MAX_DIVISOR) {
            ENGINE.setGlobalKV(keccak256(abi.encode(playerIndex, monIndex, name())), uint192(snackLevel + 1));
        }
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256) external {
        uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        uint256 snackLevel = _getSnackLevel(battleKey, attackerPlayerIndex, activeMonIndex);
        uint32 maxHp = ENGINE.getMonValueForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp);

        // Heal active mon by max HP / 2**snackLevel
        int32 healAmount = int32(uint32(maxHp / (DEFAULT_HEAL_DENOM * (2 ** snackLevel))));
        int32 currentDamage =
            ENGINE.getMonStateForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp);
        if (currentDamage + healAmount > 0) {
            healAmount = -1 * currentDamage;
        }
        ENGINE.updateMonState(attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp, healAmount);

        // Update the snack level
        _increaseSnackLevel(battleKey, attackerPlayerIndex, activeMonIndex);
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 1;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Nature;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}
