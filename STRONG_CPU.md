# BetterCPU Aggressive Mode + Difficulty Escalation

## Context

`BetterCPU` (`src/cpu/BetterCPU.sol`) is a heuristic CPU whose decision tree is identical for every player it has ever faced. We want it to *learn* from a player within a session: if a human beats it, the next battle the CPU plays harder — picks a lead that punishes the player's lead, raises its tolerance for incoming damage before bailing out, and on a KO swaps to the best offensive matchup instead of the safest sponge. After one aggressive win, it gets one more "bonus" aggressive battle, then resets to default. State is keyed by the human's address.

`_findBestDamageMove` already routes through `AttackCalculator._calculateDamageFromContext` with `TYPE_CALC`, so type effectiveness already scales the damage score — no change there.

The user explicitly rejected the `IEngineHook` route. Battle outcome is detected at the end of `CPUMoveManager.selectMove` by re-reading `winnerIndex` after `executeWithMoves`/`executeWithSingleMove`. There is no real "draw" path in the engine — `_handleGameOver` only fires when `winnerIndex` is 0 or 1; `winnerIndex == 2` post-execute means the game is still live (Engine.sol:708, 769).

---

## Part 1 — Aggressive Mode (the agreed design)

### Storage (BetterCPU.sol)

One slot per human address. Use the full 256 bits to leave headroom for Part 2.

```
mapping(address => uint256) public playerState;

// bits   0-7  : 8-bit rolling history (1 = CPU win, 0 = CPU loss); LSB = newest
// bits   8-10 : mode (0 DEFAULT, 1 AGGRESSIVE, 2 AGG_BONUS, 3 HARD — see Part 2)
// bits  11-14 : history length, capped at 8
// bits  15-...: reserved (Part 2 uses bits 15-30)
```

### Mode constants

```
uint8  constant MODE_DEFAULT    = 0;
uint8  constant MODE_AGGRESSIVE = 1;
uint8  constant MODE_AGG_BONUS  = 2;
uint8  constant MODE_HARD       = 3;        // Part 2

uint256 constant SEVERE_DAMAGE_PCT_DEFAULT    = 30;
uint256 constant SEVERE_DAMAGE_PCT_AGGRESSIVE = 50;
```

(`SEVERE_DAMAGE_PCT` constant at line 36 is removed; threshold becomes a parameter to `_evaluateDefensiveSwitch`.)

### End-of-turn hook (CPUMoveManager.sol)

Add to `CPUMoveManager`:

```
function _afterTurn(bytes32 battleKey, address p0) internal virtual {}
```

Refactor `selectMove` so all three execute paths fall through to a single `_afterTurn(battleKey, p0)` call before returning. The early returns above the dispatch (`msg.sender != p0`, `winnerIndex != 2`) skip the hook by construction, so when `_afterTurn` runs, the pre-execute `winnerIndex` was 2 — no "already recorded" guard needed.

Cost: ~10 gas/turn for every CPU subclass — accepted. Verify `BetterCPUInlineGasTest.sol` and `EngineGasTest.sol` snapshots after.

### State machine (BetterCPU._afterTurn)

```
function _afterTurn(bytes32 battleKey, address p0) internal override {
    (, uint8 winnerIndex,) = ENGINE.getCPURouteContext(battleKey);
    if (winnerIndex == 2) return;
    _recordResult(battleKey, p0, winnerIndex == 1);   // CPU is p1
}
```

Transition rules (Part 1 only — Part 2 extends with HARD):

```
DEFAULT    + CPU won  → DEFAULT
DEFAULT    + CPU lost → AGGRESSIVE
AGGRESSIVE + CPU won  → AGG_BONUS
AGGRESSIVE + CPU lost → DEFAULT
AGG_BONUS  + any      → DEFAULT
```

`winnerIndex` convention confirmed at Engine.sol:769 (`(winner == data.p0) ? 0 : 1`).

### Mode-aware behavior

Read mode once at the top of `calculateMove`:

