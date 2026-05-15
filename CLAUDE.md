# CLAUDE.md

## How to Work

**Constraints first, then design.** Before proposing any solution, identify the hard constraints (language semantics, type system, inheritance, runtime behavior). If the approach conflicts with a constraint, don't propose it. Zero band-aid attempts — if it doesn't fit cleanly, the design is wrong. Redesign, don't force.

**Measure before deducing.** When debugging, add one targeted diagnostic and look at the data. Don't build chains of reasoning from assumptions about what the code "should" do. If the first theory doesn't match observations, measure — don't generate more theories from the same unverified premises.

**Fix at the right layer.** Don't patch symptoms. If a fix requires callers to know implementation details, it's at the wrong layer. If the same pattern needs 3+ special cases, the abstraction is wrong.

## Project Overview

**C.H.O.M.P.** (Credibly Hackable On-chain Monster PvP) is an on-chain turn-based PvP battling game inspired by Pokemon Showdown and M.U.G.E.N. Built on Solidity using the Foundry framework, it features an extensible battle engine where users can create custom moves, monsters ("mons"), effects, abilities, and hooks.

**License:** AGPL-3.0
**Solidity version:** 0.8.34

## Quick Start

```bash
forge install        # Install dependencies (forge-std)
forge build          # Compile contracts
forge test           # Run all tests
forge test -vvv      # Run tests with verbose output
```

## Repository Structure

