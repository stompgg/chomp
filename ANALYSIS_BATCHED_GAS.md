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
| `main` legacy (baseline, 2-sig) | 5,277,953 | — |
| clean-legacy (repack + single-sig) | 5,201,946 | −75,907 (−1.4%) |
| **clean-batched** (repack + single-sig + batching, no shadow) | **4,583,171** | **−694,782 (−13.2%)** |

**Batching reduces gas ~13% vs `main` on a real game**, and even the legacy fallback is now below
`main` (single-sig + repack). The batched win = ~11% cold-read amortization (one execute tx keeps
every slot warm across sub-turns, for free) + ~2% single-sig submit + the BattleData repack.

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
| A2 | Legacy `executeWithDualSignedMoves` → single-sig (`msg.sender==committer`, drop committer sig) | ~3.6k/turn legacy |

Full suite green (506 tests).

## Security model (single-sig)

Replay protection is unchanged from the dual-sig design — it lives in the **revealer signature**,
which is over `DualSignedReveal{battleKey, turnId, committerMoveHash, revealerMove…}`:

- **Cross-turn / cross-battle replay:** the signature binds `(battleKey, turnId)`, so a signature
  for turn N can't be replayed on turn N+1 or another battle (the digest differs → recovery fails).
- **Committer can't change their move:** the revealer's sig binds `committerMoveHash`. If the
  committer submits a different preimage, the recomputed hash differs → the revealer sig recovers
  the wrong address → `InvalidSignature`.
- **Committer can't be impersonated / unilateral-revealer attack:** `msg.sender == committer`. A
  revealer (or any third party) submitting a forged committer move reverts `NotCommitter` before
  any execution. (This is the load-bearing check; the trade-off is no relaying — the committer must
  send their own turn's tx.) The CPU passthrough (D) uses the same `msg.sender == p0` binding.

## The floor (how much further can gas go?)

Within the hard constraints (fully on-chain, per-turn submission, no batch-submit, no optimistic
execution), the achievable win is **~13% vs `main`** for PvP (batching + single-sig + repack), plus
the CPU-decision-offchain saving for single-player. The structural floor is the per-turn submission:
each turn is ≥1 tx, so you pay `N × (21k base + 1 sig ~3k + calldata + buffer write)` regardless —
~35k/turn of irreducible submission overhead. Batching only amortizes the *execution* side. Going
materially below ~13% would require either relaxing a constraint (batch-submit / optimistic) or
shrinking per-turn cold reads (tighter `BattleConfig` packing — the one unexplored on-chain lever,
which helps both paths).
