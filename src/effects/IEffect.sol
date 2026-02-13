// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../Structs.sol";

interface IEffect {
    function name() external returns (string memory);

    // Returns pre-computed bitmap of steps this effect runs at (set at deploy time)
    // Bit i is set if effect runs at EffectStep(i)
    function getStepsBitmap() external view returns (uint16);

    // Returns array of steps this effect runs at (used to build bitmap for gas optimization)
    function getStepsToRun() external pure returns (EffectStep[] memory);

    // Whether to run the effect at a specific step
    function shouldRunAtStep(EffectStep r) external returns (bool);

    // Whether or not to add the effect if some condition is met
    function shouldApply(bytes32 extraData, uint256 targetIndex, uint256 monIndex) external returns (bool);

    // Lifecycle hooks during normal battle flow
    function onRoundStart(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        returns (bytes32 updatedExtraData, bool removeAfterRun);
    function onRoundEnd(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onMonSwitchIn(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onMonSwitchOut(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        returns (bytes32 updatedExtraData, bool removeAfterRun);

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onAfterDamage(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex, int32 damage)
        external
        returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onAfterMove(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        returns (bytes32 updatedExtraData, bool removeAfterRun);

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    // WARNING: Avoid chaining this effect to prevent recursive calls
    // (e.g., an effect that mutates state triggering another effect that mutates state)
    function onUpdateMonState(
        uint256 rng,
        bytes32 extraData,
        uint256 playerIndex,
        uint256 monIndex,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    // Lifecycle hooks when being applied or removed
    function onApply(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        returns (bytes32 updatedExtraData, bool removeAfterRun);
    function onRemove(bytes32 extraData, uint256 targetIndex, uint256 monIndex) external;
}