```
chomp/
├── src/                    # Solidity source contracts
│   ├── Engine.sol          # Core battle engine (main entry point)
│   ├── IEngine.sol         # Engine interface
│   ├── Structs.sol         # All shared data structures
│   ├── Enums.sol           # All shared enums (Type, MoveClass, EffectStep, etc.)
│   ├── Constants.sol       # Global constants (move indices, defaults, sentinel values)
│   ├── DefaultValidator.sol # Validates game rules (team sizes, move legality, timeouts)
│   ├── DefaultRuleset.sol  # Configures initial global effects for battles
│   ├── IValidator.sol      # Validator interface
│   ├── IRuleset.sol        # Ruleset interface
│   ├── IEngineHook.sol     # Hook interface for battle lifecycle events
│   ├── abilities/          # Ability interface (IAbility.sol)
│   ├── commit-manager/     # Commit-reveal scheme for simultaneous moves
│   │   ├── DefaultCommitManager.sol
│   │   ├── SignedCommitManager.sol   # EIP-712 signed commits
│   │   └── ICommitManager.sol
│   ├── cpu/                # AI opponents (CPU players)
│   │   ├── CPU.sol         # Base CPU
│   │   ├── BetterCPU.sol   # Smarter AI
│   │   ├── OkayCPU.sol, RandomCPU.sol, PlayerCPU.sol
│   │   └── ICPU.sol
│   ├── effects/            # Effect system (status effects, stat boosts, battlefield)
│   │   ├── IEffect.sol     # Effect interface with lifecycle hooks
│   │   ├── BasicEffect.sol
│   │   ├── StaminaRegen.sol
│   │   ├── StatBoosts.sol
│   │   ├── status/         # Status effects (Burn, Frostbite, Panic, Sleep, Zap)
│   │   └── battlefield/    # Battlefield effects (Overclock)
│   ├── hooks/              # Engine hooks (BattleHistory)
│   ├── lib/                # Utility libraries (ECDSA, EIP712, Ownable, etc.)
│   ├── matchmaker/         # Battle matchmaking
│   │   ├── DefaultMatchmaker.sol     # Propose/accept/confirm flow
│   │   └── SignedMatchmaker.sol      # EIP-712 signed matchmaking
│   ├── mons/               # Individual mon implementations (one dir per mon)
│   │   ├── <monname>/      # Lowercase dir: 4 move .sol files + 1 ability .sol (+ optional libs)
│   │   ├── aurox/          # e.g. BullRush.sol, GildedRecovery.sol, IronWall.sol, UpOnly.sol, ...
│   │   ├── embursa/        # e.g. HeatBeacon.sol, SetAblaze.sol, Tinderclaws.sol, ...
│   │   └── ...             # See drool/mons.csv for full roster
│   ├── moves/              # Move system
│   │   ├── IMoveSet.sol    # Move interface
│   │   ├── StandardAttack.sol        # Base attack implementation
│   │   ├── StandardAttackFactory.sol
│   │   ├── StandardAttackStructs.sol # ATTACK_PARAMS struct
│   │   └── AttackCalculator.sol      # Damage calculation
│   ├── rng/                # Randomness oracle interface
│   ├── teams/              # Team registry (combined team + mon registry + gacha + progression)
│   │   ├── ITeamRegistry.sol
│   │   ├── GachaTeamRegistry.sol  # Roll, exp, daily multipliers, onBattleEnd hook
│   │   ├── Facets.sol             # 12-facet ±5% stat tradeoff system (abstract)
│   │   └── Quests.sol             # Daily quest pool + packed predicate evaluator (abstract)
│   └── types/              # Type effectiveness calculator
├── test/                   # Foundry test suite
│   ├── abstract/BattleHelper.sol  # Shared test helper (battle setup, commit-reveal)
│   ├── mocks/              # Mock contracts for testing
│   ├── effects/            # Effect-specific tests
│   ├── mons/               # Per-mon integration tests
│   ├── moves/              # Move system tests
│   ├── EngineTest.sol      # Core engine tests
│   ├── EngineGasTest.sol   # Gas benchmarks
│   └── *.sol               # Other test files
├── script/                 # Foundry deployment scripts
│   ├── EngineAndPeriphery.s.sol  # Deploy engine + periphery contracts
│   ├── SetupMons.s.sol     # Deploy all mons (auto-generated by processing/)
│   ├── SetupCPU.s.sol      # Deploy CPU players
│   └── Surgery.s.sol       # Maintenance/upgrade script
├── processing/             # Python build scripts
│   ├── buildAll.py         # Master orchestrator (sprites, validation, codegen)
│   ├── generateSolidity.py # Generate SetupMons.s.sol from CSV data
│   ├── validateMoves.py    # Validate move contracts match CSV data
│   ├── deploy.py           # Full deployment pipeline orchestrator
│   ├── buildTypeChart.py   # Build type effectiveness chart
│   ├── createAddressAndABIs.py      # Extract deployed addresses + ABIs
│   ├── generateMonsTypeScript.py    # Generate TypeScript mon data
│   ├── createMonSpritesheets.py     # Generate mon spritesheets
│   ├── createAttackSpritesheets.py  # Generate attack spritesheets
│   ├── inputToEnv.py       # Parse forge output to .env
│   └── removeUnusedImports.py       # Clean up unused Solidity imports
├── transpiler/             # Solidity-to-TypeScript transpiler (Python)
│   ├── sol2ts.py           # Main entry point
│   ├── lexer/              # Tokenizer
│   ├── parser/             # AST construction
│   ├── type_system/        # Type registry
│   ├── codegen/            # TypeScript code generation
│   ├── runtime/            # TypeScript runtime library
│   ├── dependency_resolver/ # Dependency resolution
│   └── test/               # TypeScript integration tests (vitest)
├── drool/                  # Game data (CSV) and frontend assets
│   ├── mons.csv            # Mon stats (HP, attack, speed, types, etc.)
│   ├── moves.csv           # Move definitions (power, stamina, accuracy, etc.)
│   ├── abilities.csv       # Ability definitions
│   ├── types.csv           # Type chart data
│   ├── imgs/               # Sprites (front/back/mini GIFs, spritesheets)
│   └── *.js, *.css, index.html  # Data viewer/analysis web app
├── docs/                   # Design docs and notes
├── snapshots/              # Foundry gas snapshots (JSON)
├── lib/                    # Git submodules (forge-std)
└── foundry.toml            # Foundry configuration
```

## Architecture

### Core Battle Flow

1. **Matchmaking**: Players propose and accept battles via `DefaultMatchmaker` or `SignedMatchmaker`
2. **Battle Start**: `Engine.startBattle()` initializes battle state, validates teams via `IValidator`
3. **Turn Loop** (commit-reveal):
   - Player 0 commits a hash of their move
   - Player 1 reveals their move
   - Player 0 reveals their preimage
   - `Engine.execute()` resolves the turn
4. **Turn Resolution**:
   - Priority determines move order (higher priority goes first; speed breaks ties)
   - Each player's move is executed (damage, effects, switches)
   - Effects run at their lifecycle hooks (RoundStart, AfterDamage, RoundEnd, etc.)
   - KO checks and forced switches
