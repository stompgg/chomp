// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../Structs.sol";

abstract contract BasicEffect is IEffect {
    // Each subclass must override getStepsBitmap() to return a static constant
    // Bit layout: OnApply=0x01, RoundStart=0x02, RoundEnd=0x04, OnRemove=0x08,
    //             OnMonSwitchIn=0x10, OnMonSwitchOut=0x20, AfterDamage=0x40, AfterMove=0x80, OnUpdateMonState=0x100
    function getStepsBitmap() external pure virtual returns (uint16);

    function name() external virtual returns (string memory) {
        return "";
    }

    // Whether or not to add the effect if the step condition is met
    function shouldApply(bytes32, bytes32, uint256, uint256) external virtual returns (bool) {
        return true;
    }

    // Lifecycle hooks during normal battle flow
    function onRoundStart(bytes32, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    function onRoundEnd(bytes32, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: ONLY RUN ON GLOBAL EFFECTS (mons have their Ability as their own hook to apply an effect on switch in)
    function onMonSwitchIn(bytes32, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onMonSwitchOut(bytes32, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onAfterDamage(bytes32, uint256, bytes32 extraData, uint256, uint256, int32)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    function onAfterMove(bytes32, uint256, bytes32 extraData, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    // WARNING: Avoid chaining this effect to prevent recursive calls
    function onUpdateMonState(bytes32, uint256, bytes32 extraData, uint256, uint256, MonStateIndexName, int32)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    // Lifecycle hooks when being applied or removed
    function onApply(bytes32, uint256, bytes32, uint256, uint256)
        external
        virtual
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (updatedExtraData, removeAfterRun);
    }

    function onRemove(bytes32, bytes32 extraData, uint256 targetIndex, uint256 monIndex) external virtual {}
}
