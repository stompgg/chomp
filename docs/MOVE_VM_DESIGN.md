# Move-VM Design Sketch

Builds on [`MOVE_VM_RESEARCH.md`](./MOVE_VM_RESEARCH.md). **Premise:** `StatBoosts` and `AttackCalculator`
are absorbed into the engine as syscalls (this clears the single biggest dependency gate — see the
research doc §"real ceiling"). Under that premise, this sketches what the move VM looks like.

**Goal:** a move/ability becomes a **VM program** (data) run by a **fixed interpreter** whose only
side-effects are engine syscalls. Then the entire battle is ZK-provable by proving *one interpreter*
over committed program-data + inputs, instead of proving arbitrary user EVM bytecode.

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