5. **Battle End**: When all mons on one side are KO'd

### Key Interfaces

| Interface | Purpose |
|-----------|---------|
| `IEngine` | Core battle engine - state mutation, battle management |
| `IMoveSet` | Move contract - `move()`, `priority()`, `stamina()`, `moveType()`, `moveClass()` |
| `IEffect` | Effect lifecycle - `onRoundStart()`, `onAfterDamage()`, `onRemove()`, etc. |
| `IAbility` | Mon ability - `activateOnSwitch()` |
| `IValidator` | Game rule validation - teams, moves, timeouts |
| `IRuleset` | Initial battle configuration (global effects) |
| `ICommitManager` | Commit-reveal move management |
| `IMatchmaker` | Battle matchmaking validation |
| `ITeamRegistry` | Team storage and retrieval |
| `IMonRegistry` | Mon data storage (stats, moves, abilities) |
| `IEngineHook` | Battle lifecycle hooks (OnBattleStart, OnRoundEnd, etc.) |
| `ICPU` | AI opponent interface |
| `IRandomnessOracle` | RNG source |

### Move System

Moves implement `IMoveSet`. Most standard attacks extend `StandardAttack`, which takes `ATTACK_PARAMS`:

```solidity
ATTACK_PARAMS({
    BASE_POWER: 50,
    STAMINA_COST: 2,
    ACCURACY: 100,
    PRIORITY: DEFAULT_PRIORITY,    // DEFAULT_PRIORITY = 3
    MOVE_TYPE: Type.Fire,
    EFFECT_ACCURACY: 30,
    MOVE_CLASS: MoveClass.Physical,
    CRIT_RATE: DEFAULT_CRIT_RATE,  // 5
    VOLATILITY: DEFAULT_VOL,       // 10
    NAME: "Tinderclaws",
    EFFECT: IEffect(address(0))
})
```

Custom moves implement `IMoveSet` directly for complex behavior.

### Effect System

Effects implement `IEffect` with a bitmap indicating which lifecycle steps they run at:
- `OnApply`, `RoundStart`, `RoundEnd`, `OnRemove`
- `OnMonSwitchIn`, `OnMonSwitchOut`
- `AfterDamage`, `AfterMove`, `OnUpdateMonState`

Effects can be per-mon (local) or global (battlefield-wide). The `StaminaRegen` effect is a global default that regenerates 1 stamina per turn.

### Type System

16 types: Yin, Yang, Earth, Liquid, Fire, Metal, Ice, Nature, Lightning, Mythic, Air, Math, Cyber, Wild, Cosmic, None. Type effectiveness is calculated by `ITypeCalculator`.

### Gacha & Progression System

`GachaTeamRegistry` is also an `IEngineHook` (subscribes to `OnBattleEnd`) and inherits `Facets` + `Quests`. It owns the full progression loop: rolling, points, per-mon exp, daily multipliers, level-up facet draws, and quest evaluation.

**Rolling.** Mon ids are sequential starting at 0 (`createMon` enforces `monId == monIds.length()`). Ids `[0, NUM_STARTERS)` (= 3) are *starter* mons.

- `firstRoll(uint256 starterId)` — one-shot per player. Caller picks `starterId ∈ {0,1,2}`; the contract guarantees that mon at slot 0 of the result and rolls `INITIAL_ROLLS - 1` (= 3) more uniformly from `[NUM_STARTERS, numMons)`. Free.
- `roll(uint256 numRolls)` — paid (`ROLL_COST` per roll, default 16 points). Uniform across the entire pool. Reverts `NoMoreStock` once the caller owns every mon.
- Linear-probing dedup keeps draws inside their window so `firstRoll`'s 3 random picks never land on a starter.

**Points / exp / facets storage.** All packed for gas:

```
playerData[address] (1 slot per player):
  bit 255       bonusAwarded (first-game-ever bonus claimed)
  bit 254       isWhitelistedAsOpponent (admin-set; replaces a separate mapping)
  bit 253       isHardCpu (only meaningful when bit 254 is set)
  bits 250-252  streakDay (1..STREAK_FLAT_BONUS_MAX; 0 = no streak yet)
  bits 192-223  lastQuestCompletedDay (uint32 calendar day)
  bits 128-159  lastFirstGameTimestamp (uint32 seconds since epoch)
  bits 0-127    pointsBalance (uint128)

packedExpForMon[player][monId / 16]: 16 mons × 16 bits each, capped at 65535.
facetData[player][monId / 16]:        16 mons × 16 bits each
                                       (bits 0-11 unlockedBitmap, bits 12-15 assignedFacetId).
```

