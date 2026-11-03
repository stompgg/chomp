# Engine gas audit — 2026-11-02

**Conclusion:** compiling with solar is the largest available lever. Six unconditional
source fixes are already applied. A further batch of inline tags saves about 4% more on
solar for about 5 KB of bytecode. Compute responds to inlining; state does not. PvP is dominated by first-touch
storage cost, so further PvP savings need fewer distinct slots per turn, which means layout
work rather than local tidying. See `PLAN_ENGINE_GAS_REWRITE.md` for the rewrite plan.

All A/Bs ran in scratch copies. Only the six fixes under "Applied" reached `src/`.

This builds on `docs/engine-gas-audit-2026-09-05.md`. Its negative results still stand.

## Method

Forge 1.9.0, solar 0.3.0-dev (`a2b44354`), default profile (`optimizer_runs` 3000), isolate
on unless stated. Each top-level call is then its own transaction, as in production.

Forge's internal-function decode does not work on solar output, so opcode data came from
outside the test process. In a scratch copy, the test calls `vm.dumpState` just before the
reused batch; that state seeds a throwaway `anvil --init`; `debug_traceCall` replays one real
transaction. The singles trace reproduces the mainnet result: 27 turns, winner p1. Solar's
`sourceMap` then maps each opcode to an `Engine.sol` line. Engine frames are taken as odd call
depths, and the total matches external-trace Engine gas to within 2%.

`CALL` overhead is reported cost minus the child frame's starting gas. Using either raw
`gasCost` or the parent/child gas difference is badly wrong.

## Baseline

| KPI (solar, isolate on) | Gas |
|---|---:|
| Singles replay, reused key (27 turns) | 1,787,775 |
| Singles replay, first-ever key | 2,582,702 |
| Doubles replay, reused key (10 turns) | 1,106,227 |
| No-op turn | 19,374 |
| PvP, 5 turns, one tx each | 577,430 |
| Battle start, recycled key, same teams | 571,856 |
| Battle start, first-ever key | 1,591,213 |

Engine runtime: 56,157 bytes.

### Solar against solc

Same frozen source and settings, isolate on, before the small wins below. Chart:
`planning/SOLAR_VS_SOLC.html`.

| | solc 0.8.34 | solar | Change |
|---|---:|---:|---:|
| Cold build of 299 files | 348.9 s | 1.65 s | about 210× faster |
| Build peak memory | 4.76 GB | 0.33 GB | -93% |
| Runtime bytes, all 114 contracts | 373,202 | 227,607 | -39.0% |
| Engine runtime bytes | 91,520 | 56,157 | -38.6% |
| Gas, all 691 tests | 2,357,349,754 | 1,902,280,198 | -19.3% |
| Singles, reused key | 2,226,021 | 1,787,775 | -19.7% |
| Singles, first-ever key | 3,020,313 | 2,582,702 | -14.5% |
| Doubles, reused key | 1,259,612 | 1,106,227 | -12.2% |
| Battle start, recycled key | 624,256 | 571,856 | -8.4% |
| No-op turn | 21,096 | 19,374 | -8.2% |
| PvP, 5 turns | 620,482 | 577,430 | -6.9% |

Every one of the 114 contracts is smaller on solar, and solar is cheaper in 690 of 691 tests.
The exception is `test_rollDistributionMatchesTheWei` at +40%. Both compilers pass all 691.
Test gas includes the test contracts, which were compiled the same way.

Compile times use `--no-dynamic-test-linking`, 5 runs on solar and 1 on solc. Plain
`forge build` takes 9m34s on solc: forge first spends about 3m20s on a dynamic-linking pass that
fails with stack too deep, then retries. Solar takes about 2.1 s.

With isolate off on the pinned replay, singles is 2,060,977 on solc and 1,622,731 on solar
(-21.3%). solc's isolate-off no-op turn reproduces the committed 18,738 exactly.

Solar's codegen still reports itself as experimental. All 691 tests pass on it, but passing
tests are not a compiler audit.

## How real games are played

Taken from the event payloads of the 2,474 singles turns in the 86 mainnet CPU batches in
`test/fixtures/gas-audit/mainnet-2026-09-05.json`.

| Both sides' actions | Share of turns |
|---|---:|
| move + move | 40.9% |
| move + switch | 19.2% |
| move + rest | 16.9% |
| rest + switch | 15.7% |
| switch + switch | 4.7% |
| rest + rest | 2.6% |

