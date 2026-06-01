# Move-VM Design Sketch

Builds on [`MOVE_VM_RESEARCH.md`](./MOVE_VM_RESEARCH.md). **Premise:** `StatBoosts` and `AttackCalculator`
are absorbed into the engine as syscalls (this clears the single biggest dependency gate — see the
research doc §"real ceiling"). Under that premise, this sketches what the move VM looks like.

**Goal:** a move/ability becomes a **VM program** (data) run by a **fixed interpreter** whose only
side-effects are engine syscalls. Then the entire battle is ZK-provable by proving *one interpreter*
over committed program-data + inputs, instead of proving arbitrary user EVM bytecode.

> ⚠️ **Read §7 (Validation verdict) first.** Transpiling the 12 hardest/representative moves to the v0
> ISA below exposed that `DAMAGE`/`STAT_BOOST` are **not** clean macro-opcodes — they're 190-/635-line
> stateful subsystems, and the RNG is a **keccak chain**, not a sequential entropy pull. The "restricted
> VM" is honest only for the ~25–35% **state-machine** slice; for the damage/boost/status majority it
> requires a general `KECCAK` + subsystem-opcodes. §8 explores the **no-keccak** variation that could fix
> this; §9 details what it buys in the 1-tx CPU flow.

---

## 1. Shape

