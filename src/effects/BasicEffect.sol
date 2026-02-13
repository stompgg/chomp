// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../Structs.sol";

abstract contract BasicEffect is IEffect {
    // Each subclass must override getStepsBitmap() to return a static constant
    // Bitmap layout: bit i is set if effect runs at EffectStep(i)
    // EffectStep enum: OnApply=0, RoundStart=1, RoundEnd=2, OnRemove=3,
    //                  OnMonSwitchIn=4, OnMonSwitchOut=5, AfterDamage=6, AfterMove=7, OnUpdateMonState=8
    function getStepsBitmap() external pure virtual returns (uint16);

    // Each subclass must override to return the steps array
    function getStepsToRun() external pure virtual returns (EffectStep[] memory);

    function name() external virtual returns (string memory) {
        return "";
    }

    // Whether or not to add the effect if the step condition is met
    function shouldApply(bytes32, uint256, uint256) external virtual returns (bool) {
        return true;
    }

    // Lifecycle hooks during normal battle flow
    function onRoundStart(uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    function onRoundEnd(uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: ONLY RUN ON GLOBAL EFFECTS (mons have their Ability as their own hook to apply an effect on switch in)
    function onMonSwitchIn(uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onMonSwitchOut(uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onAfterDamage(uint256, bytes32 extraData, uint256, uint256, int32)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    function onAfterMove(uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    // WARNING: Avoid chaining this effect to prevent recursive calls
    function onUpdateMonState(uint256, bytes32 extraData, uint256, uint256, MonStateIndexName, int32)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // Lifecycle hooks when being applied or removed
    function onApply(uint256, bytes32, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (updatedExtraData, removeAfterRun);
    }

    function onRemove(bytes32 extraData, uint256 targetIndex, uint256 monIndex) external virtual {}
}
