# Move-VM Feasibility Research

**Question:** could C.H.O.M.P.'s user-created moves/abilities be re-expressed as programs for a
restricted, circuit-friendly **"move VM"** — a fixed instruction set whose only side-effects are calls
back into the battle engine — so the whole battle becomes ZK-provable via one interpreter circuit
instead of proving arbitrary EVM bytecode (the current blocker to cheap ZK)?

**Method:** parallel per-mon catalog of every custom `.sol` move/ability across all 13 mons (engine ops,
computation, control flow, reentrant reads, external deps, effect-persistence, expressivity hardness),
then an adversarial synthesis. Findings verified against source on the load-bearing claims.

---

## Verdict (TL;DR)

A **pure fixed-op VM is insufficient.** The realistic target is a small **bounded-Turing core**:

- a fixed ALU — add/sub/mul/div/mod, bit-ops, **keccak as a first-class op**, and **256-bit *wrapping*
  mul/exp** (StatBoosts relies on intentional overflow + a downstream clamp);
- **bounded loops** with a static iteration cap (effect-array scans, KO popcount, team scans — no
  unbounded loops, no recursion);
- **scratch memory** (moves build `uint32[5]` stat arrays, `StatBoostToApply[]`, `DamageCalcContext`);
- **persistent effect state** — `bytes32 extraData` per instance threaded across turns (~30% of items);
- a **lifecycle dispatcher** over the 10 `EffectStep`s, selected by the 16-bit `getStepsBitmap`, with
  **consistent reentrant battle-state views** mid-hook;
- the **~21 engine syscalls** as opcodes;
- two **macro opcodes** — `DAMAGE` (AttackCalculator) and `STAT_BOOST` (StatBoosts) — or the circuit
  must inline ~825 LOC of EVM-exact arithmetic incl. intentional overflow.

**Recommendation: prototype on a subset; don't commit to a full VM yet; don't shelve.** The two
make-or-break gates are (1) StatBoosts + AttackCalculator as economical in-circuit primitives, and
(2) keccak-per-turn prover cost (keccak, not arithmetic, is the dominant in-circuit driver here).

---

## 1. Required syscall set (≈21 engine ops = the VM's primitives)

**Reads:** `getMonValueForBattle`, `getMonStateForBattle`, `getMonStatsForBattle`, `getEffects`,
`getEffectData`, `getGlobalKV`, `getMoveDecisionForBattleState`, `getActiveMonIndexForBattleState`,
`getTurnIdForBattleState`, `getKOBitmap`, `getTeamSize`, `getDamageCalcContext`, `getPreDamage`/`tempRNG`.

**Writes:** `updateMonState`, `dealDamage`, `dispatchStandardAttack`, `addEffect`/`removeEffect`/`editEffect`,
`setGlobalKV`, `switchActiveMon`, `setPreDamage`.

**Trusted library subroutines that must become macro-opcodes (not opaque callouts):**
`AttackCalculator._calculateDamage*` (≈190 LOC, calls `ITypeCalculator` + RNG/accuracy/crit/variance),
`StatBoosts.addStatBoosts/removeStatBoosts/clearAll` (≈635 LOC), `ITypeCalculator.getTypeEffectiveness`,
`SwitchTargetLib.findRandomNonKOed`, keccak key-derivation libs (`StatusEffectLib`, `HeatBeaconLib`, `NineNineNineLib`).

## 2. Coverage (~55 items across 13 mons)

- **~40% trivial** — `StandardAttack` wrapper + one side effect.
- **~45% moderate** — RNG branching, globalKV state machines, bounded loops, heal-with-clamp, single reentrant read.
- **~15% HARD**, each with a specific blocking feature:

| Move/ability | Blocking feature |
|---|---|
| **HardReset** (nirvamma) | Global-singleton effect `(2,0)` w/ caster identity in extraData; fires only on opponent NO_OP; heals/damages *both* teams in one hook; RNG-seeded forced switches; 2-bit state machine. **Hardest single item.** |
| **Gachachacha** (sofabbi) | RNG 3-way dispatch where one branch **swaps the attacker context fed to the damage calc** (move computes damage *as the opponent*); basePower is sometimes attacker HP, sometimes defender HP. Breaks "move computes its own fixed basePower." |
| **ActusReus** (malalien) | Conditional debuff on opponent-KO; reentrant live-KO read; triple-hook lifecycle; opaque 1-bit flag in bytes32; routes through StatBoosts. |
| **Initialize** (inutia) | GlobalKV lock-on-execute + clear-on-switchout + propagate-buff-on-switchin; cross-mon buff routing. |
| **ChainExpansion** (inutia) | Per-opponent-switch "summon" effect: decrement charges, heal/damage by type, self-remove when exhausted. Needs event scheduling, not move-and-return. |
| **Tinderclaws** (embursa) | `getMoveDecisionForBattleState` mid-hook to gate self-burn on the player's *intent this turn* (REST/SWITCH/normal). |
| **PostWorkout** (pengym) | `onMonSwitchOut` recovers a status-effect *address* from globalKV, scans `getEffects` to find+remove it, grants stamina. |
| **SneakAttack** (ekineki) | Manual `DamageCalcContext` from 9 reentrant reads + persists-as-effect; needs an 8-point consistent reentrant view. |

**The real ceiling — `StatBoosts`** (≈635 LOC; clients: TripleThink, ActusReus, Deadlift, Loop,
Initialize, Interweaving, HoneyBribe, Tinderclaws, EternalGrudge, UpOnly, SaviorComplex, Chronoffense).
It iterates the live effect set, **accumulates with unchecked wrapping exponentiation**
(`scalingFactor ** boostCounts[k]`), divides by a denom-power, and packs a globalKV snapshot. Its result
depends on the *entire live effect set* and on EVM-exact 256-bit wrap semantics. It must be a first-class
VM opcode — there is no clean "treat it as opaque" middle.

## 3. Transpiler reuse

The existing `transpiler/` (Sol→TS) is the **front half for free and almost none of the hard half**:
- **Carries over (~1/3, mechanical):** lexer/parser/AST + arithmetic/bitop/keccak codegen + control-flow
  lowering. Trivial + most moderate moves transpile near-mechanically.
- **Does NOT carry over (the expensive 2/3):** no storage model (but globalKV + effect `extraData`
  persistence is *the* state mechanism); dynamic dispatch via a **runtime registry of concrete
  instances** (a circuit needs static, compile-time-flattened dispatch); no macro-opcode mapping for
  AttackCalculator/StatBoosts; no effect-lifecycle scheduling (that's engine behavior, not in-function).

## 4. Recommendation & gates

**Prototype scope:** `aurox + ekineki + embursa` (covers trivial wrappers, RNG branching, globalKV state
machines, the NineNineNine turn-counter pattern, Tinderclaws's hard intent-read, and UpOnly/HoneyBribe as
StatBoosts clients) **+ `HardReset` as the explicit "can the VM even express this?" stress test.**

**Gate 1 — macro-opcodes:** implement `DAMAGE` (AttackCalculator) and `STAT_BOOST` (StatBoosts) as
in-circuit primitives *first*, incl. the unchecked-wrap exponentiation. If these can't be proven
economically, the VM is dead on arrival — 12+ moves and the whole stat-boost system route through them.

**Gate 2 — keccak economics:** measure keccaks/turn (RNG stream-splitting + every KV key) in-circuit;
that, not arithmetic, is the dominant cost. Decide "how many keccaks/turn can we afford" on the subset
before scaling.

**Long tail behind a `kind: custom` escape hatch:** a move the VM can't represent stays native EVM and
simply isn't ZK-provable yet. First candidates: Gachachacha's attacker-context swap, ChainExpansion's
summon scheduling.

Key source refs: `src/IEngine.sol` (syscalls), `src/effects/StatBoosts.sol:153-248` (aggregation +
unchecked exponentiation ceiling), `src/moves/AttackCalculator.sol:38-127` (damage macro),
`src/mons/nirvamma/HardReset.sol:41-163` (hardest item), `src/mons/sofabbi/Gachachacha.sol:47-62`
(attacker swap), `src/Enums.sol` (EffectStep lifecycle the dispatcher must cover).
