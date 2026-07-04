# Phase 3 — effects, moves, abilities: full dispatch — DONE

Status: complete. All 13 mons + 8 effects + StandardAttack transpile and
compile; dispatch.rs (23 fns over IMoveSet/IEffect/IAbility) routes by
ContractId; deploy_all mirrors the TS factories' dep wiring. Lockstep
gate: 10 scenarios / 60 turns bit-identical, including burn / frostbite /
zap / sleep status effects, the Overclock battlefield effect,
PreemptiveShock switch-in ability activations, and stat-boost
interactions. Mutation-verified.

Phase 2 landed the World model with Engine as the only stateful contract
and interface dispatch stubbed. Phase 3 transpiles every effect / move /
ability contract and replaces the stubs with generated dispatch tables, so
scripted battles can use REAL moves (StandardAttack subclasses, custom
IMoveSets) and status effects. Phase 4 is then "turn the roster on" —
same machinery, more scenarios.

## Recon facts (verified against src/ and ts-output/)

- Scope: ~80 contracts. 59 mon files (13 mons × 4 moves + 1 ability +
  shared libs), 8 effects (StaminaRegen, Overclock, 6 status), plus
  StandardAttack and small libs. The TS oracle already transpiles ALL of
  them (`ts-output/mons/**`, `factories.ts`).
- Everything is a SINGLETON. Each move is its own contract class baking
  ATTACK_PARAMS into its constructor (`BullRush is StandardAttack`), so
  the World model's one-state-per-contract shape extends unchanged — no
  per-instance keying needed.
- Wiring is name-keyed dependency injection (ts-output/factories.ts:
  `BullRush: { deps: ['TypeCalculator'] }`). Constructor args are the dep
  contract addresses (typed as interfaces) plus literals.
- Addresses in the TS sim: `hash*31 + charCode` over the class name PLUS a
  generation counter — order-dependent, NOT reproducible from the name
  alone. The lockstep fixture must therefore EXPORT the address book, and
  the Rust replay must register it. (Behavior depends on address equality
  — StatusEffectLib's one-status flag, EffectInstance.effect compares —
  so the book has to match the oracle exactly.)
- Inheritance chains that must flatten: `X is StandardAttack is IMoveSet,
  Ownable`; `XStatus is StatusEffect is BasicEffect is IEffect`; abilities
  `is IAbility` (+ BasicEffect for the hybrid pattern).
- `super.f()` IS used (status effects call `super.onApply/onRemove/
  shouldApply`) — flattening needs super-method resolution, not just
  override-wins.
- lib/Ownable is assembly-slot based (solady-style) — not transpilable and
  not needed: owner-gated setters are never called in sims. Constructors
  DO call `_initializeOwner(owner)`, which must become a no-op (not a
  panicking stub, or every move's `construct` would panic).

## Design

### 1. Automatic inheritance flattening

Replace the hand-written `flatten` config with automatic transitive
flattening for every emitted `contract` (config stays as an override):

- Merge state vars (base-first, declaration order — matches storage
  layout and the TS class-field order) and functions from the linearized
  base chain; a child override shadows the base function of the same
  (name, arity).
- Shadowed base functions still emit, renamed `{name}__in_{Base}`;
  `super.f(...)` at a call site resolves against the linearization and
  emits a direct call to that renamed fn (same module, same `self_`/world
  state — Solidity super is static dispatch).
- Constructors chain: the child's `construct` evaluates base-constructor
  args from its inheritance-specifier header, runs base constructor
  bodies (base-first), then its own body, all against the merged
  `<Name>State`. Interfaces contribute nothing; `Ownable` contributes its
  (skipped) machinery — see noopCalls.
- needs_world / overloads / param-lowering already resolve through
  flatten_bases; they pick the linearization up for free once
  symbols.configure_world computes it automatically.

### 2. Deployment: address book + generated init

- `world.rs` gains `pub struct AddressBook { pub <Name>: Address, ... }`
  (one field per emitted stateful/dispatchable contract) and
  `pub fn deploy_all(world: &mut World, book: &AddressBook)` which:
  - constructs every contract state in dependency order (deps from
    constructor parameter types that are interface-typed, mirroring
    factories.ts), passing dep ADDRESSES from the book;
  - fills `world.contract_ids: rt::Mapping<Address, ContractId>` (a
    generated `#[repr(u16)] enum ContractId`), the reverse map dispatch
    uses.
- The lockstep generator exports the TS `contractAddresses` book into the
  fixture; the replay test loads it into an AddressBook by name. The
  Phase-5 arena assigns its own book (any unique addresses).

### 3. Dispatch tables

- New config key `dispatchInterfaces`: `["IMoveSet", "IEffect",
  "IAbility", "IRuleset", "IEngineHook"]`.
- `_emit_interface_dispatch` for these emits
  `crate::dispatch::{Iface}_{method}(world, target, args...)`.
- Generated `dispatch.rs`: per interface method, match on
  `world.contract_ids.get(&target)` → module call, wrapped in the same
  msg.sender frame push used for alias calls (sender := current contract,
  current := target). Unknown address → panic printing the address (loud,
  like every other unfinished edge).
- Only contracts that implement the interface get arms; the discriminant
  comes from the contract's base chain (post-linearization).

### 4. Config additions

- `noopCalls`: bare-name calls dropped as no-ops (vs stubCalls' loud
  panic): `_initializeOwner`, `_guardInitializeOwner`. Rationale: called
  on the constructor path of every move; ownership is dead state in sims.
- `includeFiles` grows to `effects/**`, `mons/**`, `moves/StandardAttack
  .sol`, `moves/StandardAttackStructs.sol`, `lib/StatusEffectLib` path,
  mon libs. `statefulContracts` becomes derived (any contract with state
  vars after flattening) rather than hand-listed; config remains as an
  override for edge cases.

### 5. Gate (Phase 3 exit)

Extend `scripts/generate_battle_vectors.ts` with contract-move scenarios
(mons whose move slots are CONTRACT addresses, not inline-packed):

- burn + frostbite application and per-turn chip damage (SetAblaze,
  DeepFreeze), including the stat-boost interactions (burn halves attack
  via the inlined stat-boost path);
- sleep / zap turn-skip branches (RNG-gated wake);
- an ability that registers an effect on switch-in (Tinderclaws or
  PreemptiveShock);
- a StandardAttack-with-EFFECT move (probabilistic status application —
  correlated-RNG semantics come along for free).

Fixture additionally carries `addressBook: { name: address }` and each
mon's move slots referencing addresses from the book. Same replay loop,
same field diffing; mutation-verify again.

## Sequencing

1. symbols: automatic linearization + merged state/functions + super
   resolution + derived statefulContracts.
2. contract.py: constructor chaining; function.py: `{name}__in_{Base}`
   emission for shadowed bases.
3. Config: includeFiles sweep, noopCalls; compile-error loop over
   effects/ then mons/ (expect a long tail of small expression-layer
   gaps, same discipline as Phase 2).
4. world.rs: AddressBook + ContractId + deploy_all + contract_ids.
5. dispatch.rs generation; flip IMoveSet/IEffect/IAbility from stubs.
6. Vector generator scenarios + replay-side address book; gate green +
   mutation check.
