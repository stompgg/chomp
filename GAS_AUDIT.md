# Gas Audit — June 2026

Multi-agent audit of all gas-relevant paths (9 area auditors → dedup → adversarial verification of
every finding; 30 confirmed, 2 refuted, 0 verifier failures). Every estimate below is the
*verifier-corrected* number, not the finder's original claim.
**Status (updated):** BUG-1/2/3 fixed, BUG-4 documented won't-fix; optimizations triaged per Owen's inline annotations (answers inline below).

**Prod frame used for ranking** (per Owen):
- OP-stack L2; execution gas is the scarce resource; bytecode size is a non-issue.
- Prod paths only: inline validation (`validator == address(0)`), `INLINE_STAMINA_REGEN_RULESET`,
  built-in dual-signed buffer for PvP, `selectMoveWithCpuMove`/`executeGame` for CPU (on-chain
  `calculateMove` is dev-only), SignedMatchmaker, GachaTeamRegistry.
- Deprecated (do not optimize): DefaultValidator, DefaultCommitManager, SignedCommitManager,
  DefaultMatchmaker (test-only), on-chain heuristic CPU decisions.
- Breakage budget: anything with good ROI (events, IEngine surface, storage layout all OK).

---

## 1. Where the gas actually goes (prod flows)

**PvP per-turn (built-in dual-signed).** A stage tx (`submitTurnMoves`) runs ~45k (recycled buffer
slot) to ~62k (fresh): 21k tx base, ~2.1k calldata, ~6.4k cold mapping reads, ~3.9k signature work
(already optimal: Solady immutable domain separator, EIP-2098), 5–22.1k `moveBuffer` SSTORE + 2.9k
`numBuffered` RMW, ~1.05k `MovesSubmitted`. The drain adds ~3k per buffered turn on top of the
~76.3k engine turn. `submitTurnMovesAndExecute` is already well-tuned (~13–15k overhead, zero
buffer touches for 1-turn batches). The engine turn itself: ~21k base, ~12–18k cold SLOADs, ~4–6k
SSTOREs, ~2.4k events, remainder compute/keccak/transient.

**Benchmarks systematically understate prod by ~2.3k/turn**: every gas test passes zero engine
hooks, but prod battles always carry GachaTeamRegistry as an OnBattleEnd-only hook, and both
per-turn hook loops still probe its `stepsBitmap` (finding C1).

**startBattle (warm-steady 266.8k).** ~79 cold SLOADs (~166k) are the registry `getTeams` call, of
which ~72 (~151k) are catalog reads at **9 cold SLOADs per distinct mon** (1 stats + 5 for the
4-move EnumerableSet + 3 for the 1-ability EnumerableSet). Engine-side, the team re-store is 56
slots (7/mon — incl. one pure length slot per mon), ~123k when values are identical (cold-access
no-op writes at ~2.2k each). BattleData's two slots are 0→nonzero every battle (44.2k floor —
battleKey is fresh per battle).

**Battle end.** The one slot the recycling design still re-zeroes every cycle: MappingAllocator's
free-list push/pop costs ~40–51k per battle lifecycle (pop zeroes the element, length toggles
0↔1, `battleKeyToStorageKey` write+delete). Plus onBattleEnd ~24–30k per human side (already
well-batched; small quest-slot wins remain).

**Status/boost battles.** The engine-side gating is excellent; the remaining fat is in the
*callers*: vestigial globalKV keys (burn/sleep/overclock: 13–48k per first-write key per battle),
each boost-source entry taxing every `_runEffects` pass ~2.2k/turn cold, and cross-contract
round-trips at ~700–1500 each for state the engine could hand over or read once.

**CPU one-tx (`executeGame`).** Already the cheap path. Residual: byte-by-byte calldata decode
(13-iteration inner loop per turn), dead move-snapshot reads on flag sub-turns, per-sub-turn warm
hook probes.

---

## 2. Correctness bugs found while auditing (fix regardless of gas)