By action: 58.9% move, 22.2% switch, 18.9% rest. So a both-sides-rest fast path would serve
2.6% of turns. The no-op KPI is useful as a floor but is a poor proxy for gameplay.

Sides send in 3.57 of 4 mons on average, and 72% use all four.

Across those games Engine execution is ~100k gas per turn, and receipts add only ~117k per
transaction. Execution is what matters. The largest callback exposures are `addStatBoost`
(13.25%), `addEffect` (8.68%), `dispatchStandardAttack` (5.67%), `switchActiveMonForSlot`
(4.07%) and `dealDamage` (4.04%). These are inclusive and can overlap.

One game costs roughly 2.36M: 572k to start plus 1.79M to play. Battle start is about 24%.

## Where the gas goes

Engine self-gas, reused batch. Mechanics contracts are only 3.7–6.7% of gas.

| Class | Singles | Doubles | No-op game |
|---|---:|---:|---:|
| Stack (`PUSH`/`DUP`/`SWAP`/`POP`) | 22.4% | 25.0% | 24.0% |
| Storage reads | 22.9% | 26.3% | 29.9% |
| Storage writes | 15.6% | 12.1% | 2.2% |
| Jumps | 11.5% | 12.1% | 14.1% |
| Arithmetic and other | 10.2% | 10.8% | 8.2% |
| Transient | 7.7% | 5.5% | 14.3% |
| Keccak | 3.6% | 3.4% | 4.3% |
| Memory | 2.7% | 2.9% | 1.8% |
| External call overhead | 2.4% | 1.5% | 1.1% |

Call overhead is small. Plain compute (stack, jumps, arithmetic) is 44–48%, and 12–13% of
Engine gas sits in compiler-generated code.

### State footprint per turn

Per turn in the singles replay: **17.3 distinct slots touched, 7.2 written** (maximum 26 and
15). If each turn were its own transaction, first-touch cost is about 57k, roughly half of the
115k PvP turn. This is why inlining cuts batches by 5% but PvP by only 1%.

Singles writes per game: `hpDelta` 49, stamina 73 (41 regen, 32 deduct), the BattleData turn
word 26, effect data 26, packed `MonState` boosts 21, effect headers 16.

### Redundant access: treat with care

| | Singles | Doubles | No-op game |
|---|---:|---:|---:|
| `SLOAD`s | 2,568 | 1,758 | 1,080 |
| First read of the slot | 56 | 45 | 12 |
| Re-read, no call since | 1,500 | 1,211 | 800 |
| Re-read across a call, unchanged | 1,012 | 502 | 268 |
| `SSTORE`s | 361 | 136 | 39 |
| Mergeable with an earlier write | 71 | 21 | 0 |
| Same-value | 27 | 7 | 0 |

**These are not available savings.** Many "redundant" reads are the read half of a packed-field
write, which a local variable cannot remove, and solar already merges some of the rest. Two
single-read patches changed nothing at all. This metric finds candidates; only full-game A/Bs
establish savings.

### Battle start

563,839 gas traced, recycled key, same teams.

| Region | Gas |
|---|---:|
| Team registry `getTeams` (mock in this test) | 228,423 |
| Matchmaker frame | 64,989 |
| `_storeTeam` snapshot (48 slots) | ~106,000 |
| New permanent `battleData[battleKey]` slots (2) | 40,000+ |
| Other first-writes (compiler-attributed) | 25,000 |

40 of the snapshot writes store an unchanged value at 2,200 each. The registry figure is
**not** production: `GachaTeamRegistry` differs from the mock.

## Measured A/Bs

Cumulative, in order, against the baseline. All 691 tests passed at every step.