```
uint8 mode = uint8((playerState[ctx.p0] >> 8) & 0x7);
bool aggressive = (mode == MODE_AGGRESSIVE || mode == MODE_AGG_BONUS || mode == MODE_HARD);
```

Plumb `aggressive` into the three branch helpers:

- **`_selectLead(battleKey, opponentMonExtraData, switches, aggressive)`** (line 383)
  Replace `score = offensiveScore - defensiveScore` with
  `score = aggressive ? (3 * offensiveScore - defensiveScore) : (offensiveScore - defensiveScore)`.

- **`_selectBestSwitch(battleKey, opponentMonIndex, opponentMoveIndex, switches, aggressive)`** (line 444)
  When `aggressive`, replace the "least damage taken" loop with an offensive-matchup loop. Extract a helper `_offensiveMatchupScore(battleKey, candidateMonIndex, opponentMonIndex)` mirroring the offensive half of `_selectLead` (sum of `TYPE_CALC.getTypeEffectiveness(candType_i, oppType_j, 10)` over both type pairs). Pick max. Keep the existing `canEstimate=false` early-return.
  Two call sites:
  - line 86 (P1 KO revenge) → pass `aggressive`.
  - line 201 (P6 fallback when no usable moves left) → pass `false`. Stuck-out-of-moves is not a revenge scenario.

- **`_evaluateDefensiveSwitch(... , uint256 severeDamagePct)`** (line 616, threshold at line 653)
  Take threshold as a parameter. Caller passes
  `aggressive ? SEVERE_DAMAGE_PCT_AGGRESSIVE : SEVERE_DAMAGE_PCT_DEFAULT`.

- **`_findBestDamageMove`**: NO CHANGE.

### Tests (test/BetterCPUTest.sol)

State machine / packing:
- `testStateMachine_DefaultLossToAggressive`
- `testStateMachine_AggressiveWinToBonus`
- `testStateMachine_AggressiveLossToDefault`
- `testStateMachine_BonusAfterWinResetsToDefault`
- `testStateMachine_BonusAfterLossResetsToDefault`
- `testHistoryShiftAndCap` — play 10 battles, assert length caps at 8 and LSB pattern matches.

Behavior (synthetic teams via `TestTypeCalculator.setTypeEffectiveness` so default and aggressive diverge):
- `testAggressiveLeadPicksOffensiveCandidate`
- `testAggressiveRevengeKOPicksOffensiveMatchup`
- `testAggressive50PctThresholdSkipsDefensiveSwitch`
- `testAfterTurnNotCalledOnEarlyReturn`

---

## Part 2 — Brainstorm: HARD difficulty

The goal: a tier above AGG_BONUS that triggers when the player keeps winning. AGG/AGG_BONUS reweights the existing helpers; HARD adds *new* capabilities that exploit information we already have but don't currently use.

### What we have to work with

**Free per-turn information** (already in CPUContext / IEngine getters):
- The player's revealed move this turn (`playerMoveIndex`, `playerExtraData`) — this is the lookahead.
- Every mon's full stats (HP, atk, def, spA, spD, speed, types).
- Every mon's 4 move slots and their metadata (basePower, type, class, priority, stamina).
- Stamina, status, stat-delta, KO bitmaps for both sides.
- Turn count.

**What we don't have:**
- The player's *next* turn's intent.
- Any way to reason across battles other than what we persist.

**Persistent budget per player:** 256-bit slot, ~15 bits used by Part 1, ~241 free. Per-(player, mon) histograms are out of budget at scale; per-player aggregates are cheap.

### Proposed HARD tier features

Each is independently shippable. Pick the subset we want.

#### (H1) Per-player lead memory — *uses storage*