| ID | Bug | Severity |
|----|-----|----------|
| **BUG-1** | **Stale `p0Move`/`p1Move` on recycled storage keys.** Game-over path returns before the end-of-turn move-clear (`Engine.sol:1111-1118` vs `1130-1133`) and `startBattle` never clears them, so a new battle recycling a key whose previous occupant ended on a `setMove`-driven turn still has `IS_REAL_TURN_BIT` set. `execute()` is permissionless and only requires one real-turn bit → **anyone can burn turn 0 of the new battle with the previous battle's moves** (griefing). Fix: duplicate the conditional clear (`!cameFromDirectMoveInput`) before the game-over return. Must stay conditional — an unconditional clear in `_handleGameOver` re-introduces the ~4.4k cold 0→0 burn documented at `Engine.sol:1127-1129`. | High — **FIXED**: conditional clear in the game-over branch + unconditional clear in `end()`; regression tests in `RecycledKeyHygieneTest` |
| **BUG-2** | **Stale `hasInlineStaminaRegen` on recycled keys.** Set true in the inline branch (`Engine.sol:261`), never cleared in the other branches — a later battle on the same key with an external/no ruleset gets inline regen *on top of* its config. Latent today (prod always uses the sentinel) but a footgun. Also: `globalEffectsLength` not reset when an external ruleset returns 0 effects; `p0Salt`/`p1Salt` never reset. | Latent — **FIXED**: every ruleset branch now writes `hasInlineStaminaRegen` + `globalEffectsLength`; salts reset at startBattle |
| **BUG-3** | **`SleepStatus._globalSleepKey` is read but never written nonzero** (`SleepStatus.sol:22-24, 33-36, 111`) — the one-sleeper-per-player gate is inert. Either an unwired feature (add the missing write) or dead code (delete). `BurnStatus.onRemove`'s degree-reset KV write (`BurnStatus.sol:117`) is unambiguously dead — the degree lives in extraData. Both cost real gas (finding D1). | **FIXED**: sleep gate wired as a live feature (one sleeper per player; a KO'd sleeper releases the gate; guarded clear on remove); Burn dead write removed |
| **BUG-4** | **DefaultMatchmaker re-propose leaks pool keys / strands proposals** (`MappingAllocator.sol:9-20` never checks an existing mapping; worse, the `(p0, address(0))` open-proposal nonce never bumps, so every open-proposal cycle leaks one pool key). Test-only now (DefaultMatchmaker not deployed), but `_initializeStorageKey`'s no-check contract is shared — keep in mind if the allocator is ever reused. | **WON'T-FIX** (deprecated, test-only): documented in the DefaultMatchmaker contract header + CLAUDE.md Known Issues — do not re-promote to prod without fixing |

---

## 3. Confirmed optimizations, ranked by prod expected value

Verifier-corrected savings. "Break" = none / storage-layout / events / interface / architecture.

### Tier A — battle lifecycle structure (~85–100k off every battle, more on rematches)

| ID | Finding | Verified savings | Break |
|----|---------|------------------|-------|
| **A1** | **MonRegistry: flat per-mon rows instead of EnumerableSets.** `monMoves[id]` → `mapping(uint256 => uint256[MOVES_PER_MON])` (4 SLOADs, no lazy-length word), primary ability → one slot. 9→6 cold SLOADs per distinct mon. `MonRegistry.sol:18-21,156-172`. | **~50k per warm startBattle** (8 distinct mons; ~6.3k per *distinct* mon) | storage-layout (registry redeploy; catalog re-seeded at deploy, no migration) |

Does this still work if we want more than 4 moves per mon (and to let players customize)?

> **A:** Yes, with one adaptation: size the flat row to a max-catalog-moves constant and keep a packed per-mon move count (16 counts per word). If players later pick K moves from a larger pool, the team store records the selected indices and `getTeams` reads only those K slots — the EnumerableSet overhead (lazy-length word + per-value position slots) never comes back, so the savings survive and actually grow with catalog size. Caveat that exists regardless of layout: player move-selection needs new PackedTeamStore lanes (~12 bits/mon for 4 picks from up to 8 moves).