- A move/ability = a **program blob** (the VM's bytecode), stored in the registry / committed into the
  battle hash — *not* a deployed Solidity contract.
- The engine hosts a **fixed interpreter** that loads and runs a program. Side-effects happen **only**
  through engine syscalls (the "engine-only callbacks" invariant — which also guarantees deterministic
  replay, the property the 1-tx flow already leans on).
- For ZK: the interpreter is the circuit; the program + the battle's input vector + the start/end state
  commitments are the public inputs. Arbitrary user moves are handled because we prove the *interpreter*,
  not each move's bytecode.

## 2. Instruction set (ISA)

- **ALU:** add/sub/mul/div/mod; **256-bit *wrapping* mul/exp** (StatBoosts depends on intentional
  overflow + a downstream clamp); bit-ops (and/or/xor/shl/shr/mask); signed-`int32`-aware comparisons;
  **keccak** as a first-class op (RNG stream-splitting + KV-key derivation — the dominant in-circuit cost).
- **Memory:** a small fixed register file + bounded scratch memory (moves build `uint32[5]` stat arrays,
  `StatBoostToApply[]`, `DamageCalcContext`). Statically sized.
- **Control flow:** conditional branch; **bounded loops** with a static iteration cap (= max effects/mon,
  max team size). No unbounded loops, no recursion.
- **Syscalls (the ~21 engine ops as opcodes):**
  - *reads:* `getMonValueForBattle`, `getMonStateForBattle`, `getMonStatsForBattle`, `getEffects`,
    `getEffectData`, `getGlobalKV`, `getMoveDecisionForBattleState`, `getActiveMonIndexForBattleState`,
    `getTurnIdForBattleState`, `getKOBitmap`, `getTeamSize`, `getDamageCalcContext`, `getPreDamage`/`tempRNG`.
  - *writes:* `updateMonState`, `dealDamage`, `addEffect`/`removeEffect`/`editEffect`, `setGlobalKV`,
    `switchActiveMon`, `setPreDamage`.
- **Macro-opcodes (now engine features):** `DAMAGE` (AttackCalculator) and `STAT_BOOST` (StatBoosts) —
  single opcodes the interpreter implements natively, proven once rather than re-derived per move.

## 3. Effect lifecycle

- A program declares its `stepsBitmap` — which of the 10 `EffectStep`s it hooks (`OnApply`, `RoundStart`,
  `RoundEnd`, `OnRemove`, `OnMonSwitchIn`, `OnMonSwitchOut`, `AfterDamage`, `AfterMove`,
  `OnUpdateMonState`, `PreDamage`).
- The engine's existing scheduler invokes the program at each hooked step with
  `(battleKey, targetIndex, monIndex, extraData)`; the program returns updated `extraData` (+ remove flag).
- **Persistent state** = the per-effect `bytes32 extraData` (threaded across turns) + `globalKV`. The VM
  never touches storage directly — only via the read/write syscalls.

## 4. Hard cases → explicit opcodes or escape hatch

| Case | Handling |
|---|---|
| **Gachachacha** (attacker-context swap) | a `DAMAGE`-variant opcode taking an explicit attacker side ("compute damage as side X") |
| **HardReset** (global-singleton, cross-team, RNG switches) | global effect (`targetIndex 2`) + cross-team syscalls + a `bytes32` state machine. *The explicit "can the VM express this?" stress test.* |
| **ChainExpansion** (per-switch summon) | `OnMonSwitchIn` hook + a charge counter in `extraData` |
| **Tinderclaws / Somniphobia** (read opponent's committed move) | the existing `getMoveDecisionForBattleState` syscall — but note this makes the player's move-decision a *committed input* to the proof |
| **anything else** | a **`kind: custom` escape hatch** — stays a native EVM contract and simply isn't ZK-provable yet. First tail candidates: the above. |

## 5. Phased plan

- **Phase 0 — prerequisite (valuable independent of ZK):** inline `StatBoosts` + `AttackCalculator` into
  the engine as syscalls; migrate the ~12 StatBoosts callers + the damage callers. Enforces the
  engine-only-callbacks invariant for the whole stat system.
- **Phase 1 — ISA + off-chain interpreter:** define the instruction set and build a *reference*
  interpreter off-chain (extend `transpiler/`'s runtime — it already lowers arithmetic / keccak /
  control flow).
- **Phase 2 — transpile + equivalence:** auto-transpile the ~85% (trivial + moderate) moves to VM
  programs; validate by running each VM program against its Solidity move and diffing state, using the
  existing per-mon test suites as oracles.
- **Phase 3 — on-chain interpreter:** the engine runs VM programs for migrated moves; the hard ~15%
  stays behind the `kind: custom` escape hatch.
- **Phase 4 — ZK:** the interpreter as a circuit; prove battles; settle with proof + final-state commit.

## 6. Gates (de-risk on the subset before scaling)

1. **`STAT_BOOST` + `DAMAGE` as economical circuit opcodes** (incl. the unchecked-wrap exponentiation).
   **Prototype these FIRST** — 12+ moves and the whole stat system route through them; if they can't be
   proven cheaply the VM is dead on arrival regardless of ISA elegance.
2. **keccak/turn cost in-circuit** — the dominant driver (RNG splitting + every KV key). Measure on the
   subset; decide "how many keccaks/turn can we afford."
3. **Escape-hatch tail** — confirm it stays small and that those moves being non-ZK-provable is acceptable.

**Prototype subset** (from the research): `aurox + ekineki + embursa` + **`HardReset`** as the stress test
— exercises every feature class (trivial wrappers, RNG branching, globalKV state machines, the
NineNineNine turn-counter, Tinderclaws's intent-read, UpOnly/HoneyBribe as StatBoosts clients) plus the
hardest control-flow shape.

---

## 7. Validation verdict (transpiling the 12 hardest moves to the v0 ISA)

We transpiled the 8 hardest + 4 representative moves to the ISA above and checked each against source.
The optimistic framing of §§1–6 does **not** survive contact with the code:

- **The "restricted VM" is honest only for the ~3/12 state-machine slice** (≈25–35% of all moves):
  bit-packed effect state, countdown timers, KO checks, global-singleton cross-team effects
  (HardReset, ActusReus, RiseFromTheGrave). These transpile cleanly and ~mechanically. This is a real,
  useful design space — the *novel control-flow* moves a user most wants to author.
- **The damage/boost/status majority (~80%) breaks "restricted."** It is served only by admitting:
  - `DAMAGE` — not a primitive: `AttackCalculator` is ~190 LOC (accuracy/crit/volatility/variance + type
    calc + `dealDamage`).
  - `STAT_BOOST` — not a primitive: `StatBoosts` is **635 LOC** — iterates the full effect array, unpacks
    5-stat packed words, reads/writes a globalKV snapshot, **unchecked-wrapping exponentiation**, clamps.
  - a **general `KECCAK`** — the v0 ISA pretended keccak was "key-derivation only," but the RNG is itself
    keccak-chained (below). A general hash opcode is not a restricted VM.
- **The keccak is load-bearing decorrelation, not lazy stream-splitting** (this kills the easy
  player-entropy assumption): `AttackCalculator.mixRngForAttacker = keccak256(rng, attackerIndex)` exists
  so mirror mons don't roll identical accuracy/crit (`:17`); the effect-trigger reroll
  `keccak256(rng)` (`:34`) decorrelates effect procs from damage rolls.
- **Mechanical transpilation is fatally ambiguous for damaging moves:** `keccak256(rng)` (fork RNG) and
  `keccak256(prefix, idx)` (derive a KV key) are *syntactically identical* — a transpiler cannot tell
  them apart. So a Sol→VM pass is mechanical only for the control-flow tail; for damage/boost/status it
  degenerates to "recognize the three blessed libraries and emit macro calls."

**Strategic fork (unchanged by the prototype's outcome):**
1. **Scope the VM to the state-machine tail** + leave damage/boost/status as native EVM behind a stable
   ABI. Honest and ships, but the common moves stay un-provable.
2. **Rewrite the three shared subsystems** (`AttackCalculator`, `StatBoosts`, `StatusEffectLib`) to a
   circuit-friendly form — the **no-keccak variation** below — so the majority becomes provable. Real
   project, real correctness risk.

## 8. No-keccak variation (the thing that makes ZK economics work)

keccak is the dominant in-circuit cost. Both keccak sources are removable **without losing the property
they provide**:

- **RNG → a player-committed entropy *stream*; each roll pops the next word.** This *preserves*
  decorrelation **by construction**: p0's accuracy/crit/vol/effect rolls pop distinct words, p1's pop
  later words, so mirror mons pull *different* entropy natively — `mixRngForAttacker` and the
  effect-reroll keccaks become unnecessary (their purpose, not their mechanism, is what matters).
  Requirement: a **fixed, deterministic consumption order** (engine logic already determines how many
  rolls each move makes), so the off-chain sim and the circuit consume the stream identically. Scope this
  to the CPU/ZK path; PvP keeps its keccak RNG (it isn't proven anyway).
  - *Cost:* rewrite `AttackCalculator` to sequential pops and re-validate, against the existing
    damage-determinism + mirror-match `forge` tests, that decorrelation survives bit-for-bit.
- **KV keys → direct bit-packing, not keccak.** Keys namespace globalKV from a *tiny* input space
  (a constant prefix + playerIndex 0–1 + monIndex 0–5). Assign each namespace a small id and pack
  `(nsId << k) | indices` into the uint64 key — collision-free, deterministic, zero hashing. Replaces
  `StatusEffectLib.getKeyForMonIndex` / `StatBoosts._snapshotKey` / every `_key()` helper.
- **State commitment → a ZK-friendly hash (Poseidon), not keccak.** The circuit proves a parallel
  Poseidon-Merkle state (start/end commitments + read/write paths); the EVM keeps its keccak storage only
  for the cheap on-chain verify+settle. No keccak inside the proven computation.

**Result:** a **keccak-free native circuit.** `DAMAGE`/`STAT_BOOST` stay large but become *pure
arithmetic/state* subsystems (the 635-LOC boost aggregator is mostly mul/exp/array-walk — provable), and
the dominant cost (Gate 2, keccak/turn) is **eliminated**. That is the difference between an intractable
zkEVM-scale proof and a tractable app-specific one. The smallest experiment that settles whether the
decorrelation survives the rewrite: **port `VolatilePunch` end-to-end and run it against the existing
damage tests** (§6 prototype).

## 9. Gains in the 1-tx CPU batched flow (the only place this pays)

The CPU 1-tx flow (shipped: `CPUMoveManager.executeGame`, ~2.88M for a 26-turn game) is the unique flow
where ZK fully collapses — no commit-reveal interactivity, and the player **already executes the whole
game off-chain** to compute moves, so they already hold the trace and only need to *also* prove it.

With the no-keccak native circuit:

| | today (1-tx, on-chain exec) | with no-keccak ZK |
|---|---|---|
| on-chain execution | ~2.88M (run 26 turns) | **~0.5M** = proof verify (~250–300k) + final-state write (~200–300k) |
| calldata / DA | full move + per-turn salt stream | a proof + start/end + input-commitment (moves need not be posted, only committed) |
| off-chain | player simulates (free) | player simulates **+ proves** — now cheap: app-specific, **no keccak**, ~arithmetic + Poseidon-Merkle |

So the per-game gain is **~2.4M on-chain** plus a DA cut, against an off-chain proving cost that the
no-keccak circuit drops from "dwarfs the gas" (zkEVM) to "seconds of player-side compute." This is the
case — single-player, gas genuinely costs money — where ZK plausibly nets *positive*, conditional on the
two open gates: (1) `STAT_BOOST`/`DAMAGE` proving cost even keccak-free, and (2) the `VolatilePunch`
prototype confirming decorrelation survives the entropy-stream rewrite. PvP gains nothing here — its
move-hiding floor is untouched and it keeps native EVM + keccak RNG.
