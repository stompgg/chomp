# Solidity to TypeScript Transpiler
# AUTHORED BY CLAUDE

A transpiler that converts Solidity contracts to TypeScript for local battle simulation in the Chomp game engine.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Module Structure](#module-structure)
3. [How the Transpiler Works](#how-the-transpiler-works)
4. [Metadata and Dependency Injection](#metadata-and-dependency-injection)
5. [Adding New Solidity Files](#adding-new-solidity-files)
6. [Contract Address System](#contract-address-system)
7. [Supported Features](#supported-features)
8. [Known Limitations](#known-limitations)
9. [Future Work](#future-work)
10. [Testing](#testing)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Transpilation Pipeline                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  src/*.sol ──► sol2ts.py ──► ts-output/*.ts ──► Battle Simulation           │
│                    │                                                         │
│                    └──► factories.ts (with --emit-metadata)                  │
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
│  │  runtime/       │     │   Structs.ts    │     │    Enums.ts     │        │
│  │ (Contract base, │     │ (Mon, Battle,   │     │ (Type, MoveClass│        │
│  │  Storage, Utils,│     │  MonStats, etc) │     │  EffectStep)    │        │
│  │  ContractCont.) │     └─────────────────┘     └─────────────────┘        │
│  └─────────────────┘                                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### What the Transpiler Does

- **Preserves Solidity semantics**: Transpiled TypeScript behaves like the Solidity source
- **Uses BigInt for all integers**: Solidity's 256-bit integers map to JavaScript BigInt
- **Uses object references for contracts**: Contracts use object references with `_contractAddress` for addresses
- **Simulates storage**: The `Storage` class simulates Solidity's storage model
- **Provides dependency injection**: The `ContractContainer` handles automatic dependency resolution
- **Provides a shared event log**: The `EventStream` captures emitted events

### What the Transpiler Does Not Do

- **No EVM execution**: Source-to-source transpilation, not bytecode interpretation
- **No gas simulation**: Gas costs are not tracked
- **No storage layout guarantees**: Storage slots don't match on-chain layout
- **No modifier inlining**: Modifiers are stripped (use runtime replacements)
- **Limited assembly/Yul support**: Inline assembly blocks use the YulTranspiler for basic cases

---

## Module Structure

The transpiler is organized into focused modules:

```
transpiler/
├── sol2ts.py              # Main entry point (SolidityToTypeScriptTranspiler)
├── __init__.py            # Package exports
│
├── lexer/                 # Tokenization
│   ├── tokens.py          # Token types and Token class
│   └── lexer.py           # Lexer implementation
│
├── parser/                # AST construction
│   ├── ast_nodes.py       # AST node definitions
│   └── parser.py          # Recursive descent parser
│
├── type_system/           # Type registry (named to avoid shadowing Python's types)
│   ├── registry.py        # TypeRegistry for cross-file type discovery
│   └── mappings.py        # Type conversion utilities
│
├── codegen/               # Code generation (modular)
│   ├── generator.py       # TypeScriptCodeGenerator (orchestrator)
│   ├── context.py         # CodeGenerationContext (shared state)
│   ├── base.py            # BaseGenerator (shared utilities)
│   ├── type_converter.py  # TypeConverter (Solidity → TypeScript types)
│   ├── expression.py      # ExpressionGenerator
│   ├── statement.py       # StatementGenerator
│   ├── function.py        # FunctionGenerator
│   ├── definition.py      # DefinitionGenerator (structs, enums)
│   ├── imports.py         # ImportGenerator
│   ├── contract.py        # ContractGenerator
│   ├── yul.py             # YulTranspiler (inline assembly)
│   ├── abi.py             # AbiTypeInferer (abi.encode type inference)
│   └── metadata.py        # MetadataExtractor, FactoryGenerator
│
├── runtime/               # TypeScript runtime library
│   ├── index.ts           # Contract, Storage, ContractContainer, utils
│   ├── base.ts            # Minimal Contract for runtime replacements
│   ├── battle-harness.ts  # BattleHarness for testing
│   ├── ECDSA.ts           # Runtime replacement for lib/ECDSA.sol
│   ├── EIP712.ts          # Runtime replacement for lib/EIP712.sol
│   ├── Ownable.ts         # Runtime replacement for lib/Ownable.sol
│   └── EnumerableSetLib.ts
│
├── test/                  # TypeScript tests
│   ├── integration.test.ts
│   ├── mutators.test.ts
│   └── transpiler-test-cases.test.ts
│
└── runtime-replacements.json  # Config for Solidity files with runtime implementations
```

### Code Generator Architecture

The `TypeScriptCodeGenerator` orchestrates specialized generators:

| Generator | Responsibility |
|-----------|---------------|
| `TypeConverter` | Solidity → TypeScript type conversions |
| `ExpressionGenerator` | Literals, operators, function calls, member access |
| `StatementGenerator` | Blocks, loops, conditionals, variable declarations |
| `FunctionGenerator` | Functions, constructors, return types |
| `DefinitionGenerator` | Structs, enums, constants |
| `ImportGenerator` | Import statements, relative paths |
| `ContractGenerator` | Contract classes, inheritance, state variables |
| `YulTranspiler` | Inline assembly (basic support) |
| `AbiTypeInferer` | Type inference for abi.encode/decode |

---

## How the Transpiler Works

### Phases

1. **Type Discovery**: Scan source to discover enums, structs, constants, contracts
2. **Lexing**: Tokenize Solidity source
3. **Parsing**: Build AST from tokens
4. **Code Generation**: Traverse AST and emit TypeScript via specialized generators
5. **Import Resolution**: Generate imports based on discovered types
6. **Metadata Extraction** (optional): Extract dependencies for factory generation

### Runtime Replacements

Files with complex Yul/assembly are handled via `runtime-replacements.json`:

```json
{
  "replacements": [
    {
      "source": "lib/ECDSA.sol",
      "runtimeModule": "../runtime",
      "exports": ["ECDSA"],
      "reason": "Complex Yul assembly for ECDSA signature recovery"
    }
  ]
}
```

To add a new runtime replacement:
1. Create TypeScript implementation in `runtime/`
2. Add entry to `runtime-replacements.json`
3. Export from `runtime/index.ts`

---

## Metadata and Dependency Injection

```bash
# Emit factories.ts alongside TypeScript
python3 sol2ts.py src/ -o ts-output -d src --emit-metadata

# Only emit metadata
python3 sol2ts.py src/ --metadata-only -d src
```

The `--emit-metadata` flag generates `factories.ts` with:
- Interface aliases (e.g., `IEngine` → `Engine`)
- Lazy singleton registrations with constructor dependencies
- Factory functions for dependency injection

### Using the Container

```typescript
import { ContractContainer } from './runtime';
import { setupContainer } from './factories';

const container = new ContractContainer();
setupContainer(container);

// Resolve with automatic dependency injection
const move = container.resolve<UnboundedStrike>('UnboundedStrike');
```

---

## Adding New Solidity Files

```bash
# Single file
python3 transpiler/sol2ts.py src/moves/CoolMove.sol -o transpiler/ts-output -d src

# Entire directory with metadata
python3 transpiler/sol2ts.py src/ -o transpiler/ts-output -d src --emit-metadata
```

### Common Transpilation Patterns

| Solidity | TypeScript |
|----------|------------|
| `uint256 x = 5;` | `let x: bigint = 5n;` |
| `mapping(address => uint)` | `Record<string, bigint>` |
| `IEffect(address(this))` | `this` (object reference) |
| `address(this)` | `this._contractAddress` |
| `keccak256(abi.encode(...))` | `keccak256(encodeAbiParameters(...))` |
| `msg.sender` | `this._msg.sender` |

---

## Contract Address System

```typescript
import { contractAddresses } from './runtime';

contractAddresses.setAddresses({
  'Engine': '0xaaaa...',
  'StatBoosts': '0xbbbb...',
});

// Or pass to constructor
const myContract = new MyContract('0xcccc...');
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

### Solidity-Specific
- `abi.encode`, `abi.encodePacked`, `abi.decode` (via viem)
- `keccak256`, `sha256`
- `type(uint256).max`, `type(int256).min`
- `msg.sender`, `block.timestamp`, `tx.origin`

---

## Known Limitations

### Parser Limitations

| Feature | Status | Workaround |
|---------|--------|------------|
| Function pointers | Not supported | Refactor to use interfaces |
| Complex Yul/assembly | Basic support | Use runtime replacements |
| Modifiers | Stripped | Inline logic or use mixins |
| try/catch | Skipped | Wrap in regular conditionals |
| User-defined operators | Not supported | Use regular functions |

### Semantic Differences

| Solidity Behavior | TypeScript Behavior | Impact |
|-------------------|---------------------|--------|
| Storage references auto-persist | Object references don't auto-persist | Fixed with `??=` pattern |
| Mapping returns zero-initialized | Record returns `undefined` | Fixed with factory functions |
| `Array.push()` returns new length | Returns `undefined` | Minor - rarely used return |
| `delete array[i]` zeros element | Removes element | Use `arr[i] = 0n` instead |
| Integer overflow wraps | BigInt grows unbounded | Add masking if needed |

### Files Requiring Runtime Replacements

| File | Reason |
|------|--------|
| `lib/ECDSA.sol` | Yul assembly for signature recovery |
| `lib/EIP712.sol` | Complex typed data hashing |
| `lib/Ownable.sol` | Used as mixin for multiple inheritance |
| `lib/Multicall3.sol` | Not parseable (Yul) |
| `lib/CreateX.sol` | Not parseable (Yul) |

---

## Future Work

### High Priority

- [ ] **Modifier support**: Parse and inline modifier logic automatically
- [ ] **Improved storage semantics**: Better handling of storage vs memory references
- [ ] **Nested struct initialization**: Handle deeply nested structs in mappings

### Medium Priority

- [ ] **Watch mode**: Auto-re-transpile on file changes
- [ ] **Source maps**: Map TypeScript lines back to Solidity for debugging
- [ ] **Better error messages**: Show Solidity line numbers in transpilation errors
- [ ] **Incremental compilation**: Only re-transpile changed files

### Low Priority

- [ ] **Enhanced metadata**: Extract `moveType()`, `moveClass()`, `priority()` return values
- [ ] **Gas estimation stubs**: Add placeholder gas tracking for testing
- [ ] **Storage layout matching**: Match on-chain storage slot assignments

### Known Issues to Address

- [ ] Some edge cases with `abi.decode` type inference
- [ ] Complex inheritance chains may need manual fixes
- [ ] Some viem type casts may need adjustment for newer versions

---

## Testing

```bash
cd transpiler
npm install
npm run test:vitest
```

### Test Suites

| Suite | Description | Count |
|-------|-------------|-------|
| `transpiler-test-cases.test.ts` | Module imports, type conversions | 20 tests |
| `integration.test.ts` | Engine behavior with mocks | 13 tests |
| `mutators.test.ts` | Mutator method behavior | 7 tests |

### Running Tests

```bash
npx vitest run                              # Run all tests
npx vitest                                  # Watch mode
npx vitest run test/integration.test.ts    # Specific file
```

### Python Unit Tests

```bash
cd /path/to/project
python3 transpiler/test_transpiler.py
```

Tests ABI type inference for function return types and contract type imports.

**Current Status**: 40 TypeScript tests passing, 8 Python unit tests passing.

---

## CLI Reference

```bash
# Transpile single file
python3 transpiler/sol2ts.py src/path/to/File.sol -o transpiler/ts-output -d src

# Transpile directory with factories.ts
python3 transpiler/sol2ts.py src/ -o transpiler/ts-output -d src --emit-metadata

# Metadata only
python3 transpiler/sol2ts.py src/ --metadata-only -d src

# Print to stdout (debugging)
python3 transpiler/sol2ts.py src/path/to/File.sol --stdout -d src
```
