// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Enums.sol";
import "../IEngine.sol";
import "../Structs.sol";

interface IEffect {
    function name() external returns (string memory);

    // Returns static metadata: lifecycle steps in bits 0-15 and requested fresh-context steps in
    // bits 16-31. Lifecycle layout: OnApply=0x01, RoundStart=0x02, RoundEnd=0x04,
    // OnRemove=0x08, OnMonSwitchIn=0x10, OnMonSwitchOut=0x20, AfterDamage=0x40,
    // AfterMove=0x80, OnUpdateMonState=0x100, PreDamage=0x200. Legacy deployed effects returning
    // only the low uint16 remain EVM-compatible and simply request no fresh context.
    function getStepsBitmap() external view returns (uint32);

    // Whether or not to add the effect if some condition is met
    function shouldApply(IEngine engine, bytes32 battleKey, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        returns (bool);

    // Lifecycle hooks during normal battle flow.
    // `activesPacked` carries every slot's active roster index in its low 32 bits (one 8-bit lane
    // per absolute slot, EMPTY_ACTIVE_LANE = no mon there). For an opted-in AfterMove hook, Engine
    // also embeds fresh 24-bit move lanes at bits 32..127 and the acted-slot mask at bits 128..131.
    // Existing effects remain compatible; opt-in readers decode the high context via TargetLib.
    function onRoundStart(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onMonSwitchIn(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onMonSwitchOut(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    // `source` is the originator of the damage (low 160 bits = address for external dealDamage
    // callers; full uint256 = packed move slot for the inline-StandardAttack path — detect with
    // `source >> 160 != 0`). `damage` is the final post-PreDamage value actually applied.
    function onAfterDamage(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked,
        int32 damage,
        uint256 source
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    // Runs before damage is applied; effects can mutate the in-flight damage by calling
    // `engine.setPreDamage(int32)`. Read the current running damage via `engine.getPreDamage()`.
    // Multiple subscribed effects compose sequentially in effect-array order, each observing
    // the post-mutation value from prior effects.
    function onPreDamage(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked,
        uint256 source
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    // NOTE: CURRENTLY ONLY RUN LOCALLY ON MONS (global effects do not have this hook)
    // WARNING: Avoid chaining this effect to prevent recursive calls
    // (e.g., an effect that mutates state triggering another effect that mutates state)
    function onUpdateMonState(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 playerIndex,
        uint256 monIndex,
        uint256 activesPacked,
        MonStateIndexName stateVarIndex,
        int32 valueToAdd
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    // Lifecycle hooks when being applied or removed
    function onApply(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external returns (bytes32 updatedExtraData, bool removeAfterRun);

    function onRemove(
        IEngine engine,
        bytes32 battleKey,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external;
}