| **A2** | **Engine team storage: `uint256[4]` fixed moves array** (Engine-internal `StoredMon`; public `Mon` ABI unchanged, `getBattle` rebuilds). Kills the per-mon length slot (8× 22.1k cold / 8× ~2.2k warm no-op) and the per-access bounds-check SLOAD + keccak on the hot path. `Engine.sol:246-257, 2365-2370, 2818-2822`. | **~177k per cold / ~17.6k per warm startBattle** + 0–4.8k/turn | storage-layout. Copy loop must zero-fill short teams; index≥4 must stay "silent skip" |

This is fine to codify in. Do arrays still benefit from the same mapping key reuse we're already using?

> **A:** Yes — identically, slightly better. A fixed-size `uint256[4]` inside the stored struct occupies four *inline* consecutive slots of the same recycled `p0Team[monIndex]` entry (no length slot, no per-element keccak indirection). Battle N+1 on a recycled key rewrites exactly the physical slots battle N used (nz→nz ~2.9k), same as today's element writes — minus the length slot entirely. One requirement (same hygiene class as BUG-1/2): mons with <4 moves must zero-fill unused lanes so a recycled slot can't leak the previous battle's move words; zero-over-zero is a ~100-gas no-op. **Status: approved.**

| **A3** | **MappingAllocator: non-shrinking count-biased free list** (mapping + depth counter biased +1; pop leaves value in place, push is nz→nz ~2.9k instead of fresh 0→nonzero). Optional full variant: small sequential storage-key indices stored in BattleData slot-0 spare bits, killing the `battleKeyToStorageKey` write too. `MappingAllocator.sol:6-41`. | **~15–30k net per battle lifecycle** (start gets ~6.7k *worse* — loses pop refunds; battle-end tx gets ~34–37k cheaper). Full variant more | storage-layout (allocator slots shift in Engine; flag for Surgery.s.sol) |

Why does the battle-end tx get cheaper?

> **A:** Because the free-list `push` happens in the battle-ending tx, and today it's maximally expensive: Solidity's `pop()` (run at battle start) zeroes the array element, and at typical pool depth the length slot toggles 0↔1 — so the ending tx's push pays two fresh zero→nonzero SSTOREs (~40k gross, partially refunded). With a count-biased non-shrinking list, pop only decrements the counter (the value stays in place) and push rewrites the same lane nz→nz (~2.9k) plus the counter (~2.9k, never touching zero thanks to the +1 bias). The flip side: startBattle loses the pop-zeroing refunds (~6.7k worse there); net per lifecycle ~15–30k better.

