# BetterCPU Aggressive Mode + Difficulty Escalation

## Context

`BetterCPU` (`src/cpu/BetterCPU.sol`) is a heuristic CPU whose decision tree is identical for every player it has ever faced. We want it to *learn* from a player within a session: if a human beats it, the next battle the CPU plays harder — picks a lead that punishes the player's lead, raises its tolerance for incoming damage before bailing out, and on a KO swaps to the best offensive matchup instead of the safest sponge. The CPU cycles through three escalating tiers — **Hell** (baseline), **Tartarus** (harder), **Diyu** (hardest) — and naturally drops back down again after the player breaks the streak. State is keyed by the human's address.

---

## Part 1 — Mode ladder (Hell / Tartarus / Diyu)

### Storage (BetterCPU.sol)

One slot per human address. Use the full 256 bits to leave headroom for Part 2.

```
mapping(address => uint256) public playerState;

// bits   0-7  : 8-bit rolling history (1 = CPU win, 0 = CPU loss); LSB = newest
// bits   8-9  : mode (0 HELL, 1 TARTARUS, 2 DIYU)
// bit   10    : diyuPriorLoss flag (CPU has already lost once in current DIYU stint)
// bits  11-14 : history length, capped at 8
// bits  15-...: reserved (Part 2 uses bits 15-22)
```

### Mode constants

```
uint8  constant MODE_HELL     = 0;
uint8  constant MODE_TARTARUS = 1;
uint8  constant MODE_DIYU     = 2;

uint256 constant SEVERE_DAMAGE_PCT_HELL     = 30;
uint256 constant SEVERE_DAMAGE_PCT_TARTARUS = 50;
uint256 constant SEVERE_DAMAGE_PCT_DIYU     = 60;   // +10% over TARTARUS (Part 2, H3)
```

(`SEVERE_DAMAGE_PCT` constant at line 36 is removed; threshold becomes a parameter to `_evaluateDefensiveSwitch`, picked per mode.)

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

Transition rules (full ladder — symmetric promote/demote with one sticky bit in DIYU):

```
HELL     + CPU won  → HELL
HELL     + CPU lost → TARTARUS

TARTARUS + CPU won  → HELL
TARTARUS + CPU lost → DIYU                       (diyuPriorLoss = 0)

DIYU     + CPU won  → TARTARUS                   (diyuPriorLoss = 0)
DIYU     + CPU lost, diyuPriorLoss == 0 → DIYU   (diyuPriorLoss = 1)
DIYU     + CPU lost, diyuPriorLoss == 1 → HELL   (diyuPriorLoss = 0)
```

DIYU is not a sink: two cumulative wins from a DIYU starting point bring the CPU back to HELL through TARTARUS, and two losses in DIYU also reset to HELL (the player has clearly figured the CPU out — cool off and try a fresh angle next time). One DIYU loss earns the CPU a second crack at the same tier; the `diyuPriorLoss` bit is the cheapest way to express that without a multi-bit consecutive-loss counter.

`winnerIndex` convention confirmed at Engine.sol:769 (`(winner == data.p0) ? 0 : 1`).

### Mode-aware behavior

Read mode once at the top of `calculateMove`:

```
uint8 mode = uint8((playerState[ctx.p0] >> 8) & 0x3);
bool aggressive = (mode == MODE_TARTARUS || mode == MODE_DIYU);
bool diyu = (mode == MODE_DIYU);
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
  Take threshold as a parameter. Caller picks by mode:
  `diyu ? SEVERE_DAMAGE_PCT_DIYU : (aggressive ? SEVERE_DAMAGE_PCT_TARTARUS : SEVERE_DAMAGE_PCT_HELL)`.

- **`_findBestDamageMove`**: NO CHANGE.

### Tartarus chaos roll

To make Tartarus harder to game-plan against without disturbing Diyu's deterministic scariness, Tartarus gets a **1/10 chance per turn to bypass the decision tree and pick uniformly from all valid options** for the current context.

At the very top of `calculateMove`, after `_calculateValidMoves` and mode resolution but before turn-0 / P1-KO branching:

```
if (mode == MODE_TARTARUS) {
    uint256 rng = _getRNG(battleKey);
    if (rng % 10 == 0) {
        return _pickRandomValidOption(rng, noOp, moves, switches);
    }
}
```

`_pickRandomValidOption` picks from the union `noOp ++ moves ++ switches`. Because `_calculateValidMoves` already filters by context (turn 0 / KO'd → no moves array; insufficient stamina → moves excluded), the union *is* the valid action set — no extra context-awareness needed.

```
function _pickRandomValidOption(
    uint256 rng,
    RevealedMove[] memory noOp,
    RevealedMove[] memory moves,
    RevealedMove[] memory switches
) internal pure returns (uint128, uint16) {
    uint256 total = noOp.length + moves.length + switches.length;
    // Use upper bits for selection so the 1/10 trigger and the index don't share entropy.
    uint256 idx = (rng >> 8) % total;
    if (idx < noOp.length) return (noOp[idx].moveIndex, noOp[idx].extraData);
    idx -= noOp.length;
    if (idx < moves.length) return (moves[idx].moveIndex, moves[idx].extraData);
    idx -= moves.length;
    return (switches[idx].moveIndex, switches[idx].extraData);
}
```

Notes:
- HELL stays fully deterministic. DIYU also stays fully deterministic — chaos would dilute D3/D4.
- The chaos roll *can* land on turn 0, randomizing the lead 10% of the time in Tartarus. Acceptable trade-off.
- `_getRNG` already exists (uses `_sampleRNG` + `nonceToUse++`); the chaos roll adds one RNG sample per Tartarus turn (~free).

### Tests (test/BetterCPUTest.sol)

Three goals — *not* full behavioral coverage:
1. **Baseline preserved** — covered by the existing BetterCPU test suite; the refactor must keep those green. No new "HELL still works" tests needed.
2. **Aggressive ramp visible** — one test per feature showing the harder mode picks differently from the easier mode on the *same* synthetic team. Without the paired baseline run, the test could pass vacuously.
3. **Never revert** — state machine doesn't deadlock; helpers handle sentinel HP, fresh mons, and empty option lanes without reverting; CPU doesn't suicide.

Naming: `testRamp_*` (ramp visible), `testSafety_*` (revert / suicide guard), `testStateMachine_*`, `testChaosRoll_*`.

#### State machine — 3 tests

- `testStateMachine_LadderClimbAndReset` — end-to-end integration through real battles: HELL → lose → TARTARUS → lose → DIYU → lose (flag set, mode unchanged) → lose → HELL. *Catches*: any broken transition, plus the `selectMove` → `_afterTurn` → `_recordResult` wiring. Subsumes per-transition unit tests.
- `testStateMachine_DiyuWinDropsToTartarus` — parameterized over `diyuPriorLoss ∈ {0, 1}`; assert mode = TARTARUS and flag = 0 after a DIYU win in either starting state. *Catches*: stuck in DIYU after a win; flag not cleared on demote.
- `testSafety_DrawDoesNotMutateState` — `winnerIndex == 2` early return; mode/flag/history all unchanged. *Catches*: corruption on incomplete or drawn battles.

#### Tartarus ramp — 2 paired tests + 1 safety

Each paired test runs HELL and TARTARUS on the same synthetic team and asserts both picks.

- `testRamp_LeadOffensiveVsDefensive` — team has candidate A (defensive-best, resists opp types, low offense) and B (SE offense, weak defense) constructed so HELL's `off - def` picks A and TARTARUS's `3*off - def` picks B. *Catches*: aggressive lead-score multiplier not wired in.
- `testRamp_DefensiveThresholdRaised` — incoming damage = 45% of max HP, materially-better switch candidate exists. HELL switches; TARTARUS stays. *Catches*: severe-damage threshold not mode-aware.
- `testSafety_AfterTurnSkipsOnDraw` — battle ends in draw mid-stream; assert `playerState[ALICE]` unchanged. *Catches*: state corruption on `winnerIndex == 2` execute path. (Belongs here rather than state machine because it crosses the full `selectMove` flow.)

#### Tartarus chaos roll — 2 tests

- `testChaosRoll_ModeAndTriggerGating` — table-driven over (mode, RNG % 10): only `(TARTARUS, 0)` yields the chaos pick; `(HELL, 0)`, `(DIYU, 0)`, and all `(*, non-zero)` rows use the heuristic. Constructed so heuristic pick X ≠ chaos pick Y, so non-firing is observable. Also exercises `MockCPURNG` wiring through `_getRNG`. *Catches*: chaos firing in wrong mode, firing on wrong trigger value, RNG plumbing broken.
- `testSafety_ChaosRollPicksFromUnionWithoutRevert` — context with `noOp.length = 1, moves.length = 2, switches.length = 3`. Force chaos to pick from each lane (3 RNG values targeting `idx ∈ {0, 1, 4}`). Assert the returned option matches the expected lane element each time. *Catches*: index-out-of-bounds in `_pickRandomValidOption`, lane stitching off-by-one.

---

## Part 2 — Diyu mode

Diyu sits above Tartarus and converts the lookahead the CPU already has into actual punishment. Tartarus reweights existing helpers; Diyu adds *new* capabilities that exploit information we already read but don't currently use.

### What we have to work with

**Free per-turn information** (already in CPUContext / IEngine getters):
- The player's revealed move this turn (`playerMoveIndex`, `playerExtraData`) — this is the lookahead.
- Every mon's full stats (HP, atk, def, spA, spD, speed, types) and stat deltas.
- Every mon's 4 move slots and their metadata (basePower, type, class, priority, stamina).
- Stamina, status, stat-delta, KO bitmaps for both sides.
- Turn count.

**What we don't have:**
- The player's *next* turn's intent.
- Any way to reason across battles other than what we persist.

**Persistent budget per player:** 256-bit slot, ~15 bits used by Part 1, ~241 free.

### Diyu feature set

Three independently-shippable features.

#### (D3) Win-condition lock-in — *free, no storage*

Two layered tweaks to defensive-switch evaluation in Diyu mode:

1. **Raised severe-damage threshold.** Pass `SEVERE_DAMAGE_PCT_DIYU` (60% — `SEVERE_DAMAGE_PCT_TARTARUS + 10`) into `_evaluateDefensiveSwitch`. Smaller incoming hits no longer scare the CPU into swapping out of a setup mon.
2. **KO-bypass.** Inside `_evaluateDefensiveSwitch`, before checking the threshold, peek at our outgoing damage estimate against the opponent's current HP. If our best damage estimate would KO opp **within ±10% tolerance** (`bestOutDmg >= oppCurrentHp * 90 / 100`) **and** `_weGoFirst(...)` is true, short-circuit `return (false, 0)` regardless of `damagePctToUs`. Mirror P2's KO check but compare with the looser threshold — a sweeper that's *almost* going to KO shouldn't get pulled.

Reuses `_findBestDamageMove`'s damage estimate (already computed by the caller) and the existing `_weGoFirst` helper. No new external calls.

#### (D4) Reveal-move free-turn detection — *free, no storage*

Currently P3 catches `playerMoveIndex == SWITCH_MOVE_INDEX` and P4 catches `playerMoveIndex == NO_OP_MOVE_INDEX`. Add a Diyu-only branch ("P4.5") that catches **opponent revealing a Self/Other move with `basePower == 0`** — i.e. a setup, heal, hazard, or buff move that doesn't threaten us this turn. The move's class and base power are already cached in `_evaluateDefensiveSwitch`'s opener; lift that decode just above P5 so P4.5 can read it.

In P4.5, run a decision tree biased by "momentum":

```
momentum = (ourAliveCount > theirAliveCount)
        || (ourAliveCount == theirAliveCount && ourActiveStamina >= theirActiveStamina)
