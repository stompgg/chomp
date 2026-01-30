// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../Structs.sol";

abstract contract BasicEffect is IEffect {
    function name() external virtual returns (string memory) {
        return "";
    }

    // Whether to run the effect at a specific step
    function shouldRunAtStep(EffectStep r) external virtual returns (bool);

    // Whether or not to add the effect if the step condition is met
    function shouldApply(bytes32, uint256, uint256) external virtual returns (bool) {
        return true;
    }

    // Lifecycle hooks during normal battle flow
    function onRoundStart(EffectContext calldata, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    function onRoundEnd(EffectContext calldata, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: ONLY RUN ON GLOBAL EFFECTS (mons have their Ability as their own hook to apply an effect on switch in)
    function onMonSwitchIn(EffectContext calldata, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onMonSwitchOut(EffectContext calldata, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onAfterDamage(EffectContext calldata, uint256, bytes32 extraData, uint256, uint256, int32)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    function onAfterMove(EffectContext calldata, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    // WARNING: Avoid chaining this effect to prevent recursive calls
    function onUpdateMonState(EffectContext calldata, uint256, bytes32 extraData, uint256, uint256, MonStateIndexName, int32)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // Lifecycle hooks when being applied or removed
    function onApply(EffectContext calldata, uint256, bytes32, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (updatedExtraData, removeAfterRun);
    }

    function onRemove(bytes32 extraData, uint256 targetIndex, uint256 monIndex) external virtual {}
}