Streak is timestamp-driven (not calendar-day): a battle counts as "first of day"
when ≥24h have passed since `lastFirstGameTimestamp`. A gap >36h
(`STREAK_GRACE_WINDOW`) resets `streakDay` to 1; otherwise it ratchets up
toward the cap of `STREAK_FLAT_BONUS_MAX` (= 5).

Both per-mon mappings share the same 16-mon bucketing so `_applyExpAndFacetDraws` walks the team in one pass and coalesces SSTOREs by bucket.

**Battle rewards (`onBattleEnd`).** CPU side is short-circuited (no SSTOREs, no event). For each human side:

- Base points: `POINTS_PER_WIN` (2) on win, `POINTS_PER_LOSS` (1) otherwise.
- Streak flat: `streakDay` (1..5) added inside the parenthetical of both the points and per-mon-exp formulas. Only granted when the battle qualifies as "first of day" (≥24h since the last grant).
- Points formula: `(basePts + streakFlat) × gachaMult + firstGameEverBonus`. `gachaMult` is `×QUEST_REWARD_MULT` (= 2) when the active daily quest completes (winner-only, one-shot per day), else 1. `firstGameEverBonus` is `+FIRST_GAME_EVER_BONUS` (= 16), one-shot ever, applied *after* the multiplier.
- Per-mon exp formula: `(baseExp + streakFlat) × expMult`, capped at 65535. `baseExp` is `EXP_PER_SURVIVING_MON` (2) for alive slots, `EXP_PER_KOD_MON` (1) for KO'd slots.
- `expMult` stack: `PVP_EXP_MULT` (×2) on any PvP battle **xor** `HARD_CPU_EXP_MULT` (×2) on a battle against the Hard CPU (mutually exclusive — PvP wins the branch), times `QUEST_REWARD_MULT` (×2) on quest completion. Max stack = ×4.
- Level-ups (12-tier curve, capped at level 12 to match `TOTAL_FACETS`) trigger one facet draw per level crossed.

**Facets.** 12 systematically-derived ±5% stat tradeoffs across 4 stat groups (`HP`, `Atk`, `Def`, `Speed`). `_facetDef(facetId)` is pure — no constant table. Unlocks are persistent per-mon; `assignFacets(monIds, facetIds)` is a free bulk re-assign that requires the caller to own every listed mon and the facet to be in the unlocked bitmap (`facetId == 0` clears). Active facets shift base stats at battle start (Engine applies deltas after validator, so the validator still sees base stats).

**CPU opponent facets.** When fighting a whitelisted opponent (CPU), the human caller picks the CPU's team *and* its facet config in one call: `setOpponentTeam(opponent, monIndices, facetIds)`. Per-user-per-CPU storage (`opponentTeamFacetsPacked[opponent][phantomKey]`) keyed by the same `uint16(uint160(msg.sender))` phantom slot as the team. No ownership/unlock checks — any facet 0..12 is allowed. `getTeamsWithDeltas` short-circuits to this slot-indexed config when a side is `isWhitelistedOpponent`, so per-user CPU facet configurations stay isolated even when many users fight the same CPU.

**Quests.** Owner-managed `questPool` + a single `activeQuestPacked` slot (current day + active quest id). One quest is active per day, picked pseudorandomly via lazy rotation at the *end* of `onBattleEnd` so the current battle is judged against the pre-rotation quest. Each quest has up to `MAX_PREDICATES_PER_QUEST` (6) AND-composed predicates packed into one storage slot (41 bits each: `op` 5b, `cmp` 3b, `negate` 1b, `arg` 16b, `operand` 16b — total 246b + 3b count). Opcodes cover battle context (`TURNS`, `ALIVE_COUNT`, `ACTIVE_SLOT_INDEX`, `MON_KO_AT_SLOT`), team composition (`HAS_MON_ID`), per-mon progression (`MON_LEVEL`, `MON_FACET`), and live battle state (`MON_STATE` via `Engine.getMonStateForBattle`).

**Events.**

