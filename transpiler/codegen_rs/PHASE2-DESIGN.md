# Phase 2 design: stateful contracts, the World model, and dispatch

Goal state (per PLAN): the arena runs CPU battles on the Rust engine.
Phase 2 lands the engine core (storage + turn loop) behind a battle-replay
lockstep gate; Phase 3 adds effect/move/ability dispatch enums; Phase 5 the
bun:ffi batch API. This note fixes the architecture those phases share.

## Scope truth: mirror the TS sim, not all of src/

The TS sim (the validated oracle) skips: DefaultValidator + DefaultRuleset
(battles run the engine's INLINE validator path via `validator == address(0)`
and the `INLINE_STAMINA_REGEN_RULESET` sentinel), all matchmakers and commit
managers, the whole gacha game-layer, and `cpu/` (arena CPU strategies are
sim-side TS, not transpiled). `sims/src/harness.ts` is the drive surface:

- `makeSimContext` -> `new Engine(monsPerTeam, GAME_MOVES_PER_MON)` (+ DI
  container for effects/moves), harness-owned team registry + matchmaker
  MOCKS at fixed addresses, `IRandomnessOracle` = transpiled
  DefaultRandomnessOracle, engine `_block.timestamp` advanced per turn.
- `startBattle` -> `engine.startBattle(Battle{... validator: 0, ruleset:
  INLINE_STAMINA_REGEN_RULESET, moveManager: 0xbeef ...})` with
  msg.sender = matchmaker.
- `executeTurn` -> `engine.executeWithMoves(...)` with msg.sender =
  moveManager; snapshot = turnId/winnerIndex/actives/per-mon
  hpDelta/staminaDelta/isKnockedOut (sentinel-normalized).

Damage-only lockstep needs NO external move/effect dispatch: harness mons
can use INLINE packed move slots (upper-bits-set uint256), which the engine
routes internally (MoveSlotLib + dispatchStandardAttack).

## The World model

Cross-contract calls in Solidity are reentrant (Engine -> effect ->
Engine.dealDamage), which rules out `&mut self` methods calling each other.
The standard sim answer, adopted here:

- Every transpiled contract becomes a MODULE of free functions (exactly like
  libraries today); a stateful contract additionally gets a generated
  `<Name>State` struct holding its state vars.
- A generated `World` struct owns all contract states plus the call
  environment:

```rust
pub struct Env { pub msg_sender: Address, pub tx_origin: Address,
                 pub current_contract: Address,
                 pub block_timestamp: U256, pub block_number: U256 }
pub struct World {
    pub env: Env,
    pub addresses: rt::AddressBook,        // name <-> Address, loaded from the
                                           // TS harness dump (addresses leak
                                           // into state, e.g. stat-boost keys,
                                           // so they must MATCH the oracle)
    pub ext: Box<dyn ExternalCalls>,       // harness mocks (team registry,
                                           // matchmaker) — generated trait
    pub Engine: crate::Engine::EngineState,
    // stateless transpiled contracts have no field
}
```

- Functions that (transitively) touch state, env, or world-routed calls take
  `world: &mut World` as their first parameter (`needs_world` is a
  call-graph fixed point computed in symbols; pure math libs keep their
  Phase-1 signatures).
- **No long-lived borrows of world**: every state access emits the full path
  (`world.Engine.battleConfig...`) per use; sequential NLL borrows make
  reentrancy a non-issue.

## Storage access rules

