# Phase 2C: Fixed-Size Moves Array — Changes Summary

## Overview
Converted `IMoveSet[] moves` to `IMoveSet[4] moves` in the `Mon` struct. This eliminates dynamic array storage overhead (1 length slot + pointer indirection per Mon) across all battle storage operations.

**Gas savings:** For a 6v6 battle (12 Mons), this eliminates ~24 storage slots of overhead on first battle start (2 slots per Mon: length + array pointer).

## Files Changed

### Core Struct
- **`src/Structs.sol`** — `IMoveSet[] moves` → `IMoveSet[4] moves`

### Source Files (5 files)
- **`src/DefaultValidator.sol`** — Removed `moves.length != MOVES_PER_MON` check (fixed array is always 4; MOVES_PER_MON still controls valid move indices at runtime via `moveIndex >= MOVES_PER_MON`)
- **`src/teams/DefaultTeamRegistry.sol`** — Changed `createTeam` and `updateTeam` signatures from `IMoveSet[][] memory` to `IMoveSet[4][] memory`; updated move validation to skip `address(0)` slots
- **`src/teams/DefaultMonRegistry.sol`** — Updated `validateMon` to skip `address(0)` move entries when validating
- **`src/teams/LookupTeamRegistry.sol`** — Changed local move arrays from `IMoveSet[] memory` to `IMoveSet[4] memory`
- **`src/cpu/CPU.sol`** — Added `address(0)` check in `calculateValidMoves` to skip empty move slots

### Test Files (26 files)
All test files updated to use `IMoveSet[4]` for Mon move arrays:
- `test/abstract/BattleHelper.sol` — `_createMon()` returns Mon with zero-filled fixed array
- `test/EngineTest.sol` — ~60 instances of `IMoveSet[] memory` → `IMoveSet[4] memory`
- `test/CPUTest.sol` — Move arrays and `_createMon` patterns
- `test/EngineGasTest.sol` — Move arrays and struct literals
- `test/TeamsTest.sol` — `IMoveSet[][]` → `IMoveSet[4][]` for team creation
- `test/GachaTeamRegistryTest.sol` — Fixed team move reading
- Plus 20 more test files (effects, mons, moves, etc.)

### Special Test Adjustment
- **`test/mons/EmbursaTest.sol`** — Originally used 5 moves per Mon; reduced to 4 (max capacity of fixed array). Bob's KO move moved from index 4 to index 3, MOVES_PER_MON changed from 5 to 4.

## Key Design Decisions

1. **Unused move slots are `IMoveSet(address(0))`** — Mons with <4 moves have zeroed slots. All code that iterates moves checks for `address(0)` before calling.

2. **Validator check removed** — The old `moves.length != MOVES_PER_MON` is meaningless with fixed arrays (always 4). MOVES_PER_MON still gates move index selection via `moveIndex >= MOVES_PER_MON` in `validatePlayerMove`.

3. **Registry functions preserved** — `DefaultMonRegistry.createMon()` and `modifyMon()` still take `IMoveSet[] memory` for allowed moves lists (these are NOT Mon.moves, they're the registry's allowed-move sets).

4. **CPU address(0) guard** — CPU move enumeration now skips `address(0)` move slots to prevent reverts when calling interface methods on zero address.

## Verification
```
forge build: ✅ Compiles with 0 errors
forge test: ✅ 222 tests pass, 0 fail
```
