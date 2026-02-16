// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Structs.sol";
import "../../src/Enums.sol";
import "../../src/Constants.sol";
import "../../src/Engine.sol";
import "../../src/moves/IMoveSet.sol";

/**
 * @title DoublesForceSwitchMove
 * @notice A mock move for testing switchActiveMonForSlot in doubles battles
 * @dev Forces the target slot to switch to a specific mon index (passed via extraData)
 *      extraData format: lower 4 bits = target slot (0 or 1), next 4 bits = mon index to switch to
 */
contract DoublesForceSwitchMove is IMoveSet {
    Engine public immutable ENGINE;

    constructor(Engine engine) {
        ENGINE = engine;
    }

    function move(bytes32, uint256 attackerPlayerIndex, uint240 extraData, uint256) external {
        // Parse extraData: bits 0-3 = target slot, bits 4-7 = mon to switch to
        uint256 targetSlot = uint256(extraData) & 0x0F;
        uint256 monToSwitchTo = (uint256(extraData) >> 4) & 0x0F;
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;

        // Force the target slot to switch using the doubles-aware function
        ENGINE.switchActiveMonForSlot(defenderPlayerIndex, targetSlot, monToSwitchTo);
    }

    function isValidTarget(bytes32, uint240 extraData) external pure returns (bool) {
        uint256 targetSlot = uint256(extraData) & 0x0F;
        return targetSlot <= 1;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return 0;
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 1;
    }

    function moveType(bytes32) external pure returns (Type) {
        return Type.None;
    }

    function moveClass(bytes32) external pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function basePower(bytes32) external pure returns (uint32) {
        return 0;
    }

    function accuracy(bytes32) external pure returns (uint32) {
        return 100;
    }

    function name() external pure returns (string memory) {
        return "DoublesForceSwitchMove";
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}
