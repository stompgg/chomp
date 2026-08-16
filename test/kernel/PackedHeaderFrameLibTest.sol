// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Test} from "../../lib/forge-std/src/Test.sol";

import {BattleConfig, BattleData} from "../../src/Structs.sol";
import {PackedHeaderFrameLib} from "../../src/kernel/PackedHeaderFrameLib.sol";

contract PackedHeaderFrameHarness {
    using PackedHeaderFrameLib for PackedHeaderFrameLib.Frame;

    BattleData private battle;
    BattleConfig private config;

    function setRaw(uint256 wordIndex, uint256 value) external {
        uint256 slot = _slot(wordIndex);
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    function getRaw(uint256 wordIndex) external view returns (uint256 value) {
        uint256 slot = _slot(wordIndex);
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function probeTwice(uint256 wordIndex)
        external
        view
        returns (uint256 first, uint256 second, uint16 loadedMask, uint16 dirtyMask)
    {
        PackedHeaderFrameLib.Frame memory frame = PackedHeaderFrameLib.init(battle, config);
        first = frame.read(wordIndex);
        second = frame.read(wordIndex);
        loadedMask = frame.loadedMask;
        dirtyMask = frame.dirtyMask;
    }

    function writeAndFlush(uint256 wordIndex, uint256 value)
        external
        returns (uint16 loadedBeforeFlush, uint16 dirtyBeforeFlush, uint16 dirtyAfterFlush)
    {
        PackedHeaderFrameLib.Frame memory frame = PackedHeaderFrameLib.init(battle, config);
        frame.write(wordIndex, value);
        loadedBeforeFlush = frame.loadedMask;
        dirtyBeforeFlush = frame.dirtyMask;
        frame.flush();
        dirtyAfterFlush = frame.dirtyMask;
    }

    function readBattleState()
        external
        view
        returns (
            address p0,
            address p1,
            uint8 winner,
            uint8 switchFlag,
            uint16 active,
            uint40 timestamp,
            uint16 turn,
            uint8 buffered
        )
    {
        PackedHeaderFrameLib.Frame memory frame = PackedHeaderFrameLib.init(battle, config);
        return (
            frame.p0(),
            frame.p1(),
            frame.winnerIndex(),
            frame.playerSwitchForTurnFlag(),
            frame.activeMonIndex(),
            frame.lastExecuteTimestamp(),
            frame.turnId(),
            frame.numBuffered()
        );
    }

    function advanceTurnAndFlush(uint8 switchFlag, uint40 timestamp) external {
        PackedHeaderFrameLib.Frame memory frame = PackedHeaderFrameLib.init(battle, config);
        frame.advanceTurn(switchFlag, timestamp);
        frame.flush();
    }

    function dirtyInvalidateReverts() external returns (bool reverted) {
        PackedHeaderFrameLib.Frame memory frame = PackedHeaderFrameLib.init(battle, config);
        frame.write(0, 1);
        try this.invalidate(frame) {} catch {
            reverted = true;
        }
    }

    function invalidate(PackedHeaderFrameLib.Frame memory frame) external pure {
        frame.invalidate();
    }

    function _slot(uint256 wordIndex) private view returns (uint256 slot) {
        uint256 battleSlot;
        uint256 configSlot;
        assembly ("memory-safe") {
            battleSlot := battle.slot
            configSlot := config.slot
        }
        if (wordIndex < 2) return battleSlot + wordIndex;
        if (wordIndex < 8) return configSlot + wordIndex - 2;
        if (wordIndex == 8) return configSlot + 18;
        revert();
    }
}

contract PackedHeaderFrameLibTest is Test {
    PackedHeaderFrameHarness private harness;

    function setUp() public {
        harness = new PackedHeaderFrameHarness();
        for (uint256 word; word < 9; word++) {
            harness.setRaw(word, 1000 + word);
        }
    }

    function test_lazyReadLoadsWordOnce() public view {
        (uint256 first, uint256 second, uint16 loadedMask, uint16 dirtyMask) = harness.probeTwice(5);
        assertEq(first, 1005);
        assertEq(second, 1005);
        assertEq(loadedMask, uint16(1 << 5));
        assertEq(dirtyMask, 0);
    }

    function test_fullWordWriteDoesNotRequirePriorReadAndFlushesOnlyDirtyWord() public {
        (uint16 loaded, uint16 dirtyBefore, uint16 dirtyAfter) = harness.writeAndFlush(8, 7777);
        assertEq(loaded, uint16(1 << 8));
        assertEq(dirtyBefore, uint16(1 << 8));
        assertEq(dirtyAfter, 0);
        assertEq(harness.getRaw(8), 7777);
        for (uint256 word; word < 8; word++) {
            assertEq(harness.getRaw(word), 1000 + word);
        }
    }

    function test_dirtyFrameCannotInvalidateWithoutFlush() public {
        assertTrue(harness.dirtyInvalidateReverts());
    }

    function test_wordBounds() public {
        vm.expectRevert(PackedHeaderFrameLib.HeaderWordOutOfBounds.selector);
        harness.probeTwice(9);
    }

    function test_battleStateTypedAccessorsMatchStoragePacking() public {
        address p0 = address(0x1234567890123456789012345678901234567890);
        address p1 = address(0xABcdEFABcdEFabcdEfAbCdefabcdeFABcDEFabCD);
        uint256 staticWord = uint256(uint160(p1)) | (uint256(9) << 160) | (uint256(11) << 176);
        uint256 stateWord = uint256(uint160(p0)) | (uint256(2) << 160) | (uint256(1) << 168)
            | (uint256(0x0703) << 176) | (uint256(123456) << 192) | (uint256(41) << 232)
            | (uint256(6) << 248);
        harness.setRaw(0, staticWord);
        harness.setRaw(1, stateWord);

        (
            address gotP0,
            address gotP1,
            uint8 winner,
            uint8 switchFlag,
            uint16 active,
            uint40 timestamp,
            uint16 turn,
            uint8 buffered
        ) = harness.readBattleState();
        assertEq(gotP0, p0);
        assertEq(gotP1, p1);
        assertEq(winner, 2);
        assertEq(switchFlag, 1);
        assertEq(active, 0x0703);
        assertEq(timestamp, 123456);
        assertEq(turn, 41);
        assertEq(buffered, 6);
    }

    function test_advanceTurnPreservesUnrelatedPackedFields() public {
        uint256 original = uint256(uint160(address(0x1234))) | (uint256(2) << 160) | (uint256(1) << 168)
            | (uint256(0x0703) << 176) | (uint256(99) << 192) | (uint256(41) << 232)
            | (uint256(6) << 248);
        harness.setRaw(1, original);
        harness.advanceTurnAndFlush(2, 777);

        uint256 expected = uint256(uint160(address(0x1234))) | (uint256(2) << 160) | (uint256(2) << 168)
            | (uint256(0x0703) << 176) | (uint256(777) << 192) | (uint256(42) << 232)
            | (uint256(6) << 248);
        assertEq(harness.getRaw(1), expected);
    }
}