| **A4** | **Rematch fast-path via content commitment.** `getTeamsIfChanged(prevCommitment, …)` reads ~6–8 compact words (team lanes, facet words/buckets, playerData CPU bits, catalogVersion counter — exp/levels don't affect output), returns early on match; Engine also skips the 56-slot team re-store. `GachaTeamRegistry.sol:325-381`, `Engine.sol:236-257`. | **~118–121k per identical-team rematch**; miss costs ~7–10k | architecture + ITeamRegistry addition. Commitment must cover *every* getTeams input (high-severity bug class if one is missed). Hit rate depends on the global pool handing the pair back its own slot (LIFO → likely under low concurrency) |

This seems unlikely as players may change up their team after a game.

> **A:** Agreed for PvP — deferring. If we ever revisit: vs-CPU rematches (same player grinding the same phantom-config CPU with the same team) are plausibly the common case, and a miss only costs ~7–10k against a ~120k hit, so even modest hit rates pay. But it's also the riskiest finding in the doc (the commitment must cover *every* `getTeams` input), so deferred-by-default is right. **Status: deferred.**

| **A5** | **Skip `matchmaker.validateMatch` when `msg.sender == matchmaker`** (every prod flow: SignedMatchmaker.startGame, CPU self-matchmaker). `Engine.sol:150-164`. | ~400–700 per prod startBattle (~3k on legacy DefaultMatchmaker) | none. Third-party matchmakers relying on the callback for side effects would silently skip it — document |

Given all matchmakers already handle validation, we should remove this error and the check, and fully trust matchmakers.

> **A:** Adopted in that stronger form: delete the `validateMatch` callback and `MatchmakerError` entirely. The real authorization gate (`isMatchmakerFor[p0][mm] && isMatchmakerFor[p1][mm]`) stays; a matchmaker can already return `true` unconditionally, so the callback adds no trust — player approval of the matchmaker IS the grant, and all in-repo matchmakers validate before calling `startBattle` anyway. `IMatchmaker.validateMatch` drops from the interface. **Status: approved (stronger form — remove check + error).**

| **A6** | **startBattle/getTeams micro-batch**: alias move arrays instead of element-copy (guard `length == MOVES_PER_MON`), order-then-hash-once `computeBattleKey`, skip same-value `PACKED_CLEARED_MON_STATE` rewrites, single `playerData` read per side + facet-bucket caching. | ~1.5–3k per battle flow | none |

What if the move arrays are different?

> **A:** The alias is guarded: `moves.length == MOVES_PER_MON ? alias : copy`. Every catalog mon has exactly 4 moves, so prod always takes the alias; any nonconforming length falls back to today's copy loop with byte-identical truncate/zero-fill semantics. Sharing one memory array between duplicate mon entries is safe — the Engine immediately copies the returned memory into storage and never mutates it. **Status: approved.**

| **A7** | **Slot-write consolidation in startBattle** (slots 0/1/2 are read-modify-written ~6× across external-call barriers via-IR can't merge; accumulate locally, write once at the current L302 position) + the BUG-1/BUG-2 reset fixes. | ~0.5–1k per warm start (+ the fixes ~gas-neutral) | none. Mid-startBattle staticcall-back observers would see stale packed fields — none exist today, document |

Yes, we should handle the fixes.

> **A:** The two reset fixes shipped with the bug-fix pass (BUG-1/BUG-2 above). The slot-write consolidation half stays backlog. **Status: fixes done; consolidation backlog.**

### Tier B — PvP per-turn

| ID | Finding | Verified savings | Break |
|----|---------|------------------|-------|
| **B1** | **Multi-turn batch flush (`submitTurnsAndExecute`) with committer co-signatures.** Both clients already hold co-signed `DualSignedReveal`s for every locally-played turn; K consecutive turns can flush in one tx (turnId binding gives order, exactly as `_validateAndPackTurn` L619-622), executing straight from calldata — zero `moveBuffer`/`numBuffered` writes, one `MovesSubmitted` per turn. Requires the committer to co-sign the same digest (today bound by msg.sender only), since the flusher is committer on only alternating turns. Per-turn staging + `executeBuffered` remain for the interactive/reconnect case — **this composes with, not replaces, the buffer flow**. | **~33k per amortized turn** (slot-reuse regime; ~50k fresh); **~0.7M per 26-turn game** flushed in 3–4 batches. Net of +3.1k committer ecrecover + ~1k calldata per turn | architecture (Engine entrypoint + belch/munch handshake adds one signature). Crash-safety profile: flush every K turns; must replicate `_drainBufferThenExecute`'s game-over-mid-batch semantics |

Ah, we can't do this for PVP because the goal is to keep everyone (even spectators) aware of what moves are selected. If that makes sense?

> **A:** Makes sense — rejected. The per-turn `submitTurnMoves` tx with its real-time `MovesSubmitted` event IS the spectator feed; flushing K turns at a time would blind spectators between flushes. The savings math holds but the design requirement wins. Moved to the rejected list. **Status: rejected (real-time spectation requirement).**

| **B2** | **Engine-hook steps union** (`engineHookStepsUnion` in BattleConfig slot-3 slack, mirroring `playerEffectStepsUnion`; OR'd at startBattle, gates both per-turn hook loops). Benchmarks hide this cost entirely (they pass zero hooks). `Engine.sol:807-815, 1101-1108`. | **~2.1k per legacy-shaped turn in prod** (~52k over 25 turns); ~130/warm batched sub-turn | storage-layout (slack field only, no shifts) |

Let's try this and see if it saves in practice.

> **A:** Will implement gated on a prod-shaped benchmark (gacha hook attached — current gas tests pass zero hooks, so this win is invisible to existing snapshots) + full snapshot diff. **Status: approved (measure-gated).**

| **B3** | **Mirror the built-in-manager flag into BattleData slot 0** (`usesBuiltinManager` bit written inside startBattle's existing whole-struct write; `_validateAndPackTurn` checks it off slot 0, already read for `data.p1` — drops the only battleConfig touch on the pure staging path). `Engine.sol:605-627`. | ~2.15k per `submitTurnMoves` stage tx; ~100 on combined | interface (BattleData field → getBattle tuple/ABI regen) |

Yes, we should do this if it saves in practice.

> **A:** Same treatment: implement, verify on a staging-tx benchmark + snapshot diff. **Status: approved (measure-gated).**

| **B4** | **Coalesce per-player transient reads** in `_executeInternal`: read each `_turnPxPacked` once after the hook loop, derive `cameFromDirectMoveInput`/move/salt from the local; thread salts into `_emitMonMoves`. Later consumers keep fresh re-reads (SleepStatus rewrite rule). `Engine.sol:796, 827-828, 873-874`. | ~550 per executeWithMoves/dual-signed turn; ~800–900 legacy; ~300 per batched sub-turn | none. Hot-function local-shape change → snapshot diff |

Not sure if we can do this because some moves/effects may mutate the move indices that players choose?

> **A:** Safe with respect to that — mid-turn rewrites (SleepStatus → NO_OP via `setMove`) are exactly why the *execution-time* consumers (`_handleMove`, the AfterMove regen check) keep their fresh re-reads under this change. Only the pre-execution snapshot coalesces: the MonMoves-emission read, `cameFromDirectMoveInput`, and the RNG salt reads — all of which run before any move or effect code can execute (the single read sits after the engine-hook loop, and nothing can write the transient between the snapshot and the salt consumption on the two-player path). **Status: approved (snapshot-diff gated).**

| **B5** | **Drop the `EngineExecute` event** — strict subset of MonMoves on every path that emits it (incl. `executeWithMoves`/`executeWithSingleMove`, i.e. the prod `selectMoveWithCpuMove` per-turn flow). | ~1,125 per per-turn tx (LOG2, not LOG1 — 2 topics) | events — verify belch doesn't key "turn executed" off it (migrate to MonMoves, same tx & key) |

This doesn't matter as we're not using the executeWithMoves path anymore (only batched).

> **A:** Agreed — with per-turn CPU traffic gone (`executeGame` only) and the builtin PvP drain already suppressing it, `EngineExecute` only fires on deprecated paths. Keeping the event as-is. **Status: skipped (no prod value).**

| **B6** | **Reorder `&&` operands in listener guards**: check the (almost-always-clear) `playerEffectStepsUnion` bit before the per-mon count SLOAD at `_updateMonStateInternal`, `_inlineRegenStaminaForMon`, `_dealDamageInternal` (defer count read until a union bit passes). | ~220–550+/turn | none |

Yes, we should do this.

> **Status: approved.**

| **B7** | **Thread config/battle pointers into `_runEffects` + replace `bytes` payload with 2 packed words.** All 7 callers already hold both pointers; payloads are ≤4 small words abi.encoded/decoded per listener. | ~190–220 per `_runEffects` invocation + ~80–150 per payload run | none — **but HIGH inliner risk** (the exact shape that once cost +1M); full snapshot suite + staged wins required |

Skip for now.

> **Status: skipped (inliner risk outweighs ~200/invocation).**

### Tier C — status/boost battles (the paths benchmarks don't exercise)

| ID | Finding | Verified savings | Break |
|----|---------|------------------|-------|
| **C1** | **Delete dead globalKV writes/reads**: BurnStatus.onRemove degree write, SleepStatus global-sleeper read+write (BUG-3). | ~11–14k per first burn/sleep removal per battle (up to ~45k virgin slot); ~3k per sleep application | none (confirm sleep design intent) |

> **Status: done** (shipped with the bug-fix pass — Burn dead write removed; the sleep key is now a live, wired feature so its reads/writes are intentional, not waste).


| **C2** | **Overclock duration → effect extraData** (engine already persists updatedExtraData for free; kills KV entry creation + 2 round-trips per active round). **Must ship with MegaStarBlast mask fix** — it reads Overclock's extraData raw (`MegaStarBlast.sol:37-45`). | ~18–25k per apply-to-expiry lifecycle (recycled keys), ~45k virgin | none (paired contract change) |

Yes, let's do this.

> **Status: approved (ships together with the MegaStarBlast mask fix).**

| **C3** | **Hoist the stepsBitmap filter into `_runEffects`' loop guard** — stepsBitmap shares slot 0 with the effect address, so filtering before reading `eff.data` (slot 1) + 13-arg call setup is free. Stat-boost sentinels (OnMonSwitchOut-only) currently tax every RoundStart/RoundEnd/AfterMove/AfterDamage pass. | ~2.3k/turn per filtered entry with cold data slot (e.g. burned+boosted mon, per-turn PvP); ~150–200 warm | none. Hottest loop — snapshot diff; no call-site count change |

Yes, let's do this if it saves gas in practice.

> **Status: approved (measure-gated; snapshot diff on the hottest loop).**

| **C4** | **Reuse stat-boost tombstone slots in `_addStatBoostEffectSlot`** (aggregation scan already SLOADs every effect word — record first tombstone, overwrite instead of append; stops monotonic list growth from Overclock/temp-boost churn). | ~2.3–5.1k per re-add (common case), ~34–39k on fresh keys; stops the per-pass scan tax compounding | none. Boost-entry order provably irrelevant; note switch-out hook position shift vs other effects |

Yes, let's do this.

> **Status: approved.**

| **C5** | **Streamline `_applyStatBoosts`**: hoist the OnUpdateMonState listener gate once; when no listener (one exists game-wide), write the 5 deltas directly on the already-held MonState pointer instead of 5× `_updateMonStateInternal` dispatch; kill the redundant unpack round-trip in `_addStatBoostWithKey`. | ~350–450 per single-stat op, ~900–1100 per 2-stat op; UpOnly battles ~600–800/turn | none. Watch: leaves `_updateMonStateInternal` with one internal caller → via-IR may inline; snapshot diff |

Yes, let's do this.

> **Status: approved.**

| **C6** | **`dispatchCustomAttack` engine entrypoint** mirroring `AttackCalculator._calculateDamage` semantics *exactly* (no rng remix, unconditional accuracy gate) — collapses getDamageCalcContext + 1–2 *cold* external TypeCalculator calls + dealDamage into one frame for the 10 custom-mon call sites. | ~3.5–5k per custom-attack execution (cold TypeCalculator is the common case — inline attacks use TypeCalcLib so the deployed calculator stays cold) | interface (mon redeploys; tests injecting TestTypeCalculator migrate) |

Explain this one more.

> **A (expanded):** The ~10 Tier-3/4 custom moves (NightTerrors, Q5, HardReset, …) deal damage through `AttackCalculator._calculateDamage`, which still does the pre-inlining dance. Per attack: (1) a staticcall to `ENGINE.getDamageCalcContext`, ABI-round-tripping a 12-field struct (~1.2k); (2) one or two calls to the *deployed* `TypeCalculator` contract — almost always **cold** in prod txs, because the engine's inline attacks use the internal `TypeCalcLib` and nothing else warms that account (2600 cold-account + ~700 for the first call, ~800 for a dual-type second); (3) a call back into `ENGINE.dealDamage` (~700). The fix mirrors what `dispatchStandardAttack` already proves out for inline moves: one Engine entrypoint `dispatchCustomAttack(attackerPlayerIndex, basePower, accuracy, volatility, moveType, moveClass, critRate, rng)` doing context-build + TypeCalcLib + damage core + deal-damage in a single internal frame. `_calculateDamage`'s body becomes that one call — the mon contracts call the library, so they just recompile, no per-mon code changes. It must replicate the library's semantics bit-for-bit (same rng stream, no attacker remix, same accuracy gate) so replays and the TS sim are unchanged. Costs: one IEngine addition, mon redeploys, and the mon tests that inject `TestTypeCalculator` for these moves migrate (type effectiveness moves to engine-side TypeCalcLib — the same tradeoff already accepted for inline StandardAttacks). ~3.5–5k per custom-attack execution.

Okay, let's do this. Ideally in a way where we can reuse code instead of just copying the same logic.

> **Status: approved (reuse requirement)** — `dispatchCustomAttack` must route through the existing `_dispatchStandardAttackInternal`/`_calculateDamageCore` internals, not copy them.

| **C7** | **StatusEffect/Tinderclaws/NightTerrors round-trip removals**: onApply KV re-read (engine calls shouldApply→onApply back-to-back; set flag unconditionally), Tinderclaws' redundant external shouldApply pre-check (engine re-runs it and silently no-ops), NightTerrors `tempRNG()` call whose value equals its own ignored hook parameter. | ~600–700 per status application; ~1.3–1.5k per Tinderclaws proc; ~400–500 per NightTerrors tick | none — one-line diffs |

Yes, let's do this.

| **C8** | **Targeted getters**: KO bitmap in `SwitchTargetLib.findRandomNonKOed` (bitmap invariant verified at both write sites); convert remaining `getEffects` array-builds to `getEffectData` (4 cited sites + ~9 activateOnSwitch idempotency guards equally convertible); additive `getMonBaseAndDelta` getter for the (base, delta) pairs (HoneyBribe, IronWall, GildedRecovery, ChainExpansion, PanicStatus/tick, NightTerrors, HardReset). | ~0.5–1.5k per converted site per occurrence; a few hundred–2k/turn in relevant matchups | interface (additive only) |

Let's explain this one more.

> **A (expanded):** Three independent additive-getter swaps — no existing signature changes, and parts 1–2 need zero Engine changes:
> 1. **KO bitmap in SwitchTargetLib**: `findRandomNonKOed` (random forced-switch targeting, used via PistolSquat/HardReset) loops `engine.getMonStateForBattle(IsKnockedOut)` per candidate mon — up to teamSize−1 staticcalls at ~700 each. The engine already maintains `getKOBitmap` in verified lockstep with the per-mon bools (both KO write sites update bitmap + bool together, including the revive path). Fetch the bitmap once, test bits locally: 2–5 calls → 1.
> 2. **`getEffects` → `getEffectData`**: several effects answer "is effect X on this mon / what's its data" by materializing the mon's FULL effect array via `getEffects` (~1.5–2.5k with the array build + ABI round-trip). The targeted `getEffectData(battleKey, target, mon, effectAddr)` (~700–900) already exists and is used at 6 sites; 4 more sites (BurnStatus degree scan, Tinderclaws, PostWorkout, ChainExpansion) plus ~9 ability `activateOnSwitch` idempotency guards are mechanical swaps. One subtlety to comment in the change: BurnStatus's last-match loop equals first-match because at most one burn instance can exist during the scan (the engine stores the new instance only after `onApply` returns). Two sites are NOT convertible (HardReset, MegaStarBlast filter on address AND data).
> 3. **`getMonBaseAndDelta`**: heal/stamina logic ("X% of max HP without overheal") needs a base stat AND its delta — today two ~700 staticcalls resolving the same storage pointers twice (HoneyBribe, IronWall, GildedRecovery, ChainExpansion, PanicStatus per tick, NightTerrors, HardReset). One additive getter returns `(base, sentinel-normalized delta)` in a single call.

Let's skip these for now.

> **Status: skipped.**

### Tier D — CPU one-tx + game layer

| ID | Finding | Verified savings | Break |
|----|---------|------------------|-------|
| **D1** | **Skip the dead top-of-turn move snapshot on non-emitting single-player turns** (batched CPU + PvP drain): the non-acting lane's transient is empty → falls back to a `config.pXMove` slot never written in these battles → cold 2100 on first flag sub-turn each direction. Gate on `emitMonMoves || flag >= 2`, reading the flag after the hook loop. | ~2.4–4.5k per batched tx + ~300–380 per additional flag sub-turn | none |

Okay let's do this as well if it's an unconditional win.

> **Status: approved (gated: unconditional win).**

| **D2** | **`executeGame` word-at-a-time calldata decode** (replace per-byte loop incl. 13-iteration salt loop with one `calldataload`+shift/mask per 19-byte turn). | ~few hundred–1k per turn decoded (compute-only) | none |

Okay, we can do this if it's an easy win.

> **Status: approved (gated: easy win).**

| **D3** | **onBattleEnd: lazy `_currentDay()`** (only consumed in the winner-side quest branch) **+ pack `questPool.length` with `_dayOffset`** in one slot. | ~2.1–2.3k per battle end | storage-layout (registry-internal) |

Let's do this if it's a verified win.

> **Status: approved (gated: verified win).**

### Evaluated and rejected (don't re-derive)

Ability-into-MonStats packing (240+160 > 256). Moves-as-mapping (keeps keccak per access). Reading
teams from the registry per-turn instead of snapshotting (breaks the immutable-snapshot semantics —
registry stats mutate mid-battle via exp/facets). MonState epoch tags to skip sentinel clearing
(every read site needs epoch gating). EIP-3529 refund mining on drained buffer slots/tombstones
(refund now < re-zeroing cost next battle; tombstones must stay nonzero for warmth). Selector
renaming (<300/turn, breaks every caller ABI). Truncated commit hashes (weakens equivocation
resistance; deprecated path anyway). BattleData's 44.2k/battle 0→nonzero floor (addresses must
survive for `getWinner`; only an events-only history view could remove it). **Multi-turn PvP batch
flush (was B1)**: the per-turn `MovesSubmitted` stage tx is the real-time spectator feed — batching
blinds spectators between flushes; design requirement beats the ~33k/turn. **Rematch team-commitment
fast-path (was A4)**: deferred — players change teams between games; revisit only with CPU-rematch
hit-rate data.

---

## 4. Suggested sequencing

1. ~~Bug fixes~~ **DONE** — BUG-1/2/3 fixed (+ regression tests); BUG-4 documented won't-fix.
2. **Tier A "battle lifecycle" series** (approved): A1 (flat rows, designed for future >4-move
   catalogs), A2 (fixed move arrays + zero-fill hygiene), A3 (non-shrinking free list), A5
   (remove `validateMatch` callback + error entirely), A6 (guarded alias + micro-batch), A7's
   remaining slot consolidation. A4 deferred (team churn).
3. **Tier B quick wins** (approved): B2 + B3 (measure-gated on prod-shaped benchmarks), B4
   (snapshot-gated), B6. B1 rejected (spectator visibility), B5 skipped (no prod traffic),
   B7 skipped (inliner risk).
4. **Tier C "status battles" series** (approved): C2 (+MegaStarBlast pairing), C3 (measure-gated),
   C4, C5, C6 (reuse internals — no logic copies), C7. C8 skipped. Build the prod-config
   burn+boost+switch benchmark first so the wins are measurable.
5. **Tier D** (approved, gated): D1 (unconditional win), D2 (easy win), D3 (verified win).

Measurement protocol per repo conventions: prod-config benchmarks (inline regen ruleset,
`validator == address(0)`, gacha hook attached — note current benchmarks omit the hook), one
change per intermediate commit, `git add` confirmed wins, full snapshot diff for anything touching
`Engine.sol` hot paths.
