# Solidity to TypeScript Transpiler

A transpiler that converts Solidity contracts to TypeScript for local battle simulation in the Chomp game engine.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [How the Transpiler Works](#how-the-transpiler-works)
3. [Metadata and Dependency Injection](#metadata-and-dependency-injection)
4. [Battle Simulation Harness](#battle-simulation-harness)
5. [Adding New Solidity Files](#adding-new-solidity-files)
6. [Angular Integration](#angular-integration)
7. [Contract Address System](#contract-address-system)
8. [Supported Features](#supported-features)
9. [Known Limitations](#known-limitations)
10. [Future Work](#future-work)
11. [Test Coverage](#test-coverage)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Transpilation Pipeline                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  src/*.sol ──► sol2ts.py ──► ts-output/*.ts ──► Angular Battle Service      │
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

### Key Design Principles

1. **Correct Transpilation Over Metadata**: The transpiled TypeScript behaves exactly like the Solidity source. Functions with conditional returns transpile to equivalent TypeScript conditionals - no metadata or heuristics needed.

2. **BigInt for All Integers**: Solidity's 256-bit integers map to JavaScript BigInt to maintain precision.

3. **Object References for Contracts**: In Solidity, contracts are identified by addresses. In TypeScript, we use object references directly for most operations, with `_contractAddress` available when actual addresses are needed.

4. **Storage Simulation**: The `Storage` class simulates Solidity's storage model with slot-based access.

5. **Dependency Injection**: The `ContractContainer` class provides automatic dependency resolution for contract instantiation.

---

## How the Transpiler Works

### Phase 1: Type Discovery

Before transpiling any file, the transpiler scans the source directory to discover:

- **Enums**: Collected into `Enums.ts` with numeric values
- **Structs**: Collected into `Structs.ts` as TypeScript interfaces
- **Constants**: Collected into `Constants.ts`
- **Contract/Library Names**: Used for import resolution

The type registry builds a **qualified name cache** for O(1) lookups, avoiding repeated set membership checks during code generation.

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
└── constructor: {...}
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

### Phase 6: Metadata Extraction (Optional)

When `--emit-metadata` is specified, the transpiler also extracts:

- **Dependencies**: Constructor parameters that are contract/interface types
- **Constants**: Constant values declared in the contract
- **Move Properties**: For contracts implementing `IMoveSet`, extracts name, power, etc.
- **Dependency Graph**: Maps each contract to its required dependencies

---

## Metadata and Dependency Injection

### Generating Metadata

The transpiler can emit metadata for dependency injection and UI purposes:

```bash
# Emit metadata alongside TypeScript
python3 sol2ts.py src/ -o ts-output -d src --emit-metadata

# Only emit metadata (skip TypeScript generation)
python3 sol2ts.py src/ --metadata-only -d src
```

This generates:

#### `dependency-manifest.json`

```json
{
  "contracts": {
    "UnboundedStrike": {
      "name": "UnboundedStrike",
      "filePath": "mons/iblivion/UnboundedStrike.sol",
      "inheritsFrom": ["IMoveSet"],
      "dependencies": [
        { "name": "_ENGINE", "typeName": "IEngine", "isInterface": true },
        { "name": "_TYPE_CALCULATOR", "typeName": "ITypeCalculator", "isInterface": true },
        { "name": "_BASELIGHT", "typeName": "Baselight", "isInterface": false }
      ],
      "constants": {
        "BASE_POWER": 80,
        "EMPOWERED_POWER": 130
      },
      "isMove": true,
      "isEffect": false,
      "moveProperties": {
        "name": "Unbounded Strike",
        "BASE_POWER": 80
      }
    }
  },
  "moves": { ... },
  "effects": { ... },
  "dependencyGraph": {
    "UnboundedStrike": ["IEngine", "ITypeCalculator", "Baselight"]
  }
}
```

#### `factories.ts`

Auto-generated factory functions for each contract:

```typescript
export function createUnboundedStrike(
  _ENGINE: IEngine,
  _TYPE_CALCULATOR: ITypeCalculator,
  _BASELIGHT: Baselight
): UnboundedStrike {
  return new UnboundedStrike(_ENGINE, _TYPE_CALCULATOR, _BASELIGHT);
}

export function setupContainer(container: ContractContainer): void {
  container.registerFactory('UnboundedStrike',
    ['IEngine', 'ITypeCalculator', 'Baselight'],
    (_ENGINE, _TYPE_CALCULATOR, _BASELIGHT) =>
      new UnboundedStrike(_ENGINE, _TYPE_CALCULATOR, _BASELIGHT)
  );
}
```

### Using the Dependency Injection Container

The runtime includes a `ContractContainer` for managing contract instances:

```typescript
import { ContractContainer, globalContainer } from './runtime';

// Create a container
const container = new ContractContainer();

// Register singletons (shared instances)
container.registerSingleton('Engine', new Engine());
container.registerSingleton('TypeCalculator', new TypeCalculator());

// Register factories with dependencies
container.registerFactory(
  'UnboundedStrike',
  ['Engine', 'TypeCalculator', 'Baselight'],
  (engine, typeCalc, baselight) => new UnboundedStrike(engine, typeCalc, baselight)
);

// Register lazy singletons (created on first resolve)
container.registerLazySingleton(
  'Baselight',
  ['Engine'],
  (engine) => new Baselight(engine)
);

// Resolve with automatic dependency injection
const move = container.resolve<UnboundedStrike>('UnboundedStrike');

// The container automatically:
// 1. Resolves Engine (singleton)
// 2. Resolves TypeCalculator (singleton)
// 3. Resolves Baselight (lazy singleton, creates Engine dependency)
// 4. Creates UnboundedStrike with all dependencies
```

### Bulk Registration from Manifest

```typescript
import manifest from './dependency-manifest.json';
import { factories } from './factories';

// Register all contracts from the manifest
container.registerFromManifest(manifest.dependencyGraph, factories);

// Now resolve any contract
const move = container.resolve('UnboundedStrike');
```

---

## Battle Simulation Harness

The `BattleHarness` class provides a high-level API for running battle simulations with automatic dependency injection.

### Quick Start

```typescript
import { BattleHarness, createBattleHarness } from './runtime';

// Create harness with module loader
const harness = await createBattleHarness(
  async (name) => import(`./ts-output/${name}`)
);

// Configure battle
const battleKey = await harness.startBattle({
  player0: '0x1111111111111111111111111111111111111111',
  player1: '0x2222222222222222222222222222222222222222',
  teams: [
    {
      mons: [{
        stats: { hp: 100n, stamina: 10n, speed: 50n, attack: 60n, defense: 40n, specialAttack: 70n, specialDefense: 45n },
        type1: 1,  // Fire
        type2: 0,  // None
        moves: ['BigBite', 'Recover', 'Tackle', 'Growl'],
        ability: 'UpOnly'
      }]
    },
    {
      mons: [{
        stats: { hp: 90n, stamina: 12n, speed: 55n, attack: 55n, defense: 45n, specialAttack: 65n, specialDefense: 50n },
        type1: 2,  // Water
        type2: 0,
        moves: ['Splash', 'Bubble', 'Tackle', 'Growl'],
        ability: 'Torrent'
      }]
    }
  ],
  addresses: {
    'Engine': '0xaaaa...',
    'StatBoosts': '0xbbbb...'
  }
});

// Execute turns
const state = harness.executeTurn(battleKey, {
  player0: { moveIndex: 0, salt: '0x' + 'a'.repeat(64), extraData: 0n },
  player1: { moveIndex: 1, salt: '0x' + 'b'.repeat(64) }
});

console.log('Turn:', state.turnId);
console.log('Winner:', state.winnerIndex);  // 0, 1, or 2 (ongoing)
console.log('Events:', state.events);
```

### Configuration Types

```typescript
// Mon configuration
interface MonConfig {
  stats: {
    hp: bigint;
    stamina: bigint;
    speed: bigint;
    attack: bigint;
    defense: bigint;
    specialAttack: bigint;
    specialDefense: bigint;
  };
  type1: number;   // Enum value
  type2: number;   // Enum value (0 for none)
  moves: string[]; // Contract names
  ability: string; // Contract name
}

// Team configuration
interface TeamConfig {
  mons: MonConfig[];
}

// Battle configuration
interface BattleConfig {
  player0: string;               // Address
  player1: string;               // Address
  teams: [TeamConfig, TeamConfig];
  addresses?: Record<string, string>;  // Optional contract addresses
  rngSeed?: string;              // Optional seed for deterministic RNG
}

// Turn input
interface TurnInput {
  player0: MoveDecision;
  player1: MoveDecision;
}

interface MoveDecision {
  moveIndex: number;  // 0-3 for moves, 125 for switch, 126 for no-op
  salt: string;       // bytes32 for RNG
  extraData?: bigint; // Target index, etc.
}
```

### Special Move Indices

```typescript
import { SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX } from './runtime';

// Switch to another mon
player0: { moveIndex: SWITCH_MOVE_INDEX, salt: '0x...', extraData: 2n }  // Switch to mon at index 2

// Do nothing (recover stamina)
player0: { moveIndex: NO_OP_MOVE_INDEX, salt: '0x...' }
```

### Battle State

After each turn, `executeTurn()` returns a `BattleState`:

```typescript
interface BattleState {
  turnId: bigint;                      // Current turn number
  activeMonIndex: [number, number];    // Active mon for each player
  winnerIndex: number;                 // 0, 1, or 2 (no winner yet)
  p0States: MonState[];                // State of all p0 mons
  p1States: MonState[];                // State of all p1 mons
  events: any[];                       // Events from this turn
}

interface MonState {
  hpDelta: bigint;           // HP change from base
  staminaDelta: bigint;      // Stamina change from base
  speedDelta: bigint;        // Speed stat modifier
  attackDelta: bigint;       // Attack stat modifier
  defenseDelta: bigint;      // Defense stat modifier
  specialAttackDelta: bigint;
  specialDefenseDelta: bigint;
  isKnockedOut: boolean;     // KO status
  shouldSkipTurn: boolean;   // Forced skip next turn
}
```

### Priority Calculation

Turn order is determined by:

1. **Move Priority** - Switches and no-ops have priority 6, moves use their `priority()` function
2. **Speed** - If priorities equal, faster mon goes first
3. **RNG** - If speeds equal, randomly determined from salts

### Loading Contracts On-Demand

The harness loads contracts lazily:

```typescript
// Load a specific move
const bigBite = await harness.loadMove('BigBite');

// Load an ability
const upOnly = await harness.loadAbility('UpOnly');

// Load an effect
const burn = await harness.loadEffect('BurnStatus');
```

### Using with Angular

```typescript
@Injectable({ providedIn: 'root' })
export class BattleService {
  private harness?: BattleHarness;

  async initialize(): Promise<void> {
    this.harness = await createBattleHarness(
      async (name) => import(`../../transpiler/ts-output/${name}`)
    );
  }

  async startBattle(config: BattleConfig): Promise<string> {
    if (!this.harness) await this.initialize();
    return this.harness!.startBattle(config);
  }

  executeTurn(battleKey: string, input: TurnInput): BattleState {
    return this.harness!.executeTurn(battleKey, input);
  }
}
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

# Transpile with metadata
python3 transpiler/sol2ts.py src/moves/mymove/CoolMove.sol \
    -o transpiler/ts-output \
    -d src \
    --emit-metadata

# Transpile an entire directory
python3 transpiler/sol2ts.py src/moves/mymove/ \
    -o transpiler/ts-output \
    -d src \
    --emit-metadata
```

### Step 3: Review the Output

Check `transpiler/ts-output/CoolMove.ts` for:

1. **Correct imports**: All dependencies should be imported
2. **Proper inheritance**: `extends` the right base class
3. **BigInt usage**: All numbers should be `bigint`
4. **Logic preservation**: Conditionals, loops, returns match the Solidity

### Step 4: Handle Dependencies

Use the dependency injection container:

```typescript
// Register core singletons
container.registerSingleton('Engine', engine);

// Register the move with its dependencies
container.registerFactory(
  'CoolMove',
  ['Engine'],
  (engine) => new CoolMove(engine)
);

// Resolve
const coolMove = container.resolve<CoolMove>('CoolMove');
```

Or use the generated factories if `--emit-metadata` was used:

```typescript
import { setupContainer } from './factories';

setupContainer(container);
const coolMove = container.resolve('CoolMove');
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

### Setting Up the Battle Service with Dependency Injection

```typescript
// client/lib/battle.service.ts

import { Injectable, signal, computed } from '@angular/core';
import { ContractContainer } from '../../transpiler/ts-output/runtime';

@Injectable({ providedIn: 'root' })
export class BattleService {
  private container = new ContractContainer();
  private initialized = signal(false);

  async initializeLocalSimulation(): Promise<void> {
    // Dynamic imports from transpiler output
    const [
      { Engine },
      { TypeCalculator },
      { StandardAttack },
      { StatBoosts },
      Structs,
      Enums,
      Constants,
    ] = await Promise.all([
      import('../../transpiler/ts-output/Engine'),
      import('../../transpiler/ts-output/TypeCalculator'),
      import('../../transpiler/ts-output/StandardAttack'),
      import('../../transpiler/ts-output/StatBoosts'),
      import('../../transpiler/ts-output/Structs'),
      import('../../transpiler/ts-output/Enums'),
      import('../../transpiler/ts-output/Constants'),
    ]);

    // Register core singletons
    const engine = new Engine();
    const typeCalculator = new TypeCalculator();
    const statBoosts = new StatBoosts(engine);

    this.container.registerSingleton('Engine', engine);
    this.container.registerSingleton('IEngine', engine);  // Interface alias
    this.container.registerSingleton('TypeCalculator', typeCalculator);
    this.container.registerSingleton('ITypeCalculator', typeCalculator);
    this.container.registerSingleton('StatBoosts', statBoosts);

    // Load move factories from generated manifest (optional)
    // Or register moves manually as needed

    this.initialized.set(true);
  }

  // Get a move instance with all dependencies resolved
  async getMove(moveName: string): Promise<any> {
    if (!this.initialized()) {
      await this.initializeLocalSimulation();
    }
    return this.container.resolve(moveName);
  }

  // Register a move dynamically
  registerMove(
    name: string,
    dependencies: string[],
    factory: (...deps: any[]) => any
  ): void {
    this.container.registerFactory(name, dependencies, factory);
  }
}
```

### Loading Moves Dynamically

```typescript
async loadMovesForMon(monName: string): Promise<void> {
  // Import moves for this mon
  const moveModules = await Promise.all([
    import(`../../transpiler/ts-output/mons/${monName}/Move1`),
    import(`../../transpiler/ts-output/mons/${monName}/Move2`),
    // ...
  ]);

  // Register each move with the container
  for (const module of moveModules) {
    const MoveCtor = Object.values(module)[0] as any;
    const moveName = MoveCtor.name;

    // Parse dependencies from the manifest or constructor
    const deps = this.getDependencies(moveName);

    this.container.registerFactory(moveName, deps, (...resolvedDeps) =>
      new MoveCtor(...resolvedDeps)
    );
  }
}
```

### Running a Local Battle Simulation

```typescript
async simulateBattle(team1: Mon[], team2: Mon[]): Promise<BattleResult> {
  await this.initializeLocalSimulation();

  const engine = this.container.resolve<Engine>('Engine');

  // Set up battle configuration
  const battleKey = engine.computeBattleKey(player1Address, player2Address);

  // Initialize teams
  engine.initializeBattle(battleKey, {
    p0Team: team1,
    p1Team: team2,
  });

  // Get move instances
  const move = this.container.resolve('BigBite');

  // Execute move
  const damage = move.move(
    battleKey,
    attackerIndex,
    defenderIndex,
    extraData,
    rng
  );

  return { damage, /* ... */ };
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

### Handling Effects and Abilities

Effects need to be registered and can be looked up by address:

```typescript
import { registry } from '../../transpiler/ts-output/runtime';

// Register effects
const burnStatus = container.resolve('BurnStatus');
const statBoosts = container.resolve('StatBoosts');

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

### Metadata & DI
- ✅ Dependency extraction from constructors
- ✅ Constant value extraction
- ✅ Move property extraction
- ✅ Dependency graph generation
- ✅ Factory function generation
- ✅ ContractContainer with automatic resolution

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

- Circular dependencies are detected and throw errors
- Interface types should be registered with the concrete implementation name

---

## Future Work

### High Priority

1. **Enhanced Move Metadata Extraction**
   - Extract `moveType()`, `moveClass()`, `priority()` return values
   - Support dynamic values (functions that compute based on state)
   - Generate UI-compatible metadata format

2. **Modifier Support**
   - Parse and inline modifier logic into functions
   - Currently modifiers are stripped

3. **Automatic Container Setup**
   - Generate a complete `setupContainer()` function that registers all contracts
   - Topological sort for correct initialization order

### Medium Priority

4. **Watch Mode**
   - Auto-re-transpile when Solidity files change
   - Integration with build pipelines

5. **Source Maps**
   - Map TypeScript lines back to Solidity for debugging

6. **Inheritance-Aware Dependency Resolution**
   - Traverse inheritance tree to find all required dependencies
   - Handle diamond inheritance patterns

### Low Priority

7. **VSCode Extension**
   - Inline preview of transpiled output
   - Error highlighting for unsupported patterns

8. **Fixed-Point Math**
   - Support `ufixed` and `fixed` types

9. **Custom Metadata Plugins**
   - Allow users to define custom metadata extractors
   - Support for game-specific metadata formats

---

## Test Coverage

### Unit Tests (`test_transpiler.py`)

```bash
cd transpiler && python3 test_transpiler.py
```

- ABI encode type inference (string, uint, address, mixed)
- Contract type imports (state variables, constructor params)

### Runtime Tests (`test/run.ts`)

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

- [ ] ContractContainer circular dependency detection
- [ ] Factory function generation validation
- [ ] Metadata extraction accuracy
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

# Single file with metadata
python3 transpiler/sol2ts.py src/path/to/File.sol -o transpiler/ts-output -d src --emit-metadata

# Directory with metadata
python3 transpiler/sol2ts.py src/moves/ -o transpiler/ts-output -d src --emit-metadata

# Metadata only (no TypeScript)
python3 transpiler/sol2ts.py src/moves/ --metadata-only -d src

# Print to stdout (for debugging)
python3 transpiler/sol2ts.py src/path/to/File.sol --stdout -d src

# Generate stub for a contract
python3 transpiler/sol2ts.py src/path/to/File.sol -o transpiler/ts-output -d src --stub ContractName
```

### Running Tests

```bash
cd transpiler

# Python unit tests
python3 test_transpiler.py

# TypeScript runtime tests
npm install
npm test
```

### File Structure

```
transpiler/
├── sol2ts.py              # Main transpiler script
├── test_transpiler.py     # Python unit tests
├── runtime/
│   └── index.ts           # Runtime library (Contract, Storage, ContractContainer)
├── ts-output/             # Generated TypeScript files
│   ├── runtime.ts         # Runtime library (copied from runtime/)
│   ├── Structs.ts         # All struct definitions
│   ├── Enums.ts           # All enum definitions
│   ├── Constants.ts       # All constants
│   ├── Engine.ts          # Battle engine
│   ├── dependency-manifest.json  # Contract metadata (--emit-metadata)
│   ├── factories.ts       # Factory functions (--emit-metadata)
│   └── *.ts               # Transpiled contracts
├── test/
│   ├── run.ts             # Test runner
│   ├── test-utils.ts      # Test utilities
│   ├── e2e.ts             # End-to-end tests
│   ├── engine-e2e.ts      # Engine-specific tests
│   └── battle-simulation.ts  # Battle scenario tests
└── package.json
```

### Key Runtime Exports

```typescript
// Core classes
export class Contract { ... }           // Base class for all contracts
export class Storage { ... }            // EVM storage simulation
export class ContractContainer { ... }  // Dependency injection container
export class Registry { ... }           // Move/Effect registry
export class EventStream { ... }        // Event logging

// Global instances
export const globalContainer: ContractContainer;
export const globalEventStream: EventStream;
export const registry: Registry;

// Utilities
export const ADDRESS_ZERO: string;
export function addressToUint(addr: string): bigint;
export function keccak256(...): string;
export function encodePacked(...): string;
export function encodeAbiParameters(...): string;
```
