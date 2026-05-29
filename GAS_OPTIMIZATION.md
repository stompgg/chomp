# Gas Optimization — Record & Remaining Opportunities

Consolidated record of the batched-execute + gas work on `claude/batched-from-main`.
**Supersedes** the earlier `ANALYSIS_BATCHED_GAS.md` and `OPT_PLAN.md` — the latter described a
transient-shadow / dual-sig / CPU-state-hint design that was tried and **abandoned** (see §5).

Hard constraints this work respected: fully on-chain; per-turn move submission (no batching multiple
PvP submissions into one tx); no optimistic/dispute-only execution. Deferring all *executions* into
one tx is allowed. Single-sig submit (`msg.sender == committer`) is intentional (saves an ecrecover).

---

## 1. Headline (production-faithful, real 26-turn game)

Measured via `test/RealMonReplayGasTest.t.sol`: a faithful replay of a real prod game (real mon
loadouts via `SetupMons` `deployX()` recipes + the log's exact moves/salts), each turn/submission a
separate cold-access tx (`vm.cool`), steady-state value-warm storage (storageKey reuse),
**production config (inline stamina regen)**, with byte-identical end-state equivalence asserted
between the legacy and batched paths.

| Flow (prod config: inline regen + repack + single-sig) | total gas | |
|---|---|---|
| clean-legacy (per-turn execute) | 4,624,316 | |
| **clean-batched** (submit ×26 + 1 execute) | **4,106,467** | batching saves **517,849 (~11.2%)** |

Two wins compound, in order of impact:

1. **Inline stamina regen — ~11% (~477–577k/game).** A *config* choice, not new code: prod battles
   must use `INLINE_STAMINA_REGEN_RULESET` (sentinel `address(0x57A)`), which sets
   `config.hasInlineStaminaRegen` so the engine runs regen internally. The external `StaminaRegen`
   effect is the slow path — every round-end/after-move it makes reentrant calls
   (`getPlayerSwitchForTurnFlagForBattleState`, `getMoveDecisionForBattleState`, stamina
   `getMonStateForBattle`, `updateMonState`) that all vanish under inline. This was the single
   biggest lever and was always available — see §4 for the methodology lesson.
2. **Batching — ~11.2% (517,849/game).** One execute tx amortizes execute-side cold reads across all
   sub-turns (EIP-2929 warm-slot discount), for free; plus single-sig submit and the BattleData
   slot-1 repack.

> The old external-regen `main` baseline (5,277,953) is **no longer comparable** — it measured the
> slow ruleset. A fair main comparison needs `main` itself re-measured under inline; estimate
> main-inline-legacy ≈ 4.70M (clean-legacy-inline + the measured ~76k repack+single-sig delta).

---

## 2. What shipped on this branch

| Change | Effect |
|---|---|
| **BattleData slot-1 repack** | All per-turn-mutable fields in one slot → 1 SSTORE/turn (both paths) |
| **Batching**: `submitTurnMoves` + `executeBuffered` + `Engine.executeBatchedTurns` (direct storage, **no shadow**) | ~11% execute-side cold-read amortization |
| **Single-sig submit** | Revealer sig pins the committer move hash; `msg.sender == committer`. Drops one ecrecover + one 65-byte sig vs dual-sig (~2% on submit). Applied to the legacy `executeWithDualSignedMoves` too. |
| **Offchain-CPU** `selectMoveWithCpuMove` | Player submits both their move and the CPU's move in one tx; skips `getCPUContext` (dozen+ cold SLOADs) + on-chain `calculateMove` every CPU turn |
| **`RealMonReplayGasTest` + `parse_desync_report.py`** | Desync log → replay test (equivalence + prod-faithful gas). Any real game becomes a gas + equivalence regression. |
| **`FullyOptimizedInlineGasTest` + `GasMeasure`** | Per-tx cold-access + deterministic storage-access tally; the canonical inline gas tracker |

Removed: `InlineEngineGasTest`, `EngineGasTest` (subsets / external-validator baseline — not the prod stack).

---

## 3. Security model (single-sig)

Replay protection lives in the **revealer signature** over
`DualSignedReveal{battleKey, turnId, committerMoveHash, revealerMove…}`:

- **Cross-turn / cross-battle replay:** the sig binds `(battleKey, turnId)` → a turn-N sig can't be
  replayed on turn N+1 or another battle (digest differs → recovery fails).
- **Committer can't change their move:** the revealer sig binds `committerMoveHash`; a different
  committer preimage recomputes a different hash → revealer sig recovers the wrong address → revert.
- **No impersonation / unilateral-revealer attack:** `msg.sender == committer` (load-bearing). A
  third party / revealer submitting a forged committer move reverts `NotCommitter` before execution.
  Trade-off: no relaying — the committer sends their own turn's tx. The CPU path uses the same
  `msg.sender == alice` binding.

---

## 4. Measurement methodology (and the lesson that re-baselined everything)

The authoritative instrument is `RealMonReplayGasTest` (above). Per-tx cold via `vm.cool`,
steady-state via storageKey reuse, equivalence asserted. The `--gas-report` over it attributes the
reentrant cost to each Engine call.

**Lesson (cost us a whole analysis pass):** the replay was originally built against
`DefaultRuleset(new StaminaRegen())` — the *external* regen path, which prod does not use. That
inflated the baseline and made the reentrant-read breakdown look dominated by `getMonStateForBattle`
(260 calls) / `getMoveDecisionForBattleState` (180) / `getPlayerSwitchForTurnFlag` (88). After
switching to the prod inline config those collapsed to 64 / 4 / 0. **Always baseline against the
actual production config before ranking optimizations.**

---

## 5. Tried and rejected (measured)

- **Transient shadow** (the original `OPT_PLAN.md` premise: mirror MonState + BattleData in transient,
  flush once at batch end). **Net-negative (~−94k/game).** The EVM already amortizes cold→warm SLOADs
  within one tx for free, and repeated same-slot SSTOREs are already ~100 gas; the shadow added a
  TLOAD-check + dirty/loaded bookkeeping on *every* access (reads dominate). Removed entirely — the
  clean engine (direct storage pointers, like `main`) shows batching's ~11% with no regression.
- **#4 no-op globalKV SSTORE guard** (skip the write when the value is unchanged). **Regressed every
  measured scenario** (Battle1 +191, Battle3 +191, real-game +335) with **zero** no-op writes avoided
  — statuses set distinct per-mon flags and abilities set-once-then-read, so the guard only ever pays
  the compare, never skips. Reverted.
- **#6 transient-reset trimming** (the "8→2 TSTOREs" idea in `executeBatchedTurns`). **Premise was
  wrong.** Audit: the 4 move/salt resets + `tempRNG` are *load-bearing for legacy↔batched
  equivalence* (`_emitMonMoves` reads both players' moves unconditionally every turn incl. one-sided;
  one-sided switch-in effects read `tempRNG`, which is only set on two-player turns). The other 3
  (`tempPreDamage`/`koOccurredFlag`/`effectsDirtyBitmap`) are only *probably* redundant under fragile
  within-turn self-clearing invariants, worth ~2.6k/game (batched-only) to chase. Skipped.
- **Delegatecall moves** (run move logic in the engine's context to "save SLOADs"). Rejected on both
  counts: (a) move params are **mutable** (`StandardAttack.changeVar`, owner balance-tuning) so they
  can't be bytecode/immutable, and they're **already packed into one slot** — there's no scattered
  SLOAD to collapse; delegatecall would only save the warm cross-contract CALL (~100–700), not the
  SLOAD. (b) Running curated/user move code in the engine's storage context is arbitrary state
  corruption (`winnerIndex`, balances) — a hard no for a game built on user-created moves.
- **Shared mon-instance cache for `startBattle`** (the big one we chased and dropped). **Idea:** store
  each mon's base catalog *once* in the engine (`engineMon[monId] = {stats, ability, moves}`, shared
  across all teams), have teams reference mons by id + per-slot facet, freeze the ids/facets into the
  battle config at start, and **skip storing the per-battle `Mon[]` entirely** — no 56-slot team store
  (8 mons × 7 slots), no `getTeams` fold. `execute` would rebuild each mon from `engineMon[monId]` +
  the frozen facet at read time. **Why we thought it'd win:** `StartBattleGasTest` showed warm-steady
  `startBattle` ≈ 268k and is **slot-touch-bound** (≈ distinct slots first-touched × ~2.1k; SSTORE
  *value* tier is irrelevant warm — WARM-SAME == WARM-DIFF). The per-battle team store looked like a
  free ~160–180k to delete.
  **Why it doesn't pay (measured, `TeamMonReadGasTest`, faithful layout, cold-started per turn):** the
  per-battle `Mon[]` is **not write-once** — `execute` reads it ~16×/turn via `_getTeamMon`, which
  today returns a **storage ref to a pre-folded `Mon`** (≈1 SLOAD/field, cheap). The cache replaces
  that with monId indirection (read frozen ids) + `engineMon[monId]` re-resolution (keccak) + facet
  fold on *every* read, and every `execute()` is its own cold-start tx (EIP-2929 resets warmth):

  | read model | gas/turn | Δ |
  |---|---|---|
  | current — storage ref, pre-folded | 21,581 | — |
  | full cache, field accessors | 32,896 | **+11,315** |
  | full cache, resolve-once + thread | 27,658 | +6,077 |
  | hybrid — pre-fold+store stats, dedup only moves/ability | 20,750 | −831 (neutral) |

  `net/battle = startBattle saving − execute Δ × turns`. The full cache regresses `execute`
  +11.3k/turn → ~+136k over a 12-turn battle against a ~180k `startBattle` saving → net only ~+44k,
  and **net-negative on long battles** — and it violates the hard "gas-neutral on hot paths" rule. The
  only execute-neutral variant is the **hybrid** (keep pre-folded stats stored per battle so stats
  reads are unchanged; dedup only the facet-*independent* moves/ability via `engineMon`), but it still
  stores 8 stat slots + a monId slot/battle, so its `startBattle` saving shrinks to ~135–160k and it
  buys a single-digit-% battle-cost cut for permanent hot-path complexity (split read path, registry
  push hooks, set-once `ENGINE`, deploy-order + backfill). Not worth it.
  **Root cause of the misjudgment:** we priced the per-battle `Mon[]` as pure write-once storage, so
  "store once + dedup" looked free — but it's **read-hot**, and the dedup's `startBattle` SSTORE saving
  is paid back (and then some) by per-read indirection on the `execute` hot path. "Slot-touch-bound
  `startBattle`" was true but only *half* the equation; the `execute` read-path delta only showed up
  once we micro-benchmarked it. If ever revisited, only the hybrid is viable and it must be gated on a
  full-battle RealMonReplay (start + execute over all turns), not the `startBattle` number alone.
  *(The abandoned 4-commit arc — tip `4da60a2` — is in the reflog. Per-team facets, commit `2125e22`,
  was a cache enabler reverted here back to per-mon; cherry-pick it if wanted as a standalone feature.)*

---

## 6. Remaining opportunities (ranked, honest)

The two big wins (inline, batching) are banked. What's left is marginal, conditional, or
architectural — listed for completeness:

1. **CPU / single-player one-tx batch-submit — the biggest remaining lever, but a CONSTRAINT
   QUESTION.** The "no batching submissions" rule exists for **commit-reveal fairness** (PvP). In
   single-player vs CPU there is no adversary to hide moves from — the CPU is deterministic/RNG-seeded
   and (with the ported offchain-CPU) already computed off-chain. So a single-player game has *no
   fairness reason* for per-turn submission: the player could submit the entire move list and execute
   the whole game in **one tx**, collapsing ~27 txs → 1 (~546k tx-base + ~1.25M submit execution) —
   roughly **halving single-player cost**, more than every micro-lever combined. **Gated on: does the
   no-batch-submission constraint apply to single-player, or is it purely a PvP-fairness rule?** If
   PvP-only, this is the win to pursue.
2. **`getSubmitContext` (~182k/batched-game, ~7k/submit)** — the biggest submit-side bucket, but
   ~irreducible: it's already a single bundled engine call (one cold account access + the p0/p1/
   storageKey/winnerIndex reads, all genuinely needed — p0/p1 are load-bearing for the anti-grief
   `msg.sender == committer` check). The only structural cut is **moving the move-buffer into the
   engine** (eliminates the cross-contract call, ~68k/batched-game) — a real refactor that merges the
   swappable move-manager boundary into the engine.
