# Solidity to TypeScript Transpiler

A transpiler that converts Solidity contracts to TypeScript for local battle simulation in the Chomp game engine.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [How the Transpiler Works](#how-the-transpiler-works)
3. [Metadata and Dependency Injection](#metadata-and-dependency-injection)
4. [Adding New Solidity Files](#adding-new-solidity-files)
5. [Contract Address System](#contract-address-system)
6. [Supported Features](#supported-features)
7. [Known Limitations](#known-limitations)
8. [Future Work](#future-work)
9. [Testing](#testing)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Transpilation Pipeline                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  src/*.sol ──► sol2ts.py ──► ts-output/*.ts ──► Battle Simulation           │
│                    │                                                         │
│                    └──► dependency-manifest.json (optional)                  │
│                    └──► factories.ts (optional)                              │
│                                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────────────┐       │
│  │ Solidity │───►│  Lexer   │───►│  Parser  │───►│ Code Generator   │       │
│  │  Source  │    │ (Tokens) │    │  (AST)   │    │ (TypeScript)     │       │
│  └──────────┘    └──────────┘    └──────────┘    └──────────────────┘       │
│                                        │                                     │
│                                        ▼                                     │
│                               ┌──────────────────┐                          │
│                               │ Metadata Extractor│ (--emit-metadata)       │
│                               └──────────────────┘                          │
│                                                                              │
│  Type Discovery: Scans src/ to build enum, struct, constant registries      │
│  Optimizations: Qualified name caching for O(1) type lookups                │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                         Runtime Architecture                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐        │
│  │   Engine.ts     │────►│   Effects       │────►│   Moves         │        │
│  │  (Battle Core)  │     │ (StatBoosts,    │     │ (StandardAttack │        │
│  │                 │     │  StatusEffects) │     │  + custom)      │        │
│  └────────┬────────┘     └─────────────────┘     └─────────────────┘        │
│           │                                                                  │
│           ▼                                                                  │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐        │
│  │  runtime.ts     │     │   Structs.ts    │     │    Enums.ts     │        │
│  │ (Contract base, │     │ (Mon, Battle,   │     │ (Type, MoveClass│        │
│  │  Storage, Utils,│     │  MonStats, etc) │     │  EffectStep)    │        │
│  │  ContractCont.) │     └─────────────────┘     └─────────────────┘        │
│  └─────────────────┘                                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### What the Transpiler Does

- **Preserves Solidity semantics**: Transpiled TypeScript behaves like the Solidity source. Conditional returns, loops, and control flow transpile to equivalent TypeScript.
- **Uses BigInt for all integers**: Solidity's 256-bit integers map to JavaScript BigInt to maintain precision.
- **Uses object references for contracts**: In Solidity, contracts are identified by addresses. In TypeScript, we use object references directly, with `_contractAddress` available when actual addresses are needed.
- **Simulates storage**: The `Storage` class simulates Solidity's storage model with slot-based access.
- **Provides dependency injection**: The `ContractContainer` class handles automatic dependency resolution for contract instantiation.
- **Provides a shared event log**: The `EventStream` class captures events emitted by contracts during execution.

### What the Transpiler Does Not Do

- **No EVM execution**: This is source-to-source transpilation, not EVM bytecode interpretation.
- **No gas simulation**: Gas costs are not tracked or enforced.
- **No storage layout guarantees**: Storage slots are simulated but don't match on-chain layout.
- **No modifier inlining**: Modifiers are stripped; logic must be inlined manually if needed.
- **No assembly/Yul support**: Inline assembly blocks are skipped with warnings. However, a **runtime replacement** system exists for files that require manual TypeScript implementations.

### Runtime Replacements

Some Solidity files contain Yul/assembly that cannot be transpiled. These are handled via `runtime-replacements.json`:

```json
{
  "lib/ECDSA.sol": {
    "replacement": "runtime/ECDSA.ts",
    "reason": "Complex Yul assembly for gas-optimized ECDSA signature recovery"
  }
}
```

When a file matches a replacement entry, the transpiler:
1. Skips transpilation
2. Generates a re-export from the runtime implementation
3. Emits a comment explaining the replacement

To add a new runtime replacement:
1. Create a TypeScript implementation in `runtime/`
2. Add an entry to `runtime-replacements.json`
3. Export the interface from `runtime/index.ts`

---

## How the Transpiler Works

### Phase 1: Type Discovery

Before transpiling any file, the transpiler scans the source directory to discover:

- **Enums**: Collected into `Enums.ts` with numeric values
- **Structs**: Collected into `Structs.ts` as TypeScript interfaces
- **Constants**: Collected into `Constants.ts`
- **Contract/Library Names**: Used for import resolution

The type registry builds a **qualified name cache** for O(1) lookups.

### Phase 2: Lexing

The lexer tokenizes Solidity source into tokens:

```
contract Foo { ... }  →  [CONTRACT, IDENTIFIER("Foo"), LBRACE, ..., RBRACE]
```

### Phase 3: Parsing

The parser builds an AST (Abstract Syntax Tree) representing contracts, functions, state variables, and expressions.

### Phase 4: Code Generation

The generator traverses the AST and emits TypeScript, preserving Solidity logic.

### Phase 5: Import Resolution

Based on discovered types, generates appropriate imports for runtime utilities, other contracts, structs, enums, and constants.

### Phase 6: Metadata Extraction (Optional)

When `--emit-metadata` is specified, the transpiler extracts:

- **Dependencies**: Constructor parameters that are contract/interface types
- **Constants**: Constant values declared in the contract
- **Move Properties**: For contracts implementing `IMoveSet`, extracts name, power, etc.
- **Dependency Graph**: Maps each contract to its required dependencies

---

## Metadata and Dependency Injection

### Generating Metadata

```bash
# Emit metadata alongside TypeScript
python3 sol2ts.py src/ -o ts-output -d src --emit-metadata

# Only emit metadata (skip TypeScript generation)
python3 sol2ts.py src/ --metadata-only -d src
```

This generates:

- **`dependency-manifest.json`**: Contract metadata including dependencies, constants, and move properties
- **`factories.ts`**: Auto-generated factory functions and `setupContainer()` for bulk registration

### Using the Dependency Injection Container

The runtime includes a `ContractContainer` for managing contract instances:

```typescript
import { ContractContainer } from './runtime';

const container = new ContractContainer();

// Register singletons (shared instances)
container.registerSingleton('Engine', new Engine());

// Register factories with dependencies
container.registerFactory(
  'UnboundedStrike',
  ['Engine', 'TypeCalculator', 'Baselight'],
  (engine, typeCalc, baselight) => new UnboundedStrike(engine, typeCalc, baselight)
);

// Resolve with automatic dependency injection
const move = container.resolve<UnboundedStrike>('UnboundedStrike');
```

### Bulk Registration from Manifest

```typescript
import { setupContainer } from './factories';

setupContainer(container);
const move = container.resolve('UnboundedStrike');
```

---

## Adding New Solidity Files

### Step 1: Write the Solidity Contract

Place your contract in the appropriate `src/` subdirectory.

### Step 2: Transpile

```bash
# Single file
python3 transpiler/sol2ts.py src/moves/mymove/CoolMove.sol -o transpiler/ts-output -d src

# With metadata
python3 transpiler/sol2ts.py src/moves/mymove/CoolMove.sol -o transpiler/ts-output -d src --emit-metadata

# Entire directory
python3 transpiler/sol2ts.py src/moves/mymove/ -o transpiler/ts-output -d src --emit-metadata
```

### Step 3: Review the Output

Check the generated `.ts` file for correct imports, inheritance, BigInt usage, and logic preservation.

### Common Transpilation Patterns

| Solidity | TypeScript |
|----------|------------|
| `uint256 x = 5;` | `let x: bigint = BigInt(5);` |
| `mapping(address => uint)` | `Record<string, bigint>` |
| `IEffect(address(this))` | `this` (object reference) |
| `address(this)` | `this._contractAddress` |
| `keccak256(abi.encode(...))` | `keccak256(encodeAbiParameters(...))` |
| `Type.EnumValue` | `Enums.Type.EnumValue` |
| `StructName({...})` | `{ ... } as Structs.StructName` |

---

## Contract Address System

Every transpiled contract has a `_contractAddress` property for cases where actual addresses are needed (encoding, hashing, storage keys).

### Configuration

```typescript
import { contractAddresses } from './runtime';

// Set addresses for contracts
contractAddresses.setAddresses({
  'Engine': '0xaaaa...',
  'StatBoosts': '0xbbbb...',
});

// Or pass to constructor
const myContract = new MyContract('0xcccc...');

// Default: auto-generated deterministic address from class name
```

### Effect Registry

Effects can be registered and looked up by address:

```typescript
import { registry } from './runtime';

registry.registerEffect(burnStatus._contractAddress, burnStatus);
const effect = registry.getEffect(someAddress);
```

---

## Supported Features

### Core Language
- Contracts, Libraries, Interfaces (with inheritance)
- State variables, functions, constructors
- Enums, Structs, Events (via EventStream)

### Types
- Integer types (`uint8` - `uint256`, `int8` - `int256`) → `bigint`
- `address` → `string`, `bytes`/`bytes32` → `string` (hex)
- Arrays (fixed and dynamic), Mappings → `Record<string, T>`

### Expressions
- All arithmetic, bitwise, logical operators
- Ternary operator, type casts with bit masking
- Struct literals, array/mapping indexing, tuple destructuring

### Solidity-Specific
- `abi.encode`, `abi.encodePacked`, `abi.decode` (via viem)
- `keccak256`, `sha256`
- `type(uint256).max`, `type(int256).min`
- `msg.sender`, `block.timestamp`, `tx.origin`

---

## Recent Fixes (January 2026)

The following issues were fixed to improve TypeScript compilation:

### Fixed Issues (Batch 3 - Latest)

15. **Struct Factory Functions for Mapping Access**
    - Solidity mappings return zero-initialized structs on first access; TypeScript returns `undefined`
    - Generate `createDefault*()` factory functions for each struct in `Structs.ts`
    - Example: `this.battleConfig[key] ?? Structs.createDefaultBattleConfig()`
    - Fixes `Cannot read properties of undefined` errors when accessing struct fields

16. **Storage Reference Write-Back Semantics**
    - Solidity storage references automatically persist modifications to the underlying mapping
    - TypeScript's `??` pattern creates a new object not stored in the mapping
    - Changed to `??=` pattern: first initialize the mapping entry, then get a reference
    - Example:
      ```typescript
      this.battleConfig[key] ??= Structs.createDefaultBattleConfig();
      let config: Structs.BattleConfig = this.battleConfig[key];
      // Now modifications to config persist in the mapping
      ```
    - Fixes issues where struct field modifications were not persisted

17. **EIP712 Runtime Module**
    - Added `runtime/EIP712.ts` as runtime replacement for `lib/EIP712.sol`
    - Implements `_hashTypedData()` for typed data hashing
    - Provides EIP712 domain separator functionality

18. **Multiple Inheritance Mixin System**
    - TypeScript doesn't support multiple inheritance (e.g., `class Foo extends Bar, Ownable`)
    - Moved mixin definitions from hard-coded transpiler logic to `runtime-replacements.json`
    - Any runtime replacement can specify a `mixin` field with code to inline
    - Ownable methods (`_initializeOwner`, `onlyOwner` checks) automatically inlined
    - Future multiple inheritance cases handled by JSON config, not transpiler changes

19. **Circular Dependency Resolution**
    - Created `runtime/base.ts` to resolve circular import issues
    - Contract base class, Storage, EventStream separated from `index.ts`
    - Fixes module initialization order problems

20. **Improved ABI Type Inference**
    - Better struct field type inference in `abi.encode` calls
    - TypeCast handling for `address()` and `bytes32()` casts
    - String type inference in `_infer_single_abi_type`
    - Properly infers types from struct member definitions

21. **viem Type Casting for Addresses/Bytes32**
    - Values passed to viem's encoding functions need `` `0x${string}` `` type
    - Added proper casting: `value as \`0x${string}\``
    - Fixes TypeScript type errors with viem parameters

22. **Runtime Contract Properties Made Public**
    - Changed `_msg`, `_block`, `_tx`, `_contractAddress` from protected/readonly to public
    - Enables test code to set caller context (`engine._msg = { sender: addr, ... }`)
    - Required for integration testing without complex mock setups

23. **Comprehensive Integration Test Suite**
    - Added `test/integration.test.ts` with 13 passing tests
    - Mock implementations for: `RNGOracle`, `TeamRegistry`, `Validator`, `Ruleset`, `Matchmaker`
    - Tests cover: battle initialization, stat modifications, status effects, type effectiveness, event emission
    - Removed 6 outdated test files (`battle-simulation.ts`, `e2e.ts`, `engine-e2e.ts`, `harness-test.ts`, `run.ts`, `test-utils.ts`)

24. **Bigint as Record Index Type (TS2538)**
    - JavaScript/TypeScript doesn't allow `bigint` as object index
    - Add `Number()` conversion for numeric mapping keys (uint/int types)
    - Example: `this.monStats[Number(monId)]` instead of `this.monStats[monId]`
    - Fixes `Type 'bigint' cannot be used as an index type` errors

25. **Local Struct Factory Calls**
    - Structs defined locally in a contract should use factory without `Structs.` prefix
    - Check `current_local_structs` before adding prefix
    - Example: `createDefaultBattleSummary()` instead of `Structs.createDefaultBattleSummary()`
    - Fixes `Property 'createDefaultX' does not exist on type 'typeof Structs'` errors

26. **EnumerableSetLib Initialization**
    - `AddressSet` and `Uint256Set` are runtime classes, not structs
    - Use constructor: `new AddressSet()` instead of `Structs.createDefaultAddressSet()`
    - Fixes missing factory function errors for set types

**Current Status**: All 19 TypeScript errors resolved. Zero compilation errors. 31 tests pass.

### Fixed Issues (Batch 2)

7. **Array `.length` to BigInt Conversion (TS2322)**
   - Array `.length` property now wrapped in `BigInt()` when assigned to bigint variables
   - Excludes EnumerableSetLib types (AddressSet, Uint256Set, etc.) which already return bigint
   - Fixed false positives with interface names like `IMoveSet` by being more specific about EnumerableSetLib type checks

8. **`address(uint160(...))` Pattern (TS2339)**
   - Detects when inner expression is a numeric type cast (uint160, uint256, etc.)
   - Converts bigint to hex address string: `` `0x${(expr).toString(16).padStart(40, "0")}` ``
   - Fixes `_contractAddress does not exist on type 'bigint'` errors

9. **Interface Casts with Method Calls (TS2339)**
   - `ICPU(address(this)).calculateMove()` patterns now cast to `any` to allow interface method calls
   - Fixes `'calculateMove' does not exist on type 'CPUMoveManager'` errors

10. **`new string(length)` Pattern (TS2693)**
    - Solidity's `new string(length)` now transpiles to `""` (empty string)
    - Also handles `new bytes(length)` patterns
    - Fixes `'string' only refers to a type, but is being used as a value` errors

11. **`bytes32("STRING")` Conversion (TS2554)**
    - String literals cast to bytes32 are now properly converted to hex encoding
    - Converts string characters to hex, padded to 64 characters (32 bytes)
    - Fixes `Expected 0 arguments, but got 1` errors from `.toString(16)` on strings

12. **Override Modifier on Interface Methods (TS4113)**
    - `get_all_inherited_methods()` now excludes interface methods by default
    - Only adds `override` for methods actually inherited from class hierarchy
    - Fixes `override modifier because it is not declared in the base class` errors

13. **`bytes32` Constants as Hex Strings**
    - `bytes32` state variables with hex literals now generate string values, not BigInt
    - Example: `bytes32 constant HASH = 0x...` → `static readonly HASH: string = "0x..."`

14. **ABI Type Inference for `address()` Casts**
    - `address(this)` in `abi.encode` now infers type as `'address'` not `'uint256'`
    - Handles TypeCast expressions for address, uint, int, bytes32

### Fixed Issues (Batch 1 - Previous)

1. **BigInt/Number Operator Mixing (TS2365)**
   - Array index expressions like `arr[i - 1]` now correctly convert `1` to `1n`
   - Binary operations in array indices are wrapped with `Number()` for proper type conversion

2. **Function Return Type Handling (TS2355)**
   - Virtual functions with no body now add default return statements or throws
   - Named return parameters are properly returned for empty function bodies

3. **Tuple Return Type Handling (TS2322)**
   - Added `_all_paths_return()` to detect when all code paths have explicit returns
   - Prevents adding unreachable implicit returns when if/else branches all return

4. **ECDSA Async/Sync Mismatch**
   - Implemented synchronous `recoverAddressSync()` for simulation compatibility
   - Added ECDSA to runtime replacements system

5. **EnumerableSetLib `.length()` Callable Issue (TS2349)**
   - Converted from interfaces to classes with proper getter methods
   - `set.length()` now transpiles to `set.length` (property access)

6. **ABI encodePacked Type Inference (TS2345)**
   - Added `_infer_packed_abi_types()` for proper viem `encodePacked()` format
   - `abi.encodePacked(name(), x)` now generates `encodePacked(['string', 'uint256'], [...])`

### Resolved Issues (Previously 23 errors → 0 errors)

All previously documented TypeScript compilation errors have been resolved:

- ~~**Missing Module: EIP712**~~ → Fixed: Added `runtime/EIP712.ts` replacement (Issue #17)
- ~~**Multiple Inheritance with Ownable**~~ → Fixed: Mixin system inlines Ownable methods (Issue #18)
- ~~**Struct Field Type Inference**~~ → Fixed: Improved ABI type inference (Issue #20)
- ~~**viem Type Casting**~~ → Fixed: Proper `0x${string}` casting (Issue #21)
- ~~**Record vs Map Return Type**~~ → Fixed: Consistent Record type usage

**Current Status**: All transpiled TypeScript files compile without errors. Integration tests pass.

---

## Known Limitations

### Parser Limitations

| Feature | Status |
|---------|--------|
| Function pointers | Not supported |
| Complex Yul/assembly | Skipped with warnings |
| Modifiers | Stripped (inline manually) |
| try/catch | Skipped |

### Runtime Differences

| Behavior | Note |
|----------|------|
| Storage vs memory | All TS objects are references; aliasing may differ |
| `Array.push()` return | Solidity returns new length, TS doesn't |
| `delete array[i]` | Solidity zeros element, TS removes it |
| Circular dependencies | Detected and throw errors |

---

## Future Work

- **Modifier support**: Parse and inline modifier logic
- **Watch mode**: Auto-re-transpile on file changes
- **Source maps**: Map TypeScript lines back to Solidity for debugging
- **Enhanced metadata**: Extract `moveType()`, `moveClass()`, `priority()` return values

---

## Testing

```bash
cd transpiler

# Python unit tests (ABI encoding, imports)
python3 test_transpiler.py

# TypeScript runtime tests
npm install
npm test
```

### Test Suites

1. **Integration Tests** (`test/integration.test.ts`)
   - 13 tests covering actual Engine behavior with mocks
   - Tests: battle initialization, stat modifications, status effects, type effectiveness, event emission
   - Uses mock implementations for external dependencies

2. **Transpiler Test Cases** (`test/transpiler-test-cases.test.ts`)
   - Unit tests for transpiler edge cases
   - Tests: ABI encoding, type inference, struct initialization

### Running Tests

```bash
# Run all tests
npx vitest run

# Run with watch mode
npx vitest

# Run specific test file
npx vitest run test/integration.test.ts
```

---

## CLI Reference

```bash
# Transpile single file
python3 transpiler/sol2ts.py src/path/to/File.sol -o transpiler/ts-output -d src

# Transpile directory with metadata
python3 transpiler/sol2ts.py src/moves/ -o transpiler/ts-output -d src --emit-metadata

# Metadata only
python3 transpiler/sol2ts.py src/moves/ --metadata-only -d src

# Print to stdout (debugging)
python3 transpiler/sol2ts.py src/path/to/File.sol --stdout -d src
```