```

Order of options:
1. **KO** — already caught by P2 upstream; nothing extra here.
2. **Switch-in move** (if configured for active mon and not yet used) — same as P3/P4.
3. **2HKO check**: if `bestEstimatedDamage * 2 >= oppCurrentHp`, take the damage move (we can finish in 2 turns and the free turn pays for itself).
4. **Setup move** (if configured for active mon, not yet used this switch-in, and `momentum` is true) — see (D5).
5. **Offensive/defensive switch**: run `_offensiveMatchupScore` against the opponent's active mon; pick the candidate that beats the matchup. Falls through to P5/P6 if no candidate clears the existing matchup score by ≥ `SWITCH_THRESHOLD`.
6. **Default**: best damage move (P6 fallback).

The KO short-circuit from (D3) still applies inside P5 if we fall through.

#### (D5) Per-mon setup-move config — *minimal storage, reuses `monConfig`*

Extend the existing `monConfig[monIndex][key]` map with a new key:

```
uint256 constant CONFIG_SETUP_MOVE = 2;       // stores (moveIndex + 1); 0 = unset
```

Set once at deploy via `setMonConfig(monIndex, CONFIG_SETUP_MOVE, slot + 1)` — sparse, one cold SLOAD per active-mon-turn, exact same shape as the existing `CONFIG_PREFERRED_MOVE` / `CONFIG_SWITCH_IN_MOVE` entries.

Once-per-switch-in usage tracking: add a sibling bitmap to `switchInMoveUsedBitmap`. To avoid bloating per-battle storage, **pack both into one slot**:

```
mapping(bytes32 => uint256) public cpuMoveUsedBitmap;
// bits   0-7  : switch-in move used per monIndex   (was switchInMoveUsedBitmap)
// bits   8-15 : setup move used per monIndex
```

Rename the existing field to `cpuMoveUsedBitmap` and update all touch sites (`|= 1 << monIndex`, `& 1 << monIndex`, `&= ~(1 << monIndex)`) to take a base offset (0 for switch-in, 8 for setup). MONS_PER_TEAM caps at 8 per the validator, so both lanes fit cleanly.

**Clear semantics on re-entry.** When the CPU switches a mon back into play (the four existing clear sites: turn-0 lead, P1 KO revenge, P5 defensive switch, P6 no-moves fallback), clear the switch-in lane (`bit monIndex`) unconditionally — same as today. Clear the setup lane (`bit 8 + monIndex`) **only if the incoming mon's current HP is above 50% of its max HP**. A low-HP mon coming back in is probably about to die; spending its turn on a stat-boost / hazard / heal is a bad trade, so we leave the "setup already used" bit set and let the D4 tree fall through to step 5/6 (matchup switch / damage).

Extract a helper so the gate lives in one place:

```
function _clearMoveUsedBitsOnSwitchIn(bytes32 battleKey, uint256 monIdx) internal {
    uint256 bitmap = cpuMoveUsedBitmap[battleKey];
    bitmap &= ~(uint256(1) << monIdx);                         // always clear switch-in lane
    uint32 maxHp = ENGINE.getMonValueForBattle(battleKey, 1, monIdx, MonStateIndexName.Hp);
    int32 hpDelta = ENGINE.getMonStateForBattle(battleKey, 1, monIdx, MonStateIndexName.Hp);
    if (hpDelta == CLEARED_MON_STATE_SENTINEL) hpDelta = 0;
    int256 currentHp = int256(uint256(maxHp)) + int256(hpDelta);
    if (currentHp * 2 > int256(uint256(maxHp))) {              // strictly above 50%
        bitmap &= ~(uint256(1) << (monIdx + 8));               // clear setup lane
    }
    cpuMoveUsedBitmap[battleKey] = bitmap;
}
```

Cost: one extra `getMonValueForBattle` + one `getMonStateForBattle` per CPU switch (≤4× per battle in normal play, plus once at turn 0). Acceptable. Replaces the four inline `switchInMoveUsedBitmap[battleKey] &= ~(1 << uint256(extraData))` lines.

**Storage cleanup follow-up** (optional, separate PR): `cpuMoveUsedBitmap` currently accumulates one SSTORE-shaped slot per battle forever. Following the same pattern as `Engine` and `DefaultMatchmaker`, BetterCPU can extend `MappingAllocator` and key the bitmap through `_getStorageKey(battleKey)`, then free the key on battle end via the existing `_afterTurn` hook (or an `OnBattleEnd` engine hook). Out of scope for Part 2 — call it out and ship it as a cleanup if/when storage churn becomes a concern.

**Setup move slots** (from `script/SetupMons.s.sol`):

| Mon | Move | Slot | Why |
|---|---|---|---|
| Inutia | Initialize | 1 | +50% Atk/SpAtk, transfers on switch — already once-per-switch-in by design |
| Malalien | Triple Think | 0 | +75% SpAtk, strongest single-turn setup in roster |
| Pengym | Deadlift | 1 | +50% Atk/Def, hybrid |
| Iblivion | Loop | 1 | +15/30/40% all stats by Baselight stacks (turn 2+) |
| Aurox | Iron Wall | 2 | Damage regen + 25% HP first-use; pairs with Bull Rush recoil |
| Ekineki | Nine Nine Nine | 2 | 90% crit next turn; one-shot offensive amplifier |
| Embursa | Heat Beacon | 2 | +1 priority next turn + burn opp; tag for priority follow-up |
| Nirvamma | Hard Reset | 0 | Trap: opp's next rest is punished, our next rest swaps; momentum tool |

Mons not in the table have no setup move — (D4) skips step 4 and falls through to step 5/6.

### Storage layout after Part 1 + Part 2

```
playerState[address]:
  bits   8-9  : mode (0 HELL, 1 TARTARUS, 2 DIYU)
  bit   10    : diyuPriorLoss flag