3. **Ability-idempotency (`getEffects` scan, ~103k bucket)** — abilities scan the effect list on every
   switch-in to avoid double-registration. A `globalKV`/bitmap flag or a caller-provided slot **hint**
   is O(1), but **conditional**: it adds an SSTORE that *regresses* single-switch-in mons and only
   wins for mons that switch in ≥2× / carry many effects. Same shape as #4/#6 — validate empirically
   before committing.
4. **Per-tx base floor: 27 × 21,000 = 567k.** Structural under the per-turn-submission constraint —
   only the single-player batch-submit (#1) touches it.

### Verified already-optimal (no win available)

- Reentrant views resolve storage via the transient `storageKeyForWrite` during execute (1 TLOAD,
  not the `battleKeyToStorageKey` SLOAD).
- Move params (`StandardAttack`) are packed into one slot; reads are cold-once-per-tx then warm.
- The prod (inline-validation) path calls `stamina()` once and `priority()` once per move (1784/1798
  are mutually exclusive branches, not a double call).
- Storage is bit-packed throughout (BattleData → 1 slot/turn, MonState → 1 slot/mon, KO bitmaps,
  effect counts), and the damage path already batches reads via `getDamageCalcContext` / `getMeta`.

---

## 7. Files

- `test/RealMonReplayGasTest.t.sol` — authoritative prod-faithful real-game replay (equivalence + gas).
- `test/FullyOptimizedInlineGasTest.sol` + `test/abstract/GasMeasure.sol` — inline gas tracker + tally.
- `processing/parse_desync_report.py` — desync log → replay test data.
- `src/Engine.sol` — `executeBatchedTurns`, `getSubmitContext`, BattleData repack.
- `src/commit-manager/SignedCommitManager.sol` — `submitTurnMoves` / `executeBuffered` (single-sig).
- `src/cpu/CPUMoveManager.sol` — `selectMoveWithCpuMove` (offchain-CPU, submit-both-moves).