- `Roll(address indexed player, uint256[] monIds, uint256 pointsSpent)` — fires on both `firstRoll` (spend = 0) and paid `roll`.
- `GachaEvent(bytes32 indexed battleKey, uint256 p0Packed, uint256 p1Packed)` — one per battle, carrying both sides' packed payloads (CPU side is 0). Layout sized for `MONS_PER_TEAM` up to 8: points (bits 0-15), per-mon exp gain (bits 16-79, 8 lanes × 8b), per-mon facets unlocked this battle (bits 80-175, 8 lanes × 12-bit bitmap = 1 bit per facet id), `BONUS_*` flags (bits 176-183: `FIRST_ROLL` | `FIRST_GAME` | `HARD_CPU` | `QUEST`), combined exp multiplier (bits 184-191), outcome (bits 192-199: 0=loss, 1=win, 2=draw), `streakDay` (bits 200-202). Lanes saturate so a future tuning blow-up can't bleed into neighbouring fields.

### Storage Architecture

- `BattleData` and `BattleConfig` are stored per battle key (derived from player addresses)
- `MonState` tracks deltas from base stats (hpDelta, staminaDelta, etc.)
- Effects stored in per-mon mappings with stride-based indexing (64 slots per mon)
- Heavy use of bit packing for gas efficiency (KO bitmaps, effect counts, active mon indices)
- Transient storage used for per-transaction state (`battleKeyForWrite`, `tempRNG`)

## Development Conventions

### Solidity Style

- AGPL-3.0 license header on all files
- Pragma: `^0.8.0`
- Imports: Use named imports (`import {Foo} from "path"`) - `sort_imports = true` in formatter
- Optimizer: max runs (4294967295) with via-IR enabled
- Constants: `SCREAMING_SNAKE_CASE` (though lint excludes this check)
- Move indices: 0-3 for regular moves (stored +1 to avoid zero ambiguity), 125 = switch, 126 = no-op
- State sentinel: `CLEARED_MON_STATE_SENTINEL = type(int32).max - 1`

### Mon Directory Conventions

Each mon lives in `src/mons/<monname>/` (lowercase). A typical directory contains:
- **4 move contracts** — one `.sol` file per move, `PascalCase` matching the move name (e.g., "Bull Rush" → `BullRush.sol`)
- **1 ability contract** — `PascalCase.sol` matching the ability name (e.g., `UpOnly.sol`)
- **Optional library files** — shared logic between moves in the same mon (e.g., `NineNineNineLib.sol`, `HeatBeaconLib.sol`)

Each mon has exactly one test file at `test/mons/<MonName>Test.sol` (PascalCase + "Test", e.g., `AuroxTest.sol`). Tests extend `BattleHelper`.

The CSV files in `drool/` are the source of truth for mon stats, move parameters, and ability assignments. The Solidity contracts must match these values — run `python processing/validateMoves.py` to verify.

### Testing Patterns

- Tests extend `BattleHelper` (in `test/abstract/`) which provides:
  - `_startBattle()`: Full battle setup with matchmaker propose/accept/confirm
  - `_commitRevealExecuteForAliceAndBob()`: Execute a turn with commit-reveal
  - `ALICE` = `address(0x1)`, `BOB` = `address(0x2)`
- Per-mon tests in `test/mons/` test specific move interactions
- Mock contracts in `test/mocks/` for isolated testing
- Gas benchmarks in `EngineGasTest.sol` and `InlineEngineGasTest.sol` with JSON snapshots

### Development Approach

When implementing new features or refactors, follow a test-first approach:
1. Write tests that specify the desired behavior
2. Run to verify the tests fail (confirming they test new behavior)
3. Implement the changes
4. Run to verify the tests pass

### Adding a New Mon

1. Add mon stats to `drool/mons.csv` (HP, Attack, Defense, SpAtk, SpDef, Speed, Types)
2. Add 4 moves to `drool/moves.csv` (Name, Mon, Power, Stamina, Accuracy, Priority, Type, Class, etc.)
3. Add ability to `drool/abilities.csv` (Name, Mon, Effect description)
4. Create directory `src/mons/<monname>/` (lowercase, e.g., `src/mons/aurox/`)
5. Implement 4 move contracts as `PascalCase.sol` files (see "Move Implementation Patterns" below)
6. Implement 1 ability contract as `PascalCase.sol` (see "Ability Patterns" below)
7. Run `python processing/validateMoves.py` to validate contracts match CSV data
8. Run `python processing/buildAll.py --skip-sprites` to regenerate `SetupMons.s.sol`
9. Add tests in `test/mons/<MonName>Test.sol` extending `BattleHelper`

