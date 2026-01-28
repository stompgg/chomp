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
- **No assembly/Yul support**: Inline assembly blocks are skipped with warnings.

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

Tests cover: battle key computation, turn order, multi-turn battles, storage operations, status effects, forced switches, abilities, and engine state management.

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