monConfig[monIndex][key]:
  key 0 = CONFIG_PREFERRED_MOVE   (unchanged)
  key 1 = CONFIG_SWITCH_IN_MOVE   (unchanged)
  key 2 = CONFIG_SETUP_MOVE       (new)

cpuMoveUsedBitmap[battleKey]:
  bits   0-7  : switch-in used per monIndex
  bits   8-15 : setup used per monIndex
```

### Diyu-only behavior switches

In `calculateMove`, after computing `mode` and `aggressive`:

```
bool diyu = (mode == MODE_DIYU);
```

- (D3) Inside `_evaluateDefensiveSwitch`: caller picks the Diyu threshold; helper additionally short-circuits if Diyu and outgoing-damage estimate within 10% of `oppCurrentHp` and `_weGoFirst`.
- (D4) Between P4 and P5 (new "P4.5"): if `diyu` and the opponent's revealed move is Self/Other with `basePower == 0`, enter the free-turn decision tree above.
- (D5) The (D4) tree consults `monConfig[activeMonIndex][CONFIG_SETUP_MOVE]` and the upper lane of `cpuMoveUsedBitmap[battleKey]`.

### Tests for Diyu (additive)

State-machine tests for Diyu are consolidated in Part 1's `testStateMachine_LadderClimbAndReset` — don't duplicate. The tests below are Diyu-only behaviors. Each ramp test runs paired TARTARUS + DIYU on the same synthetic team.

#### (D3) Win-condition lock-in — 3 tests

- `testRamp_DiyuRaisedThresholdAt55Pct` — incoming 55%, no outgoing-KO conditions. TARTARUS switches (>50); DIYU stays (<60). *Catches*: threshold not raised, or raised too far.
- `testRamp_DiyuKOBypassStaysInForTheKO` — outgoing damage ≥ 90% of opp current HP, incoming 65%, CPU outspeeds. TARTARUS switches; DIYU stays and attacks. *Catches*: KO-bypass missing or wrong tolerance.
- `testSafety_DiyuKOBypassRequiresOutspeed` — same as above, opp outspeeds. DIYU switches. *Catches*: CPU staying in for a KO it won't reach — suicide.

#### (D4) Free-turn detection — 3 tests

- `testRamp_DiyuFreeTurnGating` — table-driven over (mode, opp move):
  - (DIYU, Other bp=0) → enters D4
  - (DIYU, Physical bp>0) → skips D4, normal P5
  - (TARTARUS, Other bp=0) → skips D4
  Constructed so D4 outcome differs from P5 outcome on this team. *Catches*: class/bp gate wrong, mode gate wrong.
- `testRamp_DiyuFreeTurnSetupVsMatchupSwitch` — opp reveals Other bp=0, setup move configured for active mon, `bestDmg * 2 < oppCurrentHp`. Two runs on the same setup:
  - momentum=true (CPU 4 alive, opp 3) → DIYU plays setup move.
  - momentum=false (CPU 3 alive, opp 4) and switch candidate beats current matchup by ≥ `SWITCH_THRESHOLD` → DIYU switches.
  *Catches*: tree ordering inverted, momentum computation wrong, switch candidate ranking broken.
- `testSafety_DiyuFreeTurn_2HKOBeatsSetup` — momentum=true, setup configured, but `bestDmg * 2 >= oppCurrentHp`. DIYU plays best-damage; setup lane bit NOT set after the turn. *Catches*: setup priority blocking a winning damage trade.

#### (D5) Setup bitmap + HP-gated clear — 3 tests

- `testDiyu_SetupOncePerSwitchIn` — turn N setup plays (lane bit `8 + monIdx` set). Turn N+1: same opp 0-power reveal, momentum still true, no switch in between. DIYU does NOT replay setup; falls through to step 5/6. *Catches*: bit not being set, or D4 step 4 not checking it.
- `testRamp_HpGatedClearAbove50ClearsBelowDoesNot` — single test, two scenarios on the same setup:
  - Mon switches out at full HP, switches back at 80% HP → setup bit cleared, setup playable again on next free-turn.
  - Mon takes damage to 50% before switching back → bit stays set, setup not playable.
  *Catches*: HP gate inverted, missing, or boundary off-by-one (strict `>` not `≥`).
- `testSafety_SwitchInClearsAndFreshMonNoRevert` — two assertions:
  - Switch-in lane (`bit monIdx`) clears on every re-entry regardless of HP (verify at 10% HP); setup lane is independently gated.
  - Fresh mon (never switched in, HP delta == `CLEARED_MON_STATE_SENTINEL`) runs through `_clearMoveUsedBitsOnSwitchIn` without reverting.
  *Catches*: switch-in lane accidentally tied to HP gate; sentinel HP delta not handled.

---

## Verification

1. `forge build` (timeout 360000ms — see CLAUDE memory note on build timeout)
2. `forge test --match-contract BetterCPUTest -vvv`
3. Full suite: `forge test` to confirm no regression in other CPU tests, engine tests, or gas snapshots
4. Inspect `snapshots/BetterCPUInlineGasTest.json` and `snapshots/EngineGasTest.json` — `_afterTurn` adds ~10 gas/turn across all CPUs; flag if larger. The (D4) lookahead branch adds another ~30 gas in Diyu only; flag if it leaks into the HELL/TARTARUS paths.