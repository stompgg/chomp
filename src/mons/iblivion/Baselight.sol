// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {EffectStep} from "../../Enums.sol";
import {EffectInstance} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

/**
 * Baselight Ability for Iblivion
 * - Starts at 1 stack when the mon first switches in (only on first switch-in of the game)
 * - Gains 1 stack at the end of each turn, up to a max of 3
 * - Level is stored in the effect's extraData
 */
contract Baselight is IAbility, BasicEffect {
    uint256 public constant MAX_BASELIGHT_LEVEL = 3;
    uint256 public constant INITIAL_BASELIGHT_LEVEL = 1;

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Baselight";
    }

    /// @dev Finds the Baselight effect on a mon and returns its state
    /// @return exists Whether the effect exists on this mon
    /// @return effectIndex The index to use with editEffect (only valid if exists)
    /// @return level The current Baselight level (0 if not exists)
    function _findBaselightEffect(bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        internal
        view
        returns (bool exists, uint256 effectIndex, uint256 level)
    {
        (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i = 0; i < effects.length;) {
            if (address(effects[i].effect) == address(this)) {
                return (true, indices[i], uint256(effects[i].data));
            }
            unchecked { ++i; }
        }
        return (false, 0, 0);
    }

    function getBaselightLevel(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) public view returns (uint256) {
        (,, uint256 level) = _findBaselightEffect(battleKey, playerIndex, monIndex);
        return level;
    }

    function setBaselightLevel(uint256 playerIndex, uint256 monIndex, uint256 level) public {
        if (level > MAX_BASELIGHT_LEVEL) {
            level = MAX_BASELIGHT_LEVEL;
        }
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        (bool exists, uint256 effectIndex,) = _findBaselightEffect(battleKey, playerIndex, monIndex);
        if (exists) {
            ENGINE.editEffect(playerIndex, monIndex, effectIndex, bytes32(level));
        }
    }

    function decreaseBaselightLevel(uint256 playerIndex, uint256 monIndex, uint256 amount) public {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        (bool exists, uint256 effectIndex, uint256 currentLevel) = _findBaselightEffect(battleKey, playerIndex, monIndex);
        if (exists) {
            uint256 newLevel = amount >= currentLevel ? 0 : currentLevel - amount;
            ENGINE.editEffect(playerIndex, monIndex, effectIndex, bytes32(newLevel));
        }
    }

    // IAbility implementation - called when the mon switches in
    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        (bool exists,,) = _findBaselightEffect(battleKey, playerIndex, monIndex);
        if (exists) {
            return;
        }
        // First switch-in: add effect with initial Baselight level stored in extraData
        ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(uint256(INITIAL_BASELIGHT_LEVEL)));
    }

    // Steps: RoundEnd
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x04;
    }

    function onRoundEnd(uint256, bytes32 extraData, uint256, uint256)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        uint256 currentLevel = uint256(extraData);
        if (currentLevel < MAX_BASELIGHT_LEVEL) {
            return (bytes32(currentLevel + 1), false);
        }
        return (extraData, false);
    }
}
