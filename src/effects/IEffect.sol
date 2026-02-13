// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../Structs.sol";

interface IEffect {
    function name() external returns (string memory);

    // Returns pre-computed bitmap of steps this effect runs at (set at deploy time)
    // Bit layout: OnApply=0x01, RoundStart=0x02, RoundEnd=0x04, OnRemove=0x08,
    //             OnMonSwitchIn=0x10, OnMonSwitchOut=0x20, AfterDamage=0x40, AfterMove=0x80, OnUpdateMonState=0x100
    function getStepsBitmap() external view returns (uint16);

    // Whether or not to add the effect if some condition is met
    function shouldApply(bytes32 battleKey, bytes32 extraData, uint256 targetIndex, uint256 monIndex) external returns (bool);

    // Lifecycle hooks during normal battle flow
    // p0ActiveMonIndex and p1ActiveMonIndex are passed to avoid external calls back to Engine
    function onRoundStart(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onRoundEnd(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onMonSwitchIn(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onMonSwitchOut(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    function onAfterDamage(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex,
        int32 damage
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onAfterMove(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    // WARNING: Avoid chaining this effect to prevent recursive calls
    // (e.g., an effect that mutates state triggering another effect that mutates state)
    function onUpdateMonState(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 playerIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    // Lifecycle hooks when being applied or removed
    function onApply(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onRemove(
        bytes32 battleKey,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external;
}