- State vars -> `world.<Contract>.<var>`.
- Mappings -> `rt::Mapping`; value reads `.get(&k)` (clone; Solidity
  storage->memory copies), place contexts `.get_mut(&k)` (materializes the
  zero value — exactly Solidity's zero-initialized storage).
- `X storage y = m[k];` locals: bind the key once (`let __k_y = k;`) and
  SUBSTITUTE `y` at every use with `world...m.get_mut(&__k_y)`. Conditional
  storage locals (`t == 0 ? a : b`) hoist the condition and substitute the
  if-expression per use. This is the same alias-map machinery Phase 1 built
  for memory params.
- Assignments/compound-ops whose LHS is a mapping place hoist the RHS to a
  temp first (`let __rhs = ...;`), avoiding overlapping `get_mut` borrows.
- Calls to world-taking functions hoist ALL arguments to temps inside a
  block expression (`{ let __a0 = ...; F(world, __a0) }`) so argument
  evaluation never overlaps the `&mut world` being passed.
- `transient` state vars are ordinary fields plus a generated
  `World::reset_transient()`; the harness calls it at transaction
  boundaries (mirrors the TS proxy's `_resetTransient`).

## Interface values and dispatch

Interface-typed values are Addresses EVERYWHERE (params included — the
Phase-1 `&mut dyn` convention is retired; some interface params get stored
or compared, so they must keep their identity). A method call THROUGH an
interface-typed expression dispatches by configuration:

1. `interfaceAliases` (IEngine->Engine, ITypeCalculator->TypeCalculator,
   IRandomnessOracle->DefaultRandomnessOracle): direct module call
   `Engine::method(world, args...)` — faithful while each alias has exactly
   one live instance (true in the sim harness), replaced by address-keyed
   enum dispatch in Phase 3 where multiple impls exist (moves/effects).
2. `externalInterfaces` (ITeamRegistry, IMatchmaker): routed to the harness:
   `world.ext.ITeamRegistry_getTeams(target, args...)`. The `ExternalCalls`
   trait is generated from the call sites actually emitted.
3. Anything else: loud `unimplemented!` (unchanged).

Dispatch shims own the msg.sender frame: save env, set
`msg_sender = current_contract`, set `current_contract = target`, call,
restore. Internal (same-module) calls never touch the frame — matching
Solidity internal-call semantics.

## Yul: known-block registry

Engine's 8 assembly sites are 3 shapes; no Yul->Rust codegen:
- whole-slot MonState sentinel clear -> `if *ms != MonState::default() &&
  *ms != CLEARED { *ms = CLEARED; }` (CLEARED = 7 sentinel deltas + false
  bools == PACKED_CLEARED_MON_STATE by construction);
- `mstore(<arr>, <len>)` memory-array shrink -> `arr.truncate(rt::usize(len))`;
- `_packBatchPayload` event-byte packing -> hand-ported (events are
  sim-irrelevant but the port is cheap: winner ++ low-19-bytes-BE of each
  entry).
Unknown assembly stays a loud `unimplemented!`.

## Lockstep gate (Phase 2 exit) — DONE

TS side: `scripts/generate_battle_vectors.ts` drives `sims/harness.ts` over
scripted battles (fixed teams with inline moves, fixed per-turn move
indices + salts) and dumps per-turn `TurnSnapshot`s to
`differential-rs/fixtures/battle_replay.json`. Rust side:
`differential-rs/tests/battle_replay.rs` replays the same script through
`World` (ITeamRegistry mocked via `world.ext`, matchmaker approval set
directly, `reset_transient()` per tx) and diffs every field per turn,
reporting divergence as `[scenario turn N] field, left vs right`.

Status: 5 scenarios / 35 turns bit-identical (1v1 basic, type matchups +
special class + priority, speed-tie RNG coin flips, 2v2 voluntary + KO-
forced switches, 3v3 mixed with no-op regen turns). Gate is mutation-
verified (corrupted expectation fails with the right scenario/turn/field).

## Sequencing

1. symbols: needs_world fixed point, world-contract/alias/external config. ✓
2. emitters: world param + state paths + place mode + storage-local
   substitution + env + dispatch + arg/RHS hoisting. ✓
3. world.rs + ExternalCalls generation; Yul known-block registry. ✓
4. Engine.sol compiles; Phase-1 gate updated (signature changes) and green. ✓
5. Lockstep runner + scripted battles; first-divergence loop until clean. ✓
   (clean on first run — the Phase-0/1 value-layer gates did their job)