| Step | Singles | Doubles | No-op | PvP | Bytes |
|---|---:|---:|---:|---:|---:|
| Pass `battle` into regen | -0.2% | 0.0% | -0.7% | -0.1% | 56,148 |
| One-read regen | no change | | | | |
| One-read stamina deduct | no change | | | | |
| No `hpDelta` re-read after write | -0.2% | 0.0% | -0.7% | -0.2% | 56,131 |
| One `MonState` read in `_handleMove` | -0.5% | 0.0% | -1.7% | -0.3% | 56,130 |
| `rngOracle` gate in spare flag bit | -0.5% | 0.0% | -2.3% | -2.1% | 56,141 |
| Inline tags on boost helpers | -0.9% | 0.0% | -2.3% | -2.1% | 57,103 |
| Inline tags on 14 leaf helpers | -4.4% | -4.3% | -7.3% | -3.0% | 60,759 |
| Tag `_executeEffectHook`, `_runSingleEffect` | **-5.0%** | **-4.8%** | -8.1% | **-3.0%** | 61,201 |
| Also tag `_runEffectsCore` | -5.2% | -5.0% | -8.5% | -2.9% | 66,426 |
| Also tag `_handleEffects` | -7.4% | -4.9% | -11.6% | -2.8% | 71,431 |

Tagging `_handleEffects` alone on top of the leaf set gave -5.3% / -4.4% / -8.9% at 62,244
bytes, so it is the cheapest route to more singles savings. Its call sites are duplicated
across the turn, which is why tagging everything is so expensive; see the plan.

Other results:

- `optimizer_runs` 200 to 1,000,000 moves replay gas by about 1%. 3000 is fine: 20,000 saves
  0.3% for 4.5% more bytes.
- EVM target `cancun`, `prague` and `osaka` produce identical code. Engine has no `CLZ`.
- `@custom:solar-optimize gas` changes nothing; gas is already the objective.

`@custom:solar-*` tags are NatSpec and have no effect under solc. The tag rows only pay off if
production deploys with solar.

## Applied: unconditional small wins

Six source changes, independent of compiler, are now applied to `src/`. Each A/B preserved all
691 tests. Results for the full set:

| | Singles | Doubles | No-op | PvP | Engine bytes |
|---|---:|---:|---:|---:|---:|
| solar | -0.86% | -0.02% | -3.70% | -2.28% | -81 |
| solc | -0.88% | -0.10% | -3.45% | -2.26% | not measured |

By singles gas on solar: constant `actedSlotsThisTurnMask` assignment (5,192), adjacent `MonState`
flag reads in `_handleMove` (3,997), passing `battle` into regen (2,911), hoisting `battle` in
`executeBatchedTurns` (1,569), no `hpDelta` re-read (1,047), and `RNG_ORACLE_FLAG` (748).
`RNG_ORACLE_FLAG` is 10,170 of the 13,140 saved in PvP.

Rejected as trade-offs: `_hookActivesWord` through `battleMode` (+189 on batches, nothing on PvP)
and a zero-cost guard in `_deductStamina` (singles -1,714, doubles +342, PvP +190). Same-value
write guards were not tried; they would save about 100 gas each.

The leaf set is `_getMonState`, `_getTeamMon`, `_unpackActiveMonIndex`, `_battleWord`,
`_monListensAt`, `_stepsWordListens`, `_currentTurnMoveWord`, `_getEffectSlotIndex`,
`_getMonEffectCount`, `_effectStepLaneShift`, `_slotActive`, `_buildActivesWord`,
`_effectDataAndHookContext`, `_monEffectSteps`. The boost set is `laneAt`, `boostFactor`,
`applyWordToAcc`, `finalizeAccStats`, `_boostCountOf`, `_getStatBoostBaseStats`,
`_boostWordsOf`, `_setBoostCountOf`.

## Rejected or unsafe

- **Skip `koOccurredFlag` reads when regen ran no hook.** A KO during the turn-0
  `_activateAbility` sets the flag, and nothing else consumes it on some paths. The
  `_inlineStaminaRegen` tail may be what handles it. This can change outcomes.
- **Lazy team snapshots.** 72% of sides use all four mons.
- **Both-sides-rest fast path.** 2.6% of turns.
- **Recycling all of `BattleData`.** `SimplePM` and munch's wager service call `getWinner` on
  finished battles.
- **Caching the current-turn move.** Effects rewrite it mid-turn.

## Limits of this evidence

- Percentages describe **one singles game and one doubles fixture**. The doubles fixture is
  not winner-faithful. The ten historical corpus replays proposed on 09-05 are still unbuilt,
  so no corpus-weighted saving is claimed.
- Battle start used `DefaultMatchmaker` and a mock registry, not `SignedMatchmaker` and
  `GachaTeamRegistry`.
