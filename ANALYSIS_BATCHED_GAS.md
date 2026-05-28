# Batched-Execute Gas — Findings & Clean-Branch Result

This branch (`claude/batched-from-main`) is a clean re-application from `main` of the gas wins
discovered while investigating the prior batched branch (`claude/decouple-engine-move-tracking-*`),
whose history was convoluted by a transient "shadow" layer that was added, reverted, and re-added.

## TL;DR

On a **real 26-turn prod game** (switch/no-op heavy), measured production-faithfully (each turn /
submission a separate cold-access tx via `vm.cool`; steady-state value-warm storage via storageKey
reuse), with **byte-identical end state** between legacy and batched (equivalence verified with real
mon contracts):

| Flow | total gas | vs `main` |
|---|---|---|
| `main` legacy (baseline) | 5,277,953 | — |
| clean-legacy (repack, dual-sig) | 5,296,078 | ≈ parity |
| **clean-batched** (repack, single-sig, no shadow) | **4,584,625** | **−693,328 (−13.1%)** |

**Batching reduces gas ~13% vs `main` on a real game.** The win = ~11% cold-read amortization
(one execute tx keeps every slot warm across sub-turns, for free) + ~2% single-sig submit + the
BattleData repack.

## The key finding: the transient shadow was *counterproductive*

The prior branch's premise — "a transient shadow (mirror MonState + BattleData slot-1 in transient,
flush once at batch end) is needed to deliver the savings" — was **backwards**:

- The EVM already amortizes cold→warm SLOADs across the sub-turns of a single `executeBatchedTurns`
  tx for free (EIP-2929 warm-slot discount). The shadow re-implements a discount you already get.
- Repeated SSTOREs to the same slot within one tx are already only ~100 gas each (EIP-2200 dirty
  rule) — so the shadow's flush-once "dedup" saved almost nothing.
- Meanwhile the shadow added a TLOAD check + a transient round-trip + dirty/loaded bookkeeping on
  **every** MonState/slot-1 access (reads dominate), and the MonState memory-materialization taxed
  both the legacy and batched paths.

Measured: removing the shadow saved **~94k/game**, and the shadow-support refactor had regressed the
legacy path **+12% vs `main`** — which is exactly why batching looked break-even on the old branch.
On a clean engine (storage pointers, like `main`), batching's ~13% shows through with no regression.

## Measurement methodology (the honest instrument)

Two prior instruments were misleading:
- **All-warm microbench** (`gasleft()` across one foundry tx after a warmup battle): gives legacy
  its cold SLOADs for free → made batched look +33% worse. Wrong regime for production.
- **Storage-only access tally**: per-tx-faithful cold/warm, but misses compute (and undercounts the
  shadow's transient ops) → credited batching with savings it didn't net.

The authoritative instrument is `test/RealMonReplayGasTest.t.sol`: a **faithful real-game replay**
(real mon loadouts via `SetupMons`' canonical `deployX()` recipes + the log's exact moves/salts),
run legacy vs batched, measured per-tx cold via `vm.cool`, steady-state via storageKey reuse, with
an end-state equivalence assertion. `processing/parse_desync_report.py` turns any desync log into
this test's data, so real games are reusable gas + equivalence regressions.

## What's on this branch (ported, each verified)

| Step | Change | Gas |
|---|---|---|
| A1 | BattleData slot-1 **repack** (all per-turn fields in slot 1 → 1 SSTORE/turn) | small, both paths |
| B | **Batching**: `submitTurnMoves` (single-sig: `msg.sender==committer`) + `executeBuffered` + `Engine.executeBatchedTurns` (direct storage, **no shadow**) | −11% (amortization) |
| — | single-sig **submit** (revealer sig pins the committer move hash; committer can't be impersonated, can't change move) | ~2% on submit |
| C | `vm.cool` production-faithful harness + real-mon replay (equivalence + gas) | (measurement) |
| D | **Offchain-CPU** `selectMoveWithCpuMove`: p0 submits both moves; skips `getCPUContext` (dozen+ cold SLOADs) + `calculateMove` every CPU turn | large, CPU games |
| E | `parse_desync_report.py`: desync log → replay test data | (tooling) |

Full suite green at each step (507 tests).

## Remaining / deliberate follow-ups

- **A2 — legacy `executeWithDualSignedMoves` single-sig.** `main` ships the relayer-friendly dual-sig
  (committer + revealer). Reverting it to `msg.sender==committer` saves ~4k/turn on the *legacy*
  (fallback) path but is a security-model change with churn across ~15 test sites (some assert
  committer-sig behavior). Deferred as a deliberate decision — the **primary** single-sig win (the
  batched submit) is already in. The CPU passthrough (D) is `msg.sender==p0`, also single-sig.

## The floor (how much further can gas go?)

Within the hard constraints (fully on-chain, per-turn submission, no batch-submit, no optimistic
execution), the achievable win is **~13% vs `main`** for PvP (batching + single-sig + repack), plus
the CPU-decision-offchain saving for single-player. The structural floor is the per-turn submission:
each turn is ≥1 tx, so you pay `N × (21k base + 1 sig ~3k + calldata + buffer write)` regardless —
~35k/turn of irreducible submission overhead. Batching only amortizes the *execution* side. Going
materially below ~13% would require either relaxing a constraint (batch-submit / optimistic) or
shrinking per-turn cold reads (tighter `BattleConfig` packing — the one unexplored on-chain lever,
which helps both paths).
