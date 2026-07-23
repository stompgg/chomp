// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MOVE_INDEX_MASK, NO_OP_MOVE_INDEX, NO_SLOT} from "../../src/Constants.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IEngine} from "../../src/IEngine.sol";
import {TargetLib} from "../../src/lib/TargetLib.sol";

uint256 constant TEST_CONTEXT_STATUS_CLASS = 15;

contract RewriteMoveAfterMove is BasicEffect {
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x8080;
    }

    function onAfterMove(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external override returns (bytes32, bool) {
        uint256 ownSlot = TargetLib.slotOfMon(activesPacked, targetIndex, monIndex);
        if (ownSlot != NO_SLOT) {
            engine.setMoveForSlot(battleKey, targetIndex, ownSlot & 1, NO_OP_MOVE_INDEX, 0);
        }
        return (extraData, false);
    }
}

contract FreshMoveContextAbility is IAbility, BasicEffect {
    IEffect private immutable REWRITER;
    uint8 public observedMoveIndex;

    constructor() {
        REWRITER = IEffect(address(new RewriteMoveAfterMove()));
    }

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Fresh Move Context";
    }

    function activateOnSwitch(IEngine engine, bytes32, uint256 playerIndex, uint256 monIndex) external override {
        // Stable effect-array order: the rewriter runs before this observer.
        engine.addEffect(playerIndex, monIndex, REWRITER, bytes32(0));
        engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    function getStepsBitmap() external pure override returns (uint32) {
        return 0x00808080; // AfterMove context | ALWAYS_APPLIES | AfterMove
    }

    function onAfterMove(IEngine, bytes32, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256 context)
        external
        override
        returns (bytes32, bool)
    {
        uint256 ownSlot = TargetLib.slotOfMon(context, targetIndex, monIndex);
        observedMoveIndex = uint8(TargetLib.hookMoveWordAt(context, ownSlot)) & MOVE_INDEX_MASK;
        return (extraData, false);
    }
}

contract ContextTestStatus is BasicEffect {
    function getStepsBitmap() external pure override returns (uint32) {
        return uint32(0x8000 | (TEST_CONTEXT_STATUS_CLASS << 10));
    }
}

contract AddStatusAtRoundEnd is BasicEffect {
    IEffect private immutable STATUS;

    constructor(IEffect status) {
        STATUS = status;
    }

    function getStepsBitmap() external pure override returns (uint32) {
        return 0x8004;
    }

    function onRoundEnd(IEngine engine, bytes32, uint256, bytes32 extraData, uint256 side, uint256 mon, uint256)
        external
        override
        returns (bytes32, bool)
    {
        engine.addEffect(side, mon, STATUS, bytes32(0));
        return (extraData, false);
    }
}

contract FreshStatusContextAbility is IAbility, BasicEffect {
    IEffect private immutable WRITER;
    uint8 public observedStatusClass;

    constructor() {
        IEffect status = IEffect(address(new ContextTestStatus()));
        WRITER = IEffect(address(new AddStatusAtRoundEnd(status)));
    }

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Fresh Status Context";
    }

    function activateOnSwitch(IEngine engine, bytes32, uint256 playerIndex, uint256 monIndex) external override {
        engine.addEffect(playerIndex, monIndex, WRITER, bytes32(0));
        engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    function getStepsBitmap() external pure override returns (uint32) {
        return 0x00048004; // RoundEnd context | ALWAYS_APPLIES | RoundEnd
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256 side, uint256 mon, uint256 context)
        external
        override
        returns (bytes32, bool)
    {
        observedStatusClass = uint8(TargetLib.hookStatusClass(context, side, mon));
        return (extraData, false);
    }
}
