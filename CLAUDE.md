# CLAUDE.md

## How to Work

**Constraints first, then design.** Before proposing any solution, identify the hard constraints (language semantics, type system, inheritance, runtime behavior). If the approach conflicts with a constraint, don't propose it. Zero band-aid attempts — if it doesn't fit cleanly, the design is wrong. Redesign, don't force.

**Measure before deducing.** When debugging, add one targeted diagnostic and look at the data. Don't build chains of reasoning from assumptions about what the code "should" do. If the first theory doesn't match observations, measure — don't generate more theories from the same unverified premises.

**Fix at the right layer.** Don't patch symptoms. If a fix requires callers to know implementation details, it's at the wrong layer. If the same pattern needs 3+ special cases, the abstraction is wrong.

## Project Overview

**chomp.** (Credibly Hackable On-chain Monster PvP) is an on-chain turn-based PvP battling game inspired by Pokemon Showdown. Built on Solidity using the Foundry framework, it features an extensible battle engine where users can create custom moves, monsters ("mons"), effects, abilities, and hooks.

**License:** AGPL-3.0
**Solidity version:** ^0.8.34

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
│   ├── Constants.sol       # Global constants (move indices, battle modes, slots/targeting, sentinels)
│   ├── DefaultRuleset.sol  # Configures initial global effects for battles
│   ├── IRuleset.sol        # Ruleset interface
│   ├── IEngineHook.sol     # Hook interface for battle lifecycle events
│   ├── abilities/          # Ability interface (IAbility.sol)
│   ├── commit-manager/     # External commit-reveal move managers (singles only; the dual-signed
│   │                       #   per-turn buffer and all 2-slot flows now live in the Engine)
│   │   ├── DefaultCommitManager.sol  # Classic 2-player commit/reveal (base class)
│   │   ├── SignedCommitManager.sol   # EIP-712 single-tx dual-signed moves (deployed manager)
│   │   ├── SignedCommitLib.sol       # Shared signed-commit helpers
│   │   └── ICommitManager.sol
│   ├── cpu/                # PvE host (on-chain CPU decision-making removed; moves come from the client)
│   │   ├── CPU.sol                # Self-registering matchmaker + one-tx config-and-start bundles
│   │   │                          #   (startCustomBattle / startCustomMultiBattle)
│   │   └── CPUMoveManager.sol     # Relays client-computed CPU moves through the Engine
│   ├── effects/            # Effect system (status effects, battlefield)
│   │   ├── IEffect.sol     # Effect interface with lifecycle hooks
│   │   ├── BasicEffect.sol
│   │   ├── StaminaRegen.sol
│   │   ├── status/         # Status effects (Blessed, Burn, Frostbite, Panic, Sleep, Zap) + StatusEffect(Lib)
│   │   ├── battlefield/    # Battlefield effects (Overclock)
│   │   # NOTE: stat boosts are inlined into the Engine (see "Stat Boosts" below); the math
│   │   #       helpers live in src/lib/StatBoostLib.sol, there is no StatBoosts effect contract.
│   ├── game-layer/         # Team / mon registry, gacha, exp, facets, quests, gifts
│   │   ├── GachaTeamRegistry.sol   # Concrete leaf: composes the abstracts below
│   │   ├── MonOwnership.sol        # monsOwned set + ownership view/check helpers
│   │   ├── MonRegistry.sol         # Owner-managed mon catalog (stats / moves / abilities / metadata)
│   │   ├── PlayerProfile.sol       # Packed playerData slot, CPU/whitelist flags, assigner allowlist
│   │   ├── PackedTeamStore.sol     # Bit-packed team CRUD (4 teams per slot, 16 slots per player)
│   │   ├── Facets.sol              # 12-facet ± stat tradeoff system (abstract)
│   │   ├── MonExp.sol              # Packed exp, level curve, level-up facet draws, assignExp
│   │   ├── Quests.sol              # Daily quest pool + packed predicate evaluator (abstract)
│   │   ├── ReturnerGift.sol        # Daily-return points + exp gift contract (assigner)
│   │   ├── ITeamRegistry.sol       # Public read/write surface that the leaf exposes
│   │   ├── IGachaPointsAssigner.sol / IExpAssigner.sol  # Owner-allowlisted off-band grants
│   │   └── IPhantomTeamRegistry.sol  # CPU-relayer entry for writing user phantom team configs
│   ├── hooks/              # Engine hooks (e.g. SimplePM)
│   ├── lib/                # Utility libraries: ECDSA, EIP712, Ownable, EnumerableSetLib,
│   │                       # MappingAllocator, MerkleProofLib, Multicall3, RNGLib, StaminaRegenLogic,
│   │                       # StatBoostLib, SwitchTargetLib, TargetLib (slot/target helpers),
│   │                       # ValidatorLogic (pure validation helpers; the external IValidator is gone)
│   ├── matchmaker/         # Battle matchmaking
│   │   ├── DefaultMatchmaker.sol     # Propose/accept/confirm (DEPRECATED, singles, test-only)
│   │   ├── SignedMatchmaker.sol      # EIP-712 startGame — production; all modes, party/open seats
│   │   ├── BattleOfferLib.sol        # Shared offer-hash + seat helpers (battleMode is signed)
│   │   └── IMatchmaker.sol           # Bare marker interface (auth gate; validateMatch removed)
│   ├── mons/               # Individual mon implementations (one dir per mon)
│   │   ├── <monname>/      # Lowercase dir: 4 move .sol files + 1 ability .sol (+ optional libs)
│   │   ├── aurox/          # e.g. BullRush.sol, GildedRecovery.sol, IronWall.sol, UpOnly.sol, ...
│   │   ├── embursa/        # e.g. HeatBeacon.sol, SetAblaze.sol, Tinderclaws.sol, ...
│   │   └── ...             # ~13 mons total; see drool/mons.csv for the full roster
│   ├── moves/              # Move system
│   │   ├── IMoveSet.sol               # Move interface (move() + bundled getMeta()→MoveMeta)
│   │   ├── StandardAttack.sol         # Base attack implementation
│   │   ├── StandardAttackFactory.sol
│   │   ├── StandardAttackStructs.sol  # ATTACK_PARAMS struct
│   │   ├── AttackCalculator.sol       # Damage calc (delegates to Engine dispatch)
│   │   └── MoveSlotLib.sol            # Inline move-word packing (moveType/class/priority/stamina/basePower)
│   ├── rng/                # Randomness oracle interfaces + DefaultRandomnessOracle
│   │                       # (IRandomnessOracle for battles, IGachaRNG for the gacha)
│   └── types/              # Type effectiveness calculator (TypeCalculator + TypeCalcLib)
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
│   ├── generateSolidity.py          # Generate SetupMons.s.sol from CSV data
│   ├── generateSetupCPU.py          # Generate SetupCPU.s.sol team config from cpu-teams.json
│   ├── validateMoves.py             # Validate move contracts match CSV data
│   ├── deploy.py                    # Full deployment pipeline orchestrator
│   ├── deploy_addresses.py          # Inline ability/move address packing for the deploy pipeline
│   ├── buildTypeChart.py            # Build type effectiveness chart
│   ├── buildDamageGifs.py           # Render damage-preview GIFs
│   ├── createAddressAndABIs.py      # Extract deployed addresses + ABIs
│   ├── generateMonsTypeScript.py    # Generate TypeScript mon data
│   ├── generateEventLayouts.py      # Generate generated/eventLayouts.ts (GachaEvent bit layout)
│   ├── generateEip712Meta.py        # Generate generated/eip712Meta.ts (typehash strings + domains)
│   ├── createMonSpritesheets.py     # Generate mon spritesheets
│   ├── createAttackSpritesheets.py  # Generate attack spritesheets
│   ├── packMoves.py                 # Pack move data for distribution
│   ├── inputToEnv.py                # Parse forge output to .env
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