Persist `lastSeenPlayerLead` (8 bits, opponent's mon ID at turn 0) across battles. When mode == HARD, override the turn-0 lead score: pick the candidate whose offensive matchup vs `lastSeenPlayerLead` is highest. Falls back to the standard aggressive scoring when:
- We've never seen this player (`lastSeenPlayerLead == 0` and history length == 0), or
- The player swapped openings (we still pre-position, and the standard turn-1 logic recovers).

Cost: 8 bits. Update at battle end via `getBattleEndContext().p0ActiveMonIndex` (active at end ≠ lead, but a separate read at turn 0 is needed). Cleaner: capture at turn 0 inside `calculateMove` (`ctx.turnId == 0`) using `playerExtraData`, write to storage there. One extra SSTORE per battle. **Highest single-feature impact** — turns rematches into a stacked deck.

Storage bits: **15-22**.

#### (H2) Last-mon kamikaze — *free, no storage*

When `popcount(p0KOBitmap) == p0TeamSize - 1`, opponent has only their active mon left. In HARD mode:
- Skip defensive switching entirely (P5).
- Skip "preferred move" / "switch-in move" preferences (P6).
- Force the highest-damage move regardless of incoming damage.

Trivial to implement, big gain on closing battles. Especially valuable because the existing logic over-defends when it's already won.

#### (H3) Lookahead-driven counter-switch — *free, no storage*

P5 today only fires when `damagePctToUs >= SEVERE_DAMAGE_PCT`. HARD adds a second trigger using the lookahead move type:
- Find a switch candidate that **resists** the player's revealed move type (effectiveness < 1.0x against it).
- AND has a super-effective move (≥ 2.0x) against the player's active mon.
- AND the candidate's expected damage taken from the revealed move is < 25%.

If such a candidate exists, switch even when DEFAULT/AGGRESSIVE wouldn't. This converts the free info into a guaranteed tempo swing.

#### (H4) Stamina-race exploitation — *free, no storage*

Read opponent stamina via `getMonValueForBattle(... MonStateIndexName.Stamina)`. If opponent stamina ≤ 1 (forces them to rest next turn) AND we have a low-stamina move within the SIMILAR_DAMAGE_THRESHOLD band, prefer the low-stamina move. Goal: stay attacking while they rest. Already partially captured by the existing stamina tiebreak in `_findBestDamageMove`, but HARD escalates the bias when the opponent is one move from forced-rest.

#### (H5) Setup-on-safe-turns — *free, no storage*

Today P3/P4 (opponent switching/resting) just attack. HARD adds: if our active mon has a setup move (basePower == 0 with a known stat-boosting effect), use it on these safe turns instead of attacking. Detection is brittle without an explicit "is setup" flag — would require either reading the move's `EFFECT` address and matching against a registered set of setup effects, or extending move metadata. Probably out of scope unless we add a `MoveMeta.isSetup` bit.

**Not recommended for the first HARD ship** — execution cost is high relative to other features.

#### (H6) Opponent-side setup detection — *free, no storage*

Read all four of the player active mon's move slots. If any is a known setup move (same detection problem as H5), bias toward switching out before they can capitalize. Same caveat as H5.

#### (H7) Consecutive-loss escalation — *uses storage*

Persist `consecCpuLosses` (4 bits, cap 15). Increment on CPU loss, reset on CPU win. Mode promotion:
- AGGRESSIVE + lost AND `consecCpuLosses >= 2` → HARD (instead of DEFAULT)
- HARD + won → AGG_BONUS (and reset losses)
- HARD + lost → HARD (stays angry; capped by cap)

This makes the CPU stick on HARD against a clearly-better player rather than oscillating.

Storage bits: **23-26**.

### Recommended HARD ship

The combination (H1) + (H2) + (H3) + (H7) is the sharpest contrast for the implementation cost:
- H1 turns rematches into a stacked deck.
- H2 closes out winning battles cleanly.
- H3 weaponizes the free lookahead in a way DEFAULT/AGGRESSIVE don't.
- H7 keeps the CPU on HARD when it should be.

H4 is cheap to add later if HARD still feels weak. H5/H6 wait until move metadata can flag setup moves cleanly.

### Storage layout after Part 1 + recommended Part 2

```
bits   0-7  : 8-bit rolling history
bits   8-10 : mode (0 DEFAULT, 1 AGGRESSIVE, 2 AGG_BONUS, 3 HARD)
bits  11-14 : history length, capped at 8
bits  15-22 : lastSeenPlayerLead (mon ID, 0 = none)
bits  23-26 : consecCpuLosses, capped at 15
bits  27-... reserved
```

### State machine (full, with HARD)

```
DEFAULT    + won  → DEFAULT      (consecLosses = 0)
DEFAULT    + lost → AGGRESSIVE   (consecLosses += 1)
AGGRESSIVE + won  → AGG_BONUS    (consecLosses = 0)
AGGRESSIVE + lost → if consecLosses >= 2 then HARD else DEFAULT (consecLosses += 1)
AGG_BONUS  + won  → DEFAULT      (consecLosses = 0)
AGG_BONUS  + lost → AGGRESSIVE   (consecLosses += 1)
HARD       + won  → AGG_BONUS    (consecLosses = 0)
HARD       + lost → HARD         (consecLosses += 1, capped)
```

### HARD-only behavior switches

In `calculateMove`, after computing `mode` and `aggressive`:

```
bool hard = (mode == MODE_HARD);
```

Branches:
- (H1) Inside `_selectLead`: if `hard && lastSeenLead != 0`, use `_offensiveMatchupScore(battleKey, candidateMonIndex, lastSeenLead)` as the dominant score; tiebreak with the standard score.
- (H2) Before P5: if `hard` and opponent has only the active mon left, jump straight to `_findBestDamageMove`, skipping `_evaluateDefensiveSwitch` and the preferred-move/switch-in-move logic.
- (H3) Inside P5 evaluation: in addition to the existing "switch when severe damage" trigger, fire when the lookahead-counter conditions described in H3 are met.

### Tests for HARD (additive)

- `testHard_LeadCountersLastSeenLead` — first battle establishes `lastSeenPlayerLead`; second battle (CPU is in HARD via H7) picks a different turn-0 switch than aggressive would.
- `testHard_LastMonKamikazeIgnoresDefensiveSwitch` — opponent down to 1 mon, scenario where AGGRESSIVE would still defensive-switch; HARD attacks.
- `testHard_LookaheadCounterSwitchFiresBelowSevereThreshold` — `damagePctToUs` < 50%, but a switch candidate resists the move and has SE counter; HARD switches.
- `testHard_PromotedAfterTwoConsecLosses` — two CPU losses in a row out of AGGRESSIVE → HARD; one in non-AGGRESSIVE state doesn't.
- `testHard_ResetsToAggBonusOnWin`.

---

## Verification

1. `forge build` (timeout 360000ms — see CLAUDE memory note on build timeout)
2. `forge test --match-contract BetterCPUTest -vvv`
3. Full suite: `forge test` to confirm no regression in other CPU tests, engine tests, or gas snapshots
4. Inspect `snapshots/BetterCPUInlineGasTest.json` and `snapshots/EngineGasTest.json` — `_afterTurn` adds ~10 gas/turn across all CPUs; flag if larger.

## Risks

- `CPUMoveManager.selectMove` restructure must preserve early-return semantics so the hook never fires on `NotP0` revert or `winnerIndex != 2` early return. The cleanest shape is one trailing `_afterTurn(battleKey, p0)` call with the three execute branches reachable via if/else (no early `return` from inside them).
- H1 (lead memory) writes during turn 0 of every battle — one extra SSTORE on the first turn, hot slot so cheap, but verify it doesn't show up in inline-engine gas tests.
- H3 (lookahead counter-switch) reads opponent move metadata which is already cached locally for the existing P5 path — no extra calls if we plumb the existing `oppMoveSlot`/`oppMoveClass` through.
- Aggressive `_selectBestSwitch` reuses lead's offensive-only scoring; existing tests that assert "least damage taken" behavior in DEFAULT mode keep passing because `aggressive=false` preserves old logic.