- PvP numbers come from a 5-turn benchmark, not a recorded PvP game.
- `SSTORE` prices above use the local EVM. MegaETH-specific charges are out of scope.
- Hand patches were gated by the test suite and the replay's game-over check, not by a formal
  equivalence argument. The `rngOracle` gate adds a bit to a field exposed through getters.

## Appendix: hand patches

The first experimental patch against `c7eb6fd`, kept for reference. `src/` now has the cleaner
version above: named constants and adjacent reads instead of assembly. The `regen-oneread` and
`deduct-oneread` hunks saved nothing and were not applied.

```diff
--- a/src/Engine.sol
+++ b/src/Engine.sol
@@ -433,7 +433,7 @@
         config.globalKVCount = 0;
         config.p0BoostCounts = 0;
         config.teamSizes = newTeamSizes;
-        config.inlineRegenFlags = newRegenFlags;
+        config.inlineRegenFlags = address(battle.rngOracle) == address(0) ? newRegenFlags : newRegenFlags | 0x4;
         config.globalEffectsLength = newGlobalEffectsLength;
         config.engineHooksLength = uint8(numHooks);
         config.startTimestamp = uint40(block.timestamp);
@@ -1301,16 +1301,14 @@
             uint256 rng;
             uint104 p0TurnSalt = p0Packed != 0 ? uint104(p0Packed) : config.p0Salt;
             uint104 p1TurnSalt = p1Packed != 0 ? uint104(p1Packed) : config.p1Salt;
-            if (address(config.rngOracle) == address(0)) {
+            uint8 inlineRegenFlags = config.inlineRegenFlags;
+            if (inlineRegenFlags & 0x4 == 0) {
                 rng = uint256(keccak256(abi.encode(p0TurnSalt, p1TurnSalt)));
             } else {
                 rng = config.rngOracle.getRNG(bytes32(uint256(p0TurnSalt)), bytes32(uint256(p1TurnSalt)));
             }
             tempRNG = rng;
 
-            // Cache `inlineRegenFlags` once instead of re-reading config slot 2 three times below.
-            uint8 inlineRegenFlags = config.inlineRegenFlags;
-
             // Calculate the priority and non-priority player indices. Use the internal helper
             // with already-resolved config/battle/moves to skip redundant storage re-resolution.
             priorityPlayerIndex = _computePriorityPlayerIndex(config, battle, battleKey, rng, p0TurnMove, p1TurnMove);
@@ -1396,6 +1394,7 @@
             if (inlineRegenFlags & INLINE_REGEN_REST != 0) {
                 playerSwitchForTurnFlag = _inlineStaminaRegen(
                     config,
+                    battle,
                     EffectStep.AfterMove,
                     priorityPlayerIndex,
                     _unpackActiveMonIndex(battle.activeMonIndex, priorityPlayerIndex),
@@ -1462,6 +1461,7 @@
             if (inlineRegenFlags & INLINE_REGEN_REST != 0) {
                 playerSwitchForTurnFlag = _inlineStaminaRegen(
                     config,
+                    battle,
                     EffectStep.AfterMove,
                     otherPlayerIndex,
                     _unpackActiveMonIndex(battle.activeMonIndex, otherPlayerIndex),
@@ -1517,7 +1517,7 @@
                 uint256 p0Mon = _unpackActiveMonIndex(battle.activeMonIndex, 0);
                 uint256 p1Mon = _unpackActiveMonIndex(battle.activeMonIndex, 1);
                 playerSwitchForTurnFlag =
-                    _inlineStaminaRegen(config, EffectStep.RoundEnd, 0, 0, p0Mon, p1Mon, playerSwitchForTurnFlag);
+                    _inlineStaminaRegen(config, battle, EffectStep.RoundEnd, 0, 0, p0Mon, p1Mon, playerSwitchForTurnFlag);
             }
         }
 
@@ -2732,7 +2732,7 @@
             newDelta = -int32(baseHp); // past fully-dead; the exact magnitude carries no meaning
         }
         monState.hpDelta = newDelta;
-        if (monState.hpDelta + int32(baseHp) <= 0) {
+        if (newDelta + int32(baseHp) <= 0) {
             monState.isKnockedOut = true;
             _setMonKO(config, playerIndex, monIndex);
             koOccurredFlag = 1;
@@ -3467,7 +3467,11 @@
         // Handle shouldSkipTurn flag first and toggle it off if set
         uint256 activeMonIndex = _unpackActiveMonIndex(activesWord, playerIndex);
         MonState storage currentMonState = _getMonState(config, playerIndex, activeMonIndex);
-        if (currentMonState.shouldSkipTurn) {
+        uint256 monWord;
+        assembly ("memory-safe") {
+            monWord := sload(currentMonState.slot)
+        }
+        if ((monWord >> 232) & 0xFF != 0) {
             currentMonState.shouldSkipTurn = false;
             // A forced-switch turn's coerced send-in is not an action the skip flag may eat.
             uint8 storedFlag = uint8(battleWord >> 168);
@@ -3484,7 +3488,7 @@
 
         // Coerce to a switch when one is required: turn 0 (initial send-in) or active mon KO'd.
         // Target the first non-KO'd slot so the switch always lands
-        if ((turnId == 0 || currentMonState.isKnockedOut) && moveIndex != SWITCH_MOVE_INDEX) {
+        if ((turnId == 0 || (monWord >> 224) & 0xFF != 0) && moveIndex != SWITCH_MOVE_INDEX) {
             moveIndex = SWITCH_MOVE_INDEX;
             extraData = uint16(_firstNonKOed(config, playerIndex));
         }
@@ -4422,7 +4426,7 @@
         {
             uint104 s0 = uint104(_turnP0Packed);
             uint104 s1 = uint104(_turnP1Packed);
-            rng = address(config.rngOracle) == address(0)
+            rng = config.inlineRegenFlags & 0x4 == 0
                 ? uint256(keccak256(abi.encode(s0, s1)))
                 : config.rngOracle.getRNG(bytes32(uint256(s0)), bytes32(uint256(s1)));
             tempRNG = rng;
@@ -5173,6 +5177,7 @@
     ///      benchmarks, so we resolve it locally here.
     function _inlineStaminaRegen(
         BattleConfig storage config,
+        BattleData storage battle,
         EffectStep round,
         uint256 playerIndex,
         uint256 monIndex,
@@ -5182,7 +5187,7 @@
     ) private returns (uint256 playerSwitchForTurnFlag) {
         playerSwitchForTurnFlag = prevPlayerSwitchForTurnFlag;
         if (round == EffectStep.RoundEnd) {
-            if (!StaminaRegenLogic._shouldRegenOnRoundEnd(battleData[battleKeyForWrite].playerSwitchForTurnFlag)) {
+            if (!StaminaRegenLogic._shouldRegenOnRoundEnd(battle.playerSwitchForTurnFlag)) {
                 return playerSwitchForTurnFlag;
             }
             _inlineRegenStaminaForMon(config, 0, p0ActiveMonIndex);
@@ -5203,7 +5208,7 @@
         // engine wrongly runs the next turn as a normal both-sides-act turn instead of a forced switch.
         if (koOccurredFlag != 0) {
             koOccurredFlag = 0;
-            (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battleData[battleKeyForWrite], 2);
+            (playerSwitchForTurnFlag,) = _checkForGameOverOrKO(config, battle, 2);
         }
     }
 
@@ -5212,10 +5217,11 @@
     /// matching the external StaminaRegen effect path, which goes through updateMonState.
     function _inlineRegenStaminaForMon(BattleConfig storage config, uint256 playerIndex, uint256 monIndex) private {
         MonState storage monState = playerIndex == 0 ? config.p0States[monIndex] : config.p1States[monIndex];
-        if (monState.staminaDelta >= 0) {
+        int32 staminaDelta = monState.staminaDelta;
+        if (staminaDelta >= 0) {
             return;
         }
-        monState.staminaDelta += 1;
+        monState.staminaDelta = staminaDelta + 1;
         // Exact lane skips unrelated mons without loading their effect count.
         if (_monListensAt(config, playerIndex, monIndex, EffectStep.OnUpdateMonState)) {
             _runEffectsPipeline(
@@ -5237,7 +5243,8 @@
     }
 
     function _deductStamina(MonState storage state, int32 cost) private {
-        state.staminaDelta = (state.staminaDelta == CLEARED_MON_STATE_SENTINEL) ? -cost : state.staminaDelta - cost;
+        int32 staminaDelta = state.staminaDelta;
+        state.staminaDelta = staminaDelta == CLEARED_MON_STATE_SENTINEL ? -cost : staminaDelta - cost;
     }
 
     function _emitMonMoves(
```