### Battle Modes

Every battle runs in one of three modes (a `uint8` in `BattleConfig.battleMode`, mirrored onto
`BattleData` as `isTwoSlotMode`/`isMultiMode` at start):

| Mode | Const | Actives / side | Controllers |
|------|-------|----------------|-------------|
| Singles | `BATTLE_MODE_SINGLES` (0) | 1 | p0 vs p1 |
| Doubles | `BATTLE_MODE_DOUBLES` (1) | 2 (slots 0 & 1) | one controller per side (p0 drives both of side 0's slots) |
| Multi | `BATTLE_MODE_MULTI` (2) | 2 | 4 seats, one per slot (p0, p1, p2, p3) |

- **Singles** keeps the legacy storage layout byte-identical (slot-1 lanes are never touched).
- **Doubles / Multi** are the "2-slot" family. In **Multi**, each side's 8-mon roster is the
  concatenation of its two seats' 4-mon teams at a fixed stride-4 partition (seat 0 → roster
  `[0..3]`, seat 1 → `[4..7]`); the extra seats live in `multiSeats[battleKey]` (`MultiSeatData`).
- **Canonical seat order is `[p0, p2, p1, p3]`** (side-major) — used by `getSeats`, seat rotation,
  and the `cpuSeatMask`. This is NOT the `Battle` struct field order.
- `startBattle()` starts a singles battle; `startBattleWithMode(battle, mode)` validates the mode
  byte and the p2/p3 invariant (Multi requires both non-zero; Singles/Doubles forbid them). Battle
  keys derive from `computeBattleKey(p0, p1)` (Singles/Doubles) or `computePartyKey(p0, p1, p2, p3)`
  (Multi).

### Slots & Targeting

- **Absolute slot** = `side*2 + slotIndex` (0,1 = side 0; 2,3 = side 1). `activesPacked` carries one
  8-bit lane per absolute slot holding that slot's active roster index (`EMPTY_ACTIVE_LANE = 0xFF`).
  Slot-0 lanes live in `BattleData.activeMonIndex`, slot-1 lanes in `activeMonExt`. Moves and
  effects resolve targets from `activesPacked` via `TargetLib` — no calls back into the Engine.
- A move's 16-bit wire `extraData` splits `[targetBits 4 | payload 12]`: the top nibble is a bitmask
  over absolute slots (the chosen target), the low 12 bits are the move's own payload (team indices,
  ModalBolt modes, …). The Engine strips the nibble before invoking the move.
- A move's target domain is **not** declared in Solidity: its `move()` either resolves a defender
  from `targetBits` (slot-targeting) or ignores it (self-buffs, global setups, or payload-targeted
  moves like Sneak Attack). `drool/moves.csv`'s `TargetSpec` column is the authoritative client-facing
  metadata (→ TS `Move.targetSpec`), and `validateMoves.py` checks each move's `targetBits` behavior
  against it. **Singles ignores the nibble** — targeting is implied (the opposing active).

### Core Battle Flow

1. **Matchmaking**: production battles use `SignedMatchmaker.startGame(offer, openSeatsMask,
   seatSigs)` — one EIP-712 `BattleOffer` whose `battleMode` is part of the signed struct, with
   open-seat / SeatFill support for party (Multi) games. (`DefaultMatchmaker` is deprecated,
   singles-only, test-suite-only.) PvE battles are opened by the player calling
   `CPU.startCustomBattle` / `startCustomMultiBattle` — one tx that writes the phantom opponent team
   config and starts the battle.
2. **Battle Start**: `Engine.startBattle(WithMode)` snapshots teams (validated against the
   `ITeamRegistry` snapshot + a per-seat 4-mon length check), gates every seat through matchmaker
   authorization, and stores mode / seat data. Validation is fully inline — there is no external
   `IValidator`.
3. **Move submission** (one path per battle, chosen by `moveManager`):
   - **Built-in dual-signed buffer** (default PvP): `moveManager == BUILTIN_DUAL_SIGNED_MANAGER`
     (`0x5165`) routes through the Engine's own buffer — `submitTurnMoves` / `submitSlotTurnMoves`
     stage a signature-checked turn; `executeBuffered` drains it.
   - **External commit manager** (`SignedCommitManager`): singles single-tx `executeWithDualSignedMoves`.
   - **2-slot turns**: `executeWithSlotMoves(key, side0Packed, side1Packed)` (one packed word per
     side); whole-game replays via `executeBatchedTurns` / `executeBatchedSlotTurns`.
4. **Turn Resolution**:
   - **Singles**: RNG from both salts → priority player (higher move priority; effective speed
     tie-break; `rng % 2` on a full tie) → RoundStart effects → priority move → AfterMove / stamina
     → other move → (turn 0: switch-in abilities) → RoundEnd effects. A KO locks the winner
     immediately at the KO site.
   - **2-slot (Doubles / Multi)**: a greedy dynamic scheduler makes up to 4 picks, each choosing the
     un-acted live slot with the highest (locked priority, live speed, fresh jitter). KO'd actives
     don't act, and KOs never cancel remaining actions — only game-over returns early. Empty lanes
     act only on turn 0 (send-ins).
   - **Effects** run at their lifecycle hooks (RoundStart, PreDamage, AfterDamage, AfterMove,
     RoundEnd, …); `PreDamage` lets mon-local effects mutate the in-flight damage via
     `getPreDamage` / `setPreDamage`.
   - **Forced switches** are encoded in `playerSwitchForTurnFlag`: singles uses `0`/`1` (that side
     switches) vs `2` (both act); 2-slot uses `0x80 | slotMask` (only the masked KO'd slots switch)
     vs `2` (full turn).
5. **Battle End**: when a full side is KO'd, on timeout (`end()` after `MAX_BATTLE_DURATION`), or via
   `forfeit(battleKey)` (concede — the opposing side's lead is credited; grants no gacha rewards).

### Key Interfaces

| Interface | Purpose |
|-----------|---------|
| `IEngine` | Core battle engine - state mutation, battle management |
| `IMoveSet` | Move contract - `move()` (slot-targeted), `getMeta()`→`MoveMeta`, `priority()`, `stamina()`, `moveType()`, `moveClass()` |
| `IEffect` | Effect lifecycle - `onRoundStart()`, `onPreDamage()`, `onAfterDamage()`, `onRemove()`, etc. (all take `activesPacked`) |
| `IAbility` | Mon ability - `activateOnSwitch()` |
| `IRuleset` | Initial battle configuration (global effects) |
| `ICommitManager` | External commit-reveal move management (singles only) |
| `IMatchmaker` | Bare marker interface — the Engine's matchmaker authorization gate |
| `ITeamRegistry` | Combined team CRUD + mon catalog + exp/level + facet getters (implemented by `GachaTeamRegistry` via its abstract bases) |
| `IGachaPointsAssigner` / `IExpAssigner` | Owner-allowlisted off-band grants of points / exp (e.g. `ReturnerGift`) |
| `IPhantomTeamRegistry` | CPU-relayer entry for writing a user's phantom team config from a whitelisted CPU |
| `IEngineHook` | Battle lifecycle hooks (OnBattleStart, OnRoundStart, OnRoundEnd, OnBattleEnd) |
| `IRandomnessOracle` / `IGachaRNG` | RNG sources, scoped by consumer |

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

These are packed into inline move words (see `MoveSlotLib`) rather than deployed as separate
contracts, and mirrored to JSON for the client. `StandardAttack`'s base `move()` resolves the defender
from `targetBits`; a move's client-facing target domain lives in `moves.csv`'s `TargetSpec` column,
not in Solidity.

Custom moves implement `IMoveSet` directly for complex behavior. The current interface is
`move(engine, battleKey, attackerPlayerIndex, attackerMonIndex, targetBits, activesPacked,
extraData, rng)` plus the metadata getters (`priority`/`stamina`/`moveType`/`moveClass`) and the
bundled `getMeta()`→`MoveMeta` (`{moveType, moveClass, priority, stamina, basePower}`).
Moves resolve targets from `targetBits` + `activesPacked` via `TargetLib` (they no longer receive a
defender index), and deal damage through `engine.dispatchStandardAttack` / `dispatchCustomAttack`
(both take `targetBits`).

### Effect System

Effects implement `IEffect` with a bitmap (`getStepsBitmap()`) indicating which lifecycle steps they
run at:
- `OnApply` (0x01), `RoundStart` (0x02), `RoundEnd` (0x04), `OnRemove` (0x08)
- `OnMonSwitchIn` (0x10), `OnMonSwitchOut` (0x20)
- `AfterDamage` (0x40), `AfterMove` (0x80), `OnUpdateMonState` (0x100), `PreDamage` (0x200)

`PreDamage` runs before damage is applied — subscribed effects read the in-flight value via
`engine.getPreDamage()` and mutate it via `engine.setPreDamage(int32)`, composing in effect-array
order (e.g. `Adaptor` halves matching damage). `AfterDamage`, `AfterMove`, `OnUpdateMonState`, and
`PreDamage` currently run **only on mon-local effects** (global effects skip them). Every lifecycle
hook now receives `activesPacked` so effects can resolve slots via `TargetLib` without calling back
into the Engine.

Effects can be per-mon (local; `targetIndex` = the owning player index) or global (battlefield-wide;
side index `2`). The `StaminaRegen` effect is a global default that regenerates 1 stamina per turn.

### Stat Boosts (inlined into the Engine)

Stat modifiers are **not** a separate effect contract — they are native Engine functions:
`addStatBoost` / `removeStatBoost` / `clearAllStatBoosts`
(declared in `IEngine`). Moves, abilities, and shared effects (`BurnStatus`, `FrostbiteStatus`,
`Overclock`, `UpOnly`, `Tinderclaws`, …) call `engine.addStatBoost(...)` directly during `execute`.
The packing/aggregation math lives in `src/lib/StatBoostLib.sol`. (Historically this was an external
`StatBoosts` effect that the Engine called back into ~10–15× per application; inlining removed those
round-trips.)

How it works:
- Each boost **source** is one packed entry stored in the mon's normal effect mapping under the
  `STAT_BOOST_ADDRESS` sentinel (steps bitmap `STAT_BOOST_STEPS` = `OnMonSwitchOut | ALWAYS_APPLIES`).
  Sources are keyed by `msg.sender`, so each move/ability/effect
  stacks independently and can remove its own boost. Boosts are **multiplicative** per source; `Temp`
  boosts are dropped automatically on switch-out (`_inlineStatBoostSwitchOut`), `Perm` ones persist.
- Boosts apply only to the 5 stat deltas: `Speed`, `Attack`, `Defense`, `SpecialAttack`,
  `SpecialDefense`. There is **no globalKV snapshot** — the Engine telescopes off the live `monState`
  delta (`new boosted − base − currentDelta`) and fires `OnUpdateMonState` like any other delta write.
- **Ownership invariant:** the stat-boost system is the *sole* writer of those 5 deltas. External
  `updateMonState` calls with `Speed`..`SpecialDefense` **revert with `StatRequiresStatBoost`** — to
  change a stat you must go through `add`/`removeStatBoost`, never `updateMonState`. (`Hp`, `Stamina`,
  `IsKnockedOut`, `ShouldSkipTurn` remain writable via `updateMonState`.)

### Type System

15 types: Yin, Yang, Earth, Liquid, Fire, Metal, Ice, Nature, Lightning, Faith, Air, Math, Cyber, Cosmic, None. Type effectiveness is calculated by `ITypeCalculator`.

### Gacha & Progression System

`GachaTeamRegistry` is the concrete leaf — it's an `IEngineHook` (subscribes to `OnBattleEnd`) and composes seven abstract bases that each own one slice of state and behavior:

| Abstract | Owns |
|---|---|
| `MonOwnership` | `monsOwned` per-player set; ownership view + bulk-check helpers (`_isOwnerBatch`, `_validateOwnership`). Satisfies the `_isFacetMonOwned` hook on `Facets`. |
| `MonRegistry` | Owner-managed mon catalog (`monStats`, `monMoves`, `monAbilities`, `monMetadata`, sequential `monIds` set). Inherits `ITeamRegistry` so its `createMon`/`modifyMon`/batched-getters bind directly. Backs the `_getMonStatsForFacets` hook used by facet delta computation. |
| `PlayerProfile` | Packed `playerData[address]` (one uint256 per player) + the owner-managed `isAssigner` allowlist. Exposes `pointsBalance`, `isWhitelistedOpponent`, the bulk admin flag setters, and `assignPoints` (IGachaPointsAssigner). |
| `PackedTeamStore` | Bit-packed team CRUD: `teamGroupsPacked` (4 teams × 64 bits per slot), `teamOrderPacked` (16-slot live bitmap + display order). Constructor takes `MONS_PER_TEAM` / `MOVES_PER_MON` immutables. Subclass hooks: `_packedTeamValidateOwnership`, `_packedTeamIsCpuOpponent`, `_packedTeamGetMonData`. |
| `Facets` | 12-facet ±5% stat tradeoff system (see below). Pure helpers, packed per-mon facet data, `assignFacets`. |
| `MonExp` | Packed per-mon exp (`packedExpForMon`), level curve, level-up facet draws (`_processLevelUps`), public `getExp` / `getLevel` / `getExpAndLevelsFor*`, assigner-gated `assignExp`. Inherits `Facets` + `PackedTeamStore` because level-ups draw facets and team views need the lane helpers. Subclass hooks: `_assertExpAssigner`, `_monRegistrySize`. |
| `Quests` | Daily quest pool + packed predicate evaluator. Subclass hook: `_extract` (opcode dispatch implemented by the leaf since it sees Engine + all sub-systems). |

The leaf adds: the `onBattleEnd` orchestration (streak / quest / points / exp loop, plus a `_applyExpAndFacetDraws` walk that mirrors `assignExp` but with KO bitmap + streak + event packing), gacha rolling (`firstRoll`/`roll`/`_rollInto`), the per-(user, opponent) CPU phantom facet config, the `getTeams` variant that folds facet deltas in, the `_extract` quest opcode dispatch, and the wiring overrides for every subclass hook. With this split the leaf is ~750 LOC of integration and event-shape concerns; each base is independently auditable.

**Rolling.** Mon ids are sequential starting at 0 (`createMon` enforces `monId == monIds.length()`). Ids `[0, NUM_STARTERS)` (= 3) are *starter* mons.

- `firstRoll(uint256 starterId)` — one-shot per player. Caller picks `starterId ∈ {0,1,2}`; the contract guarantees that mon at slot 0 of the result and rolls `INITIAL_ROLLS - 1` (= 3) more uniformly from `[NUM_STARTERS, numMons)`. Free.
- `roll(uint256 numRolls)` — paid (`ROLL_COST` per roll, default 16 points). Uniform across the entire pool. Reverts `NoMoreStock` once the caller owns every mon.
- Linear-probing dedup keeps draws inside their window so `firstRoll`'s 3 random picks never land on a starter.

**Points / exp / facets storage.** All packed for gas:

```
playerData[address] (1 slot per player):
  bit 255       bonusAwarded (first-game-ever bonus claimed)
  bit 254       isWhitelistedAsOpponent (admin-set; replaces a separate mapping)
  bit 253       (reserved; formerly isHardCpu)
  bits 250-252  streakDay (1..STREAK_FLAT_BONUS_MAX; 0 = no streak yet)
  bits 224-249  (reserved)
  bits 192-223  lastQuestCompletedDay (uint32 calendar day)
  bits 160-191  lastSeenTimestamp (uint32 seconds; last battle of ANY kind — drives streak grace/reset)
  bits 128-159  lastFirstGameTimestamp (uint32 seconds; last streak-bonus game — gates the 24h cooldown)
  bits 0-127    pointsBalance (uint128)

packedExpForMon[player][monId / 16]: 16 mons × 16 bits each, capped at 65535.
facetData[player][monId / 16]:        16 mons × 16 bits each
                                       (bits 0-11 unlockedBitmap, bits 12-15 assignedFacetId).
```

Streak is timestamp-driven (not calendar-day): a battle qualifies for the streak bonus
when ≥24h have passed since `lastFirstGameTimestamp` (the last *bonus-earning* game). On a
qualifying battle the ratchet-vs-reset decision is measured from `lastSeenTimestamp` (the
last battle of *any* kind, advanced every battle): a gap >36h (`STREAK_GRACE_WINDOW`) of
genuine inactivity resets `streakDay` to 1, otherwise it ratchets up toward the cap of
`STREAK_FLAT_BONUS_MAX` (= 5). Splitting the two anchors is deliberate — measuring the
reset from the bonus anchor instead would strand players who play slightly more often than
once per 24h (their sub-24h plays advance no anchor, so the next day reads a phantom ~46h
gap and resets the streak forever).

Both per-mon mappings share the same 16-mon bucketing so `_applyExpAndFacetDraws` walks the team in one pass and coalesces SSTOREs by bucket.

**Battle rewards (`onBattleEnd`).** CPU side is short-circuited (no SSTOREs, no event). For each human side:

- Base points: `POINTS_PER_WIN` (2) on win, `POINTS_PER_LOSS` (1) otherwise.
- Streak flat: `streakDay` (1..5) added inside the parenthetical of both the points and per-mon-exp formulas. Only granted when the battle qualifies as "first of day" (≥24h since the last grant).
- Points formula: `(basePts + streakFlat) × gachaMult + firstGameEverBonus`. `gachaMult` is `×QUEST_REWARD_MULT` (= 2) when the active daily quest completes (winner-only, one-shot per day), else 1. `firstGameEverBonus` is `+FIRST_GAME_EVER_BONUS` (= 16), one-shot ever, applied *after* the multiplier.
- Per-mon exp formula: `(baseExp + streakFlat) × expMult`, capped at 65535. `baseExp` is `EXP_PER_SURVIVING_MON` (2) for alive slots, `EXP_PER_KOD_MON` (1) for KO'd slots.
- `expMult` stack: a flat `GAME_EXP_MULT` (×2) on **every** battle regardless of game type (PvP, CPU, hard or not), times `QUEST_REWARD_MULT` (×2) on quest completion. Max stack = ×4. (There is no longer a PvP-vs-CPU or hard-CPU exp distinction — the old client-set "hard CPU" flag let any user self-grant the bonus, so it was removed.)
- Level-ups (12-tier curve, capped at level 12 to match `TOTAL_FACETS`) trigger one facet draw per level crossed.

**Facets.** 12 systematically-derived stat tradeoffs across 4 stat groups (`HP`, `Atk`, `Def`, `Speed`). `_facetDef(facetId)` is pure — no constant table. Magnitudes are **boost-indexed**: the boost stat determines both the boost% and the cost% paid on the nerfed stat. HP/Atk/Def boosts are symmetric (+5% / -5%); speed boosts pay a heavier cost (+5% / -10%) so they can't cheaply break speed ties. The percentages live as `BOOST_PCT_*` / `COST_PCT_*` constants in `Facets.sol`. Unlocks are persistent per-mon; `assignFacets(monIds, facetIds)` is a free bulk re-assign that requires the caller to own every listed mon and the facet to be in the unlocked bitmap (`facetId == 0` clears). `GachaTeamRegistry.getTeams()` folds the active facet's delta into each mon's stats before returning, so by the time the Engine stores teams in `BattleConfig` they already reflect the boost/cost. `validateMon` no longer checks stat equality (the round-trip would always fail with facets applied) — moves and ability membership are still enforced.

**CPU opponent facets.** When fighting a whitelisted opponent (CPU), the human caller picks the CPU's team *and* its facet config in one call: `setOpponentTeam(opponent, monIndices, facetIds)`. Per-user-per-CPU storage (`opponentTeamFacetsPacked[opponent][phantomKey]`) keyed by the same `uint16(uint160(msg.sender))` phantom slot as the team. No ownership/unlock checks — any facet 0..12 is allowed. `getTeamsWithDeltas` short-circuits to this slot-indexed config when a side is `isWhitelistedOpponent`, so per-user CPU facet configurations stay isolated even when many users fight the same CPU.

**Quests.** Owner-managed `questPool` + a single `activeQuestPacked` slot (current day + active quest id). One quest is active per day, picked pseudorandomly via lazy rotation at the *end* of `onBattleEnd` so the current battle is judged against the pre-rotation quest. Each quest has up to `MAX_PREDICATES_PER_QUEST` (6) AND-composed predicates packed into one storage slot (41 bits each: `op` 5b, `cmp` 3b, `negate` 1b, `arg` 16b, `operand` 16b — total 246b + 3b count). Opcodes cover battle context (`TURNS`, `ALIVE_COUNT`, `ACTIVE_SLOT_INDEX`, `MON_KO_AT_SLOT`), team composition (`HAS_MON_ID`), per-mon progression (`MON_LEVEL`, `MON_FACET`), and live battle state (`MON_STATE` via `Engine.getMonStateForBattle`).

**Events.**

- `Roll(address indexed player, uint256[] monIds, uint256 pointsSpent)` — fires on both `firstRoll` (spend = 0) and paid `roll`.
- `GachaEvent(bytes32 indexed battleKey, uint256 p0Packed, uint256 p1Packed)` — one per battle, carrying both sides' packed payloads (CPU side is 0). Layout sized for `MONS_PER_TEAM` up to 8: points (bits 0-15), per-mon exp gain (bits 16-79, 8 lanes × 8b), per-mon facets unlocked this battle (bits 80-175, 8 lanes × 12-bit bitmap = 1 bit per facet id), `BONUS_*` flags (bits 176-183: `FIRST_ROLL` (bit 0) | `FIRST_GAME` (bit 1) | bit 2 reserved/formerly `HARD_CPU` | `QUEST` (bit 3)), combined exp multiplier (bits 184-191), outcome (bits 192-199: 0=loss, 1=win, 2=draw), `streakDay` (bits 200-202). Lanes saturate so a future tuning blow-up can't bleed into neighbouring fields.

### Storage Architecture

- `BattleData` and `BattleConfig` are stored per battle key (derived from player addresses)
- `MonState` tracks deltas from base stats (hpDelta, staminaDelta, etc.). The 5 stat deltas are written only by the inlined stat-boost path (see "Stat Boosts"); other deltas via `updateMonState`.
- Effects stored in per-mon mappings with stride-based indexing (64 slots per mon). Stat-boost sources reuse these same mappings under the `STAT_BOOST_ADDRESS` sentinel.
- Heavy use of bit packing for gas efficiency (KO bitmaps, effect counts, active mon indices)
- Battle mode is a `uint8` in `BattleConfig.battleMode` (mirrored to `BattleData.isTwoSlotMode`/`isMultiMode`). Slot-0 active lanes pack into `BattleData.activeMonIndex` (side 0 = low byte, side 1 = high byte); 2-slot modes add slot-1 lanes in `activeMonExt`. Multi's extra seats (p2/p3) live in `multiSeats[battleKey]` (`MultiSeatData`), written only when `battleMode == MULTI`.
- Transient storage used for per-transaction state (`battleKeyForWrite`, `tempRNG`, in-flight `PreDamage`)
- `GachaTeamRegistry`'s storage is the union of its abstract bases; each base owns its own mappings/constants so the leaf is integration-only. Reordering the inheritance list would shift slot layout — keep the order in `GachaTeamRegistry.sol` stable across deploys.

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
8. Run `python processing/generateSolidity.py` to regenerate `SetupMons.s.sol`
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

**2. `StandardAttack` + `move()` override** — for moves with side effects after damage (recoil, self-switch, self-status, multi-hit). Override the full `move(...)` signature and call `_move()`, which returns `(int32 damage, bytes32 eventType)`, then add custom logic:

```solidity
function move(
    IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex,
    uint256 targetBits, uint256 activesPacked, uint16 extraData, uint256 rng
) public override {
    (int32 damage,) = _move(engine, battleKey, attackerPlayerIndex, targetBits, rng);
    if (damage > 0) {
        engine.dealDamage(attackerPlayerIndex, attackerMonIndex, selfDamage); // recoil
    }
}
```

A move's target domain is client-facing metadata in `moves.csv`'s `TargetSpec` column (→ TS `Move.targetSpec`), not a Solidity declaration; `validateMoves.py` checks each move's `targetBits` behavior against it. The player's chosen target arrives as `targetBits` (resolved against `activesPacked` via `TargetLib`); the old `targetSpec()` / `extraDataType()` / `ExtraDataType` selector layers have been removed.

**3. Custom `IMoveSet`** — for complex conditional moves (variable power, healing, stat manipulation, reading opponent state). Implement the `IMoveSet` functions directly (`move` + metadata getters + `getMeta`). Deal damage via `engine.dispatchStandardAttack` / `dispatchCustomAttack` (passing `targetBits`); `AttackCalculator._calculateDamage()` now just delegates to `dispatchCustomAttack`. Store dependencies as `immutable`.

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
- **Shared utility effects** (`src/effects/`): Deployed once, used by many contracts. (e.g., `StaminaRegen` for per-turn recovery). NOTE: stat modifiers are **not** an effect — they are inlined Engine functions (`addStatBoost`/`removeStatBoost`/…); see "Stat Boosts" above.
- **Mon-local effects** (`src/mons/<monname>/`): Abilities or move-effect hybrids that only apply to one mon. These live in the mon's directory, not in `src/effects/`.

To implement a new effect:
1. Extend `BasicEffect` (or `StatusEffect` for status conditions)
2. Override the relevant lifecycle hooks (`onRoundEnd`, `onAfterDamage`, `onPreDamage`, …) — each receives `activesPacked` for local slot resolution via `TargetLib`
3. Return a bitmap from `getStepsBitmap()` indicating which hooks to call
4. Return `(updatedExtraData, removeAfterRun)` from hooks — use `extraData` (bytes32) to carry state between turns (counters, degrees, flags)
5. Shared effects are injected into moves/abilities via constructor parameters at deploy time — there is no runtime effect registry

## Build & Deploy Pipeline

### Processing Scripts (Python 3.11+)

```bash
python processing/validateMoves.py          # Validate contracts vs CSV
python processing/generateSolidity.py       # Generate SetupMons.s.sol
python processing/generateSetupCPU.py       # Generate SetupCPU.s.sol from cpu-teams.json
python processing/deploy.py --testnet       # Full deployment (forge scripts + codegen)
python processing/deploy.py --mainnet       # Production deployment
```

Python dependencies: `numpy`, `pexpect`, `pillow` (managed via `uv`, see `pyproject.toml`)

### Transpiler (Solidity to TypeScript / Rust)

Converts Solidity contracts to TypeScript for local battle simulation:

```bash
# Transpile all contracts
python3 transpiler/sol2ts.py src/ -o transpiler/ts-output -d src --emit-metadata

# Run transpiler tests
cd transpiler && npm install && npx vitest run
```

**Rust target (sim performance).** The same front-end also drives a Rust
backend (`codegen_rs/`, native ints instead of bigint — see
`transpiler/codegen_rs/README.md`):

```bash
python3 -m transpiler src/ --target rust                 # emit transpiler/rs-output (cargo workspace)
cd transpiler/rs-output && cargo build --release          # engine + runtime + strategies (+ its bins)
CHOMP_ROOT=$(pwd)/../.. ./target/release/arena --games 6000        # whole-game batches, win-rate table
CHOMP_ROOT=$(pwd)/../.. ./target/release/trace --games 6000 --narrate 0   # trace analysis + greedy counterfactual
```

The full engine, all mons/effects, and the three CPU strategies (hard,
greedy, override) are transpiled/ported. The arena is now a **standalone,
pure-Rust binary** (`chomp-strategies`' `arena`/`trace` bins): it loads the
roster from `drool/*.csv` + `src/mons/*.json` at runtime and runs whole games
natively (~2,000 games/s at 8 threads, deterministic across thread counts).
The stacks are DECOUPLED — the Rust side was ported move-for-move against TS
and then cut loose; it may diverge freely (including its rng stream and CPU
decisions) as the prototyping substrate, and port-backs to the TS game carry
no bit-identicality requirement. Emission is allowlisted in
`transpiler-config-rust.json`. `rs-output/` is regenerated (gitignored);
hand-written crates live in `transpiler/{runtime-rs,strategies-rs}`. The
former bun↔Rust FFI seam (`chomp_run_games`, the `ffi` crate, and
`scripts/batch_benchmark.ts`) was removed once the pure-Rust arena replaced
it; the verification-era machinery (golden-vector suites, replay fixtures,
the drive-mode adapter, lockstep gates) lives in git history if parity ever
needs re-proving. The TS arena driver (`sims/src/arena/game.ts`) remains as
the port-back reference.

**Known limitation — TODO when a second codebase needs it.** The transpiler hardcodes three TS namespace names (`Enums`, `Structs`, `Constants`) for type-only Solidity files. File-type detection is content-based (a file with only enums maps to the `Enums` namespace regardless of filename), but the *namespace name itself* is fixed, and only structs are tracked per source path. A codebase that splits types across multiple files (e.g. `PoolStructs.sol` + `OrderStructs.sol`, or `Errors.sol`) would produce colliding imports. To generalize: add `enum_paths` / `constant_paths` to `transpiler/type_system/registry.py` mirroring `struct_paths`, derive the namespace name from each source file's basename, and have `imports.py:_generate_module_imports` emit one `import * as <Basename>` per actually-referenced source module instead of three blanket imports.

### Deployment Order

1. `EngineAndPeriphery.s.sol` - Engine, type calculator, `SignedCommitManager`, `GachaTeamRegistry`, `SignedMatchmaker`, CPU host, `SimplePM`, shared effects
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
| `drool/moves.csv` | Move data: Name, Mon, Power, Stamina, Accuracy, Priority, Type, Class, DevDescription, UserDescription, InputType, UnlockLevel, Constants, TargetSpec |
| `drool/abilities.csv` | Ability assignments: Name, Mon, Effect |
| `drool/types.csv` | Type effectiveness chart |

CSV-to-code mapping notes:
- **Priority** in `moves.csv` is a signed offset from `DEFAULT_PRIORITY` (3). So `0` = default, `1` = faster, `-1` = slower.
- **Power** can be `?` for variable-power custom moves (Tier 3/4 implementations)
- **InputType** (`none` / `self-mon` / `opponent-mon` / `mode-select`) is client-facing metadata for the move-input UI (generated into the TS `MoveInputType`); it no longer maps to any Solidity enum
- **TargetSpec** (kebab-case: `opponent-slot` / `self-only` / `none` / `any-other-slot` / `ally-slot` / `any-subset`; blank = `any-other-slot`) is the authoritative client-facing target domain (generated into the TS `MoveTargetSpec`) — there is no Solidity enum. `validateMoves.py` validates it behaviorally: a slot-targeting spec must consume the `targetBits` nibble in `move()`, self-only/none must ignore it
- **Type2** is `"NA"` for single-type mons

## Known Issues / Gotchas

- If a move forces a switch before the other player acts, the new mon will still try to execute its move (Engine skips if stamina is insufficient)
- If an effect calls `dealDamage()` and triggers `AfterDamage`, it can cause infinite loops - avoid dealing damage in `onAfterDamage` hooks
- RNG reuse: `StandardAttack` uses the same RNG for both accuracy and effect chance, making them correlated rather than independent
- Malicious p0 can modify mon moves between commit and battle start - mitigate via team registry or adding move indices to integrity hash
- `MAX_BATTLE_DURATION` is 1 hour, enforced in `Engine.end()` (once elapsed, anyone can end a stale battle, awarding p0). There is no external validator anymore and no per-turn timeout currently wired in — `ValidatorLogic.validateTimeoutLogic` exists but is dormant
- DefaultMatchmaker (deprecated, test-suite-only) leaks/strands MappingAllocator pool keys on re-proposals and open-proposal cycles — documented won't-fix in its contract header; do not promote it back to production without fixing

## Gas Optimization Notes

- Storage bit-packing throughout (BattleData, BattleConfig, KO bitmaps, effect counts)
- Batch context structs (`BattleContext`, `DamageCalcContext`, `BattleEndContext`, `MoveMeta`) to reduce external calls / SLOADs
- Effect step bitmaps avoid calling effects at steps they don't use
- `MappingAllocator` for efficient storage slot management
- Transient storage for per-call state to avoid unnecessary SLOADs/SSTOREs
- Optimizer runs set to max (4294967295) with via-IR for aggressive optimization