### Move Implementation Patterns

Choose the simplest pattern that fits the move's behavior:

**1. Pure `StandardAttack`** — constructor-only, no `move()` override. For straightforward damaging moves or simple effect-applying moves. Pass `EFFECT` + `EFFECT_ACCURACY` for probabilistic status application (e.g., 30% chance to burn):

```solidity
contract Blow is StandardAttack {
    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR)
        StandardAttack(msg.sender, _ENGINE, _TYPE_CALCULATOR, ATTACK_PARAMS({
            BASE_POWER: 70, STAMINA_COST: 2, ACCURACY: DEFAULT_ACCURACY,
            PRIORITY: DEFAULT_PRIORITY, MOVE_TYPE: Type.Air,
            EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
            CRIT_RATE: DEFAULT_CRIT_RATE, VOLATILITY: DEFAULT_VOL,
            NAME: "Blow", EFFECT: IEffect(address(0))
        }))
    {}
}
```

**2. `StandardAttack` + `move()` override** — for moves with side effects after damage (recoil, self-switch, self-status, multi-hit). Call `_move()` which returns `(int32 damage, bool crit)`, then add custom logic:

```solidity
function move(...) public override {
    (int32 damage,) = _move(battleKey, attackerPlayerIndex, attackerMonIndex, defenderMonIndex, rng);
    if (damage > 0) {
        ENGINE.dealDamage(attackerPlayerIndex, attackerMonIndex, selfDamage); // recoil
    }
}
```

Moves that require the player to select a target mon override `extraDataType()` to return `ExtraDataType.SelfTeamIndex` or `ExtraDataType.OpponentNonKOTeamIndex`.

**3. Custom `IMoveSet`** — for complex conditional moves (variable power, healing, stat manipulation, reading opponent state). Implement all 7 `IMoveSet` functions directly. Use `AttackCalculator._calculateDamage()` for damage. Store dependencies as `immutable`.

**4. `IMoveSet` + `BasicEffect` hybrid** — for moves that persist as effects across turns (traps, delayed damage, per-turn modifiers). Implement both interfaces in one contract. The `move()` function calls `ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), ...)`.

**Shared libraries** — when multiple moves in the same mon share logic, extract into a `library` contract in the same directory (e.g., `NineNineNineLib.sol`, `HeatBeaconLib.sol`).

### Ability Patterns

Each mon has exactly one ability, implemented in its own `PascalCase.sol` file within the mon directory.

**Pure `IAbility`** — for one-time switch-in actions (deal damage, apply a stat boost). Implement `name()` and `activateOnSwitch()`. No persistent state. (e.g., `PreemptiveShock`, `SaviorComplex`)

**`IAbility` + `BasicEffect`** (most common) — for abilities with ongoing lifecycle effects. `activateOnSwitch()` registers `address(this)` as an effect on the mon, then hooks into effect lifecycle via `getStepsBitmap()`. Must override `name()` with `override(IAbility, BasicEffect)`. Uses an idempotency guard to prevent duplicate registration:

```solidity
function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
    (EffectInstance[] memory effects,) = ENGINE.getEffects(battleKey, playerIndex, monIndex);
    for (uint256 i; i < effects.length; i++) {
        if (address(effects[i].effect) == address(this)) return;
    }
    ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
}
```

For once-per-battle abilities (e.g., `RiseFromTheGrave`), use a `globalKV` flag instead of the effect-list check.

### Adding a New Effect

Effects fall into several categories depending on scope:

- **Status effects** (`src/effects/status/`): Extend `StatusEffect` which enforces one-status-per-mon via a KV flag. Shared across mons — deployed once, injected into moves via constructor parameters. (e.g., `BurnStatus`, `FrostbiteStatus`, `SleepStatus`)
- **Battlefield effects** (`src/effects/battlefield/`): Extend `BasicEffect`, use `targetIndex=2` for global scope. (e.g., `Overclock`)
- **Shared utility effects** (`src/effects/`): Deployed once, used by many contracts. (e.g., `StatBoosts` for stat modifiers, `StaminaRegen` for per-turn recovery)
- **Mon-local effects** (`src/mons/<monname>/`): Abilities or move-effect hybrids that only apply to one mon. These live in the mon's directory, not in `src/effects/`.

To implement a new effect:
1. Extend `BasicEffect` (or `StatusEffect` for status conditions)
2. Override the relevant lifecycle hooks (`onRoundEnd`, `onAfterDamage`, etc.)
3. Return a bitmap from `getStepsBitmap()` indicating which hooks to call
4. Return `(updatedExtraData, removeAfterRun)` from hooks — use `extraData` (bytes32) to carry state between turns (counters, degrees, flags)
5. Shared effects are injected into moves/abilities via constructor parameters at deploy time — there is no runtime effect registry

## Build & Deploy Pipeline

### Processing Scripts (Python 3.11+)

```bash
# Full build pipeline
python processing/buildAll.py [--skip-sprites] [--skip-validation] [--color]

# Individual scripts
python processing/validateMoves.py          # Validate contracts vs CSV
python processing/generateSolidity.py       # Generate SetupMons.s.sol
python processing/deploy.py --testnet       # Full deployment (forge scripts + codegen)
python processing/deploy.py --mainnet       # Production deployment
```

Python dependencies: `numpy`, `pexpect`, `pillow` (managed via `uv`, see `pyproject.toml`)

### Transpiler (Solidity to TypeScript)

Converts Solidity contracts to TypeScript for local battle simulation:

```bash
# Transpile all contracts
python3 transpiler/sol2ts.py src/ -o transpiler/ts-output -d src --emit-metadata

# Run transpiler tests
cd transpiler && npm install && npx vitest run
```

### Deployment Order

1. `EngineAndPeriphery.s.sol` - Engine, validators, commit managers, matchmakers, registries
2. `SetupMons.s.sol` - All mon contracts (moves, abilities)
3. `SetupCPU.s.sol` - CPU players

### CI/CD

GitHub Actions runs on pull requests (`.github/workflows/main.yml`):
- `forge build`
- `forge test -vvv`

## Key Data Files

| File | Purpose |
|------|---------|
| `drool/mons.csv` | Mon stats: Id, Name, HP, Attack, Defense, SpAtk, SpDef, Speed, Type1, Type2, Flavor |
| `drool/moves.csv` | Move data: Name, Mon, Power, Stamina, Accuracy, Priority, Type, Class, DevDescription, UserDescription, InputType |
| `drool/abilities.csv` | Ability assignments: Name, Mon, Effect |
| `drool/types.csv` | Type effectiveness chart |

CSV-to-code mapping notes:
- **Priority** in `moves.csv` is a signed offset from `DEFAULT_PRIORITY` (3). So `0` = default, `1` = faster, `-1` = slower.
- **Power** can be `?` for variable-power custom moves (Tier 3/4 implementations)
- **InputType** maps to `ExtraDataType` enum: `none` → `None`, `self-mon` → `SelfTeamIndex`, `opponent-mon` → `OpponentNonKOTeamIndex`
- **Type2** is `"NA"` for single-type mons

## Known Issues / Gotchas

- If a move forces a switch before the other player acts, the new mon will still try to execute its move (Engine skips if stamina is insufficient)
- If an effect calls `dealDamage()` and triggers `AfterDamage`, it can cause infinite loops - avoid dealing damage in `onAfterDamage` hooks
- RNG reuse: `StandardAttack` uses the same RNG for both accuracy and effect chance, making them correlated rather than independent
- Malicious p0 can modify mon moves between commit and battle start - mitigate via team registry or adding move indices to integrity hash
- `MAX_BATTLE_DURATION` is 1 hour; `TIMEOUT_DURATION` is configurable per validator

## Gas Optimization Notes

- Storage bit-packing throughout (BattleData, BattleConfig, KO bitmaps, effect counts)
- Batch context structs (`BattleContext`, `DamageCalcContext`, `ValidationContext`) to reduce external calls / SLOADs
- Effect step bitmaps avoid calling effects at steps they don't use
- `MappingAllocator` for efficient storage slot management
- Transient storage for per-call state to avoid unnecessary SLOADs/SSTOREs
- Optimizer runs set to max (4294967295) with via-IR for aggressive optimization
