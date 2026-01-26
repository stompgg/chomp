# Solidity to TypeScript Transpiler

A transpiler that converts Solidity contracts to TypeScript for local battle simulation in the Chomp game engine.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [How the Transpiler Works](#how-the-transpiler-works)
3. [Adding New Solidity Files](#adding-new-solidity-files)
4. [Angular Integration](#angular-integration)
5. [Contract Address System](#contract-address-system)
6. [Supported Features](#supported-features)
7. [Known Limitations](#known-limitations)
8. [Future Work](#future-work)
9. [Test Coverage](#test-coverage)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Transpilation Pipeline                          │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  src/*.sol ──► sol2ts.py ──► ts-output/*.ts ──► Angular Battle Service │
│                                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────────────┐  │
│  │ Solidity │───►│  Lexer   │───►│  Parser  │───►│ Code Generator   │  │
│  │  Source  │    │ (Tokens) │    │  (AST)   │    │ (TypeScript)     │  │
│  └──────────┘    └──────────┘    └──────────┘    └──────────────────┘  │
│                                                                         │
│  Type Discovery: Scans src/ to build enum, struct, constant registries │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                         Runtime Architecture                            │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐   │
│  │   Engine.ts     │────►│   Effects       │────►│   Moves         │   │
│  │  (Battle Core)  │     │ (StatBoosts,    │     │ (StandardAttack │   │
│  │                 │     │  StatusEffects) │     │  + custom)      │   │
│  └────────┬────────┘     └─────────────────┘     └─────────────────┘   │
│           │                                                             │
│           ▼                                                             │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐   │
│  │  runtime.ts     │     │   Structs.ts    │     │    Enums.ts     │   │
│  │ (Contract base, │     │ (Mon, Battle,   │     │ (Type, MoveClass│   │
│  │  Storage, Utils)│     │  MonStats, etc) │     │  EffectStep)    │   │
│  └─────────────────┘     └─────────────────┘     └─────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Design Principles

1. **Correct Transpilation Over Metadata**: The transpiled TypeScript behaves exactly like the Solidity source. Functions with conditional returns transpile to equivalent TypeScript conditionals - no metadata or heuristics needed.

2. **BigInt for All Integers**: Solidity's 256-bit integers map to JavaScript BigInt to maintain precision.

3. **Object References for Contracts**: In Solidity, contracts are identified by addresses. In TypeScript, we use object references directly for most operations, with `_contractAddress` available when actual addresses are needed.

4. **Storage Simulation**: The `Storage` class simulates Solidity's storage model with slot-based access.

---

## How the Transpiler Works

### Phase 1: Type Discovery

Before transpiling any file, the transpiler scans the source directory to discover:

- **Enums**: Collected into `Enums.ts` with numeric values
- **Structs**: Collected into `Structs.ts` as TypeScript interfaces
- **Constants**: Collected into `Constants.ts`
- **Contract/Library Names**: Used for import resolution

```bash
python3 transpiler/sol2ts.py src/moves/MyMove.sol -o transpiler/ts-output -d src
#                                                                         ^^^^^^
#                                                   Discovery directory for types
```

### Phase 2: Lexing

The lexer tokenizes Solidity source into tokens:

```
contract Foo { ... }  →  [CONTRACT, IDENTIFIER("Foo"), LBRACE, ..., RBRACE]
```

### Phase 3: Parsing

The parser builds an AST (Abstract Syntax Tree):

```
ContractDefinition
├── name: "Foo"
├── base_contracts: ["Bar", "IBaz"]
├── state_variables: [...]
├── functions: [...]
└── ...
```

### Phase 4: Code Generation

The generator traverses the AST and emits TypeScript:

```typescript
export class Foo extends Bar {
  // state variables become properties
  readonly ENGINE: any;

  // functions become methods
  move(battleKey: string, ...): bigint {
    // Solidity logic preserved exactly
  }
}
```

### Phase 5: Import Resolution

Based on discovered types, generates appropriate imports:

```typescript
import { Contract, Storage, ADDRESS_ZERO, addressToUint } from './runtime';
import { BasicEffect } from './BasicEffect';
import * as Structs from './Structs';
import * as Enums from './Enums';
import * as Constants from './Constants';
```

---

## Adding New Solidity Files

### Step 1: Write the Solidity Contract

```solidity
// src/moves/mymove/CoolMove.sol
pragma solidity ^0.8.0;

import {IMoveSet} from "../../interfaces/IMoveSet.sol";
import {IEngine} from "../../interfaces/IEngine.sol";

contract CoolMove is IMoveSet {
    IEngine public immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function move(bytes32 battleKey, ...) external returns (uint256 damage) {
        // Your move logic
    }
}
```

### Step 2: Transpile

```bash
cd /path/to/chomp

# Transpile a single file
python3 transpiler/sol2ts.py src/moves/mymove/CoolMove.sol \
    -o transpiler/ts-output \
    -d src

# Or transpile an entire directory
python3 transpiler/sol2ts.py src/moves/mymove/ \
    -o transpiler/ts-output \
    -d src
```

### Step 3: Review the Output

Check `transpiler/ts-output/CoolMove.ts` for:

1. **Correct imports**: All dependencies should be imported
2. **Proper inheritance**: `extends` the right base class
3. **BigInt usage**: All numbers should be `bigint`
4. **Logic preservation**: Conditionals, loops, returns match the Solidity

### Step 4: Handle Dependencies

If your move uses other contracts (e.g., StatBoosts), you'll need to inject them:

```typescript
// In your test or Angular service
const statBoosts = new StatBoosts(engine);
const coolMove = new CoolMove(engine);
(coolMove as any).STAT_BOOSTS = statBoosts; // Inject dependency
```

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

## Angular Integration

### Setting Up the Battle Service

The `BattleService` in Angular dynamically imports transpiled modules and sets up the simulation:

```typescript
// client/lib/battle.service.ts

@Injectable({ providedIn: 'root' })
export class BattleService {
  private localEngine: any;
  private localTypeCalculator: any;

  async initializeLocalSimulation(): Promise<void> {
    // Dynamic imports from transpiler output
    const [
      { Engine },
      { TypeCalculator },
      { StandardAttack },
      Structs,
      Enums,
      Constants,
    ] = await Promise.all([
      import('../../transpiler/ts-output/Engine'),
      import('../../transpiler/ts-output/TypeCalculator'),
      import('../../transpiler/ts-output/StandardAttack'),
      import('../../transpiler/ts-output/Structs'),
      import('../../transpiler/ts-output/Enums'),
      import('../../transpiler/ts-output/Constants'),
    ]);

    // Create engine instance
    this.localEngine = new Engine();
    this.localTypeCalculator = new TypeCalculator();

    // Initialize battle state storage
    (this.localEngine as any).battleConfig = {};
    (this.localEngine as any).battleData = {};
  }
}
```

### Configuring Contract Addresses

If you need specific addresses for contracts (e.g., for on-chain verification):

```typescript
import { contractAddresses } from '../../transpiler/ts-output/runtime';

// Before creating contract instances
contractAddresses.setAddresses({
  'StatBoosts': '0x1234567890abcdef...',
  'BurnStatus': '0xfedcba0987654321...',
  'Engine': '0xabcdef1234567890...',
});

// Now created instances will use these addresses
const engine = new Engine(); // engine._contractAddress === '0xabcdef...'
```

### Running a Local Battle Simulation

```typescript
async simulateBattle(team1: Mon[], team2: Mon[]): Promise<BattleResult> {
  await this.initializeLocalSimulation();

  // Set up battle configuration
  const battleKey = this.localEngine.computeBattleKey(
    player1Address,
    player2Address
  );

  // Initialize teams
  this.localEngine.initializeBattle(battleKey, {
    p0Team: team1,
    p1Team: team2,
    // ... other config
  });

  // Execute moves
  const damage = move.move(
    battleKey,
    attackerIndex,
    defenderIndex,
    // ... other params
  );

  return { damage, /* ... */ };
}
```

### Handling Effects and Abilities

Effects need to be registered and can be looked up by address:

```typescript
import { registry } from '../../transpiler/ts-output/runtime';

// Register effects
const burnStatus = new BurnStatus(engine);
const statBoosts = new StatBoosts(engine);

registry.registerEffect(burnStatus._contractAddress, burnStatus);
registry.registerEffect(statBoosts._contractAddress, statBoosts);

// Later, look up by address
const effect = registry.getEffect(someAddress);
```

---

## Contract Address System

The transpiler includes a contract address system for cases where actual addresses are needed:

### How It Works

1. **Every contract has `_contractAddress`**: Auto-generated based on class name or configured via registry

2. **`address(this)` transpiles to `this._contractAddress`**: Used for encoding, hashing, storage keys

3. **`IEffect(address(this))` transpiles to `this`**: Used when passing object references

4. **`addressToUint(addr)` converts addresses to BigInt**: For `uint160(address(x))` patterns

### Configuration Options

```typescript
import { contractAddresses } from './runtime';

// Option 1: Set address for a class name (all instances share this address)
contractAddresses.setAddress('MyContract', '0x1234...');

// Option 2: Set multiple at once
contractAddresses.setAddresses({
  'Engine': '0xaaaa...',
  'StatBoosts': '0xbbbb...',
});

// Option 3: Pass address to constructor
const myContract = new MyContract('0xcccc...');

// Option 4: Use auto-generated deterministic address (default)
const myContract = new MyContract(); // Address derived from class name
```

---

## Supported Features

### Core Language
- ✅ Contracts, Libraries, Interfaces (with inheritance)
- ✅ State variables (instance and static)
- ✅ Functions with visibility modifiers
- ✅ Constructors with base class argument passing
- ✅ Enums and Structs
- ✅ Events (via EventStream)

### Types
- ✅ Integer types (`uint8` - `uint256`, `int8` - `int256`) → `bigint`
- ✅ `address` → `string`
- ✅ `bytes`, `bytes32` → `string` (hex)
- ✅ `bool`, `string` → direct mapping
- ✅ Arrays (fixed and dynamic)
- ✅ Mappings → `Record<string, T>`

### Expressions
- ✅ All arithmetic, bitwise, logical operators
- ✅ Ternary operator
- ✅ Type casts with proper bit masking
- ✅ Struct literals with named arguments
- ✅ Array/mapping indexing
- ✅ Tuple destructuring

### Solidity-Specific
- ✅ `abi.encode`, `abi.encodePacked`, `abi.decode` (via viem)
- ✅ `keccak256`, `sha256`
- ✅ `type(uint256).max`, `type(int256).min`
- ✅ `msg.sender`, `block.timestamp`, `tx.origin`

---

## Known Limitations

### Parser Limitations

| Issue | Workaround |
|-------|------------|
| Function pointers | Not supported - restructure code |
| Complex Yul/assembly | Skipped with warnings - implement in runtime |
| Modifiers | Stripped - inline logic manually if needed |
| try/catch | Skipped - error handling not simulated |

### Runtime Differences

| Issue | Description |
|-------|-------------|
| Integer division | BigInt truncates toward zero (same as Solidity) |
| Storage vs memory | All TS objects are references - aliasing may differ |
| Array.push() return | Solidity returns new length, TS doesn't |
| delete array[i] | Solidity zeros element, TS removes it |

### Dependency Injection

Contracts that reference other contracts need manual injection:

```typescript
// Solidity: STAT_BOOSTS is set via constructor or immutable
// TypeScript: May need manual assignment
(myMove as any).STAT_BOOSTS = statBoostsInstance;
```

---

## Future Work

### High Priority

1. **Cross-Contract Dependency Detection**
   - Auto-detect when a contract uses another contract (e.g., StatBoosts)
   - Generate constructor parameters or injection helpers

2. **Modifier Support**
   - Parse and inline modifier logic into functions
   - Currently modifiers are stripped

3. **Better Type Inference for abi.encode**
   - Detect return types of function calls used as arguments
   - Currently assumes uint256 for non-literal arguments

### Medium Priority

4. **Watch Mode**
   - Auto-re-transpile when Solidity files change
   - Integration with build pipelines

5. **Source Maps**
   - Map TypeScript lines back to Solidity for debugging

6. **Function Overloading**
   - Handle multiple functions with same name but different signatures

### Low Priority

7. **VSCode Extension**
   - Inline preview of transpiled output
   - Error highlighting for unsupported patterns

8. **Fixed-Point Math**
   - Support `ufixed` and `fixed` types

---

## Test Coverage

### Unit Tests (`test/run.ts`)

```bash
cd transpiler && npm test
```

- Battle key computation
- Turn order by speed
- Multi-turn battles until KO
- Storage read/write operations

### E2E Tests (`test/e2e.ts`)

- **Status Effects**: ZapStatus (skip turn), BurnStatus (DoT)
- **Forced Switches**: HitAndDip (user), PistolSquat (opponent)
- **Abilities**: UpOnly (attack boost on damage)
- **Complex Interactions**: Multi-turn battles with effect stacking

### Engine Tests (`test/engine-e2e.ts`)

- Core engine instantiation and methods
- Matchmaker authorization
- Battle state management
- Damage dealing and KO detection
- Global KV storage operations
- Event emission and retrieval

### Battle Simulation Tests (`test/battle-simulation.ts`)

- Dynamic move properties (UnboundedStrike with Baselight stacks)
- Conditional power calculations (DeepFreeze with Frostbite)
- Self-damage mechanics (RockPull)
- RNG-based power (Gachachacha)

### Tests to Add

- [ ] Negative number handling (signed integers)
- [ ] Overflow behavior verification
- [ ] Complex nested struct construction
- [ ] Multi-level inheritance (3+ levels)
- [ ] Effect removal during iteration
- [ ] Concurrent effect modifications
- [ ] Multiple status effects on same mon
- [ ] Priority modification mechanics
- [ ] Accuracy modifier mechanics

---

## Quick Reference

### CLI Usage

```bash
# Single file
python3 transpiler/sol2ts.py src/path/to/File.sol -o transpiler/ts-output -d src

# Directory
python3 transpiler/sol2ts.py src/moves/ -o transpiler/ts-output -d src

# Print to stdout (for debugging)
python3 transpiler/sol2ts.py src/path/to/File.sol --stdout -d src

# Generate stub for a contract
python3 transpiler/sol2ts.py src/path/to/File.sol -o transpiler/ts-output -d src --stub ContractName
```

### Running Tests

```bash
cd transpiler
npm install
npm test
```

### File Structure

```
transpiler/
├── sol2ts.py           # Main transpiler script
├── runtime/
│   └── index.ts        # Runtime library source (copy to ts-output as needed)
├── ts-output/          # Generated TypeScript files
│   ├── runtime.ts      # Runtime library
│   ├── Structs.ts      # All struct definitions
│   ├── Enums.ts        # All enum definitions
│   ├── Constants.ts    # All constants
│   ├── Engine.ts       # Battle engine
│   └── *.ts            # Transpiled contracts
├── test/
│   ├── run.ts          # Test runner
│   ├── e2e.ts          # End-to-end tests
│   ├── engine-e2e.ts   # Engine-specific tests
│   └── battle-simulation.ts  # Battle scenario tests
└── package.json
```
