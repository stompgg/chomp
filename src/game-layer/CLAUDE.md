# Gacha & Progression System

`GachaTeamRegistry` is the concrete leaf — it's an `IEngineHook` (subscribes to `OnBattleEnd`) and composes seven abstract bases that each own one slice of state and behavior:

| Abstract | Owns |
|---|---|
| `MonOwnership` | `monsOwned` per-player set; ownership view + bulk-check helpers (`_isOwnerBatch`, `_validateOwnership`). Satisfies the `_isFacetMonOwned` hook on `Facets`. |
| `MonRegistry` | Owner-managed mon catalog (`monStats`, `monMoves`, `monAbilities`, `monMetadata`, sequential `monIds` set). Inherits `ITeamRegistry` so its `createMon`/`modifyMon`/batched-getters bind directly. Backs the `_getMonStatsForFacets` hook used by facet delta computation. |
| `PlayerProfile` | Packed `playerData[address]` (one uint256 per player) + the owner-managed `isAssigner` allowlist. Exposes `pointsBalance`, `isWhitelistedOpponent`, the bulk admin flag setters, and `assignPoints` (IGachaPointsAssigner). |
| `PackedTeamStore` | Bit-packed team CRUD: `teamGroupsPacked` (4 teams × 64 bits per slot), `teamOrderPacked` (16-slot live bitmap + display order). Constructor takes `MONS_PER_TEAM` / `MOVES_PER_MON` immutables. Subclass hooks: `_packedTeamValidateOwnership`, `_packedTeamIsCpuOpponent`, `_packedTeamGetMonData`. |
| `Facets` | 12-facet ±5% stat tradeoff system (see below). Pure helpers, packed per-mon facet data, `assignFacets`. |
| `MonExp` | Packed per-mon exp (`packedExpForMon`), level curve, level-up facet draws (`_processLevelUps`), public `getExp` / `getLevel` / `getExpAndLevelsFor*`, assigner-gated `assignExp`. Inherits `Facets` + `PackedTeamStore` because level-ups draw facets and team views need the lane helpers. Subclass hooks: `_assertExpAssigner`, `_monRegistrySize`. |
| `Quests` | Daily quest pool + packed predicate evaluator. Subclass hook: `_extract` (opcode dispatch implemented by the leaf since it sees Engine + all sub-systems). |

The leaf adds: the `onBattleEnd` orchestration (streak / quest / points / exp loop, plus a `_applyExpAndFacetDraws` walk that mirrors `assignExp` but with KO bitmap + streak + event packing), gacha rolling (`firstRoll`/`roll`/`_rollInto`), the per-(user, opponent) CPU phantom facet config, the `getTeams` variant that folds facet deltas in, the `_extract` quest opcode dispatch, and the wiring overrides for every subclass hook. With this split the leaf is ~750 LOC of integration and event-shape concerns; each base is independently auditable.

**Rolling.** Mon ids are sequential starting at 0 (`createMon` enforces `monId == monIds.length()`). Ids `[0, NUM_STARTERS)` (= 3) are *starter* mons.

- `firstRoll(uint256 starterId)` — one-shot per player, onboarding in a single tx. Caller picks `starterId ∈ {0,1,2}`; the contract guarantees that mon at slot 0 of the result and rolls `INITIAL_ROLLS - 1` (= 3) more uniformly from `[NUM_STARTERS, numMons)`. Free. Also creates the player's first team (slot 0) from the first `MONS_PER_TEAM` rolled ids, via the same internal path `createTeam` uses (`_createTeamForUser`) — skipping the redundant ownership check since those ids were just written. The constructor reverts `MonsPerTeamExceedsInitialRolls` if `MONS_PER_TEAM > INITIAL_ROLLS`, since a deployment configured that way could never satisfy this.
- `roll(uint256 numRolls)` — paid (`ROLL_COST` per roll, default 16 points). Uniform across the entire pool. Reverts `NoMoreStock` once the caller owns every mon.
- Linear-probing dedup keeps draws inside their window so `firstRoll`'s 3 random picks never land on a starter.

**Points / exp / facets storage.** All packed for gas:

```
playerData[address] (1 slot per player):
  bit 255       bonusAwarded (first-game-ever bonus claimed)
  bit 254       isWhitelistedAsOpponent (admin-set; replaces a separate mapping)
  bit 253       (reserved; formerly isHardCpu)
  bits 250-252  streakDay (1..STREAK_FLAT_BONUS_MAX; 0 = no streak yet)
  bits 224-249  (reserved)
  bits 192-223  lastQuestCompletedDay (uint32 calendar day)
  bits 160-191  lastSeenTimestamp (uint32 seconds; last battle of ANY kind — drives streak grace/reset)
  bits 128-159  lastFirstGameTimestamp (uint32 seconds; last streak-bonus game — gates the 24h cooldown)
  bits 0-127    pointsBalance (uint128)

packedExpForMon[player][monId / 16]: 16 mons × 16 bits each, capped at 65535.
facetData[player][monId / 16]:        16 mons × 16 bits each
                                       (bits 0-11 unlockedBitmap, bits 12-15 assignedFacetId).
```

Streak is timestamp-driven (not calendar-day): a battle qualifies for the streak bonus
when ≥24h have passed since `lastFirstGameTimestamp` (the last *bonus-earning* game). On a
qualifying battle the ratchet-vs-reset decision is measured from `lastSeenTimestamp` (the
last battle of *any* kind, advanced every battle): a gap >36h (`STREAK_GRACE_WINDOW`) of
genuine inactivity resets `streakDay` to 1, otherwise it ratchets up toward the cap of
`STREAK_FLAT_BONUS_MAX` (= 5). Splitting the two anchors is deliberate — measuring the
reset from the bonus anchor instead would strand players who play slightly more often than
once per 24h (their sub-24h plays advance no anchor, so the next day reads a phantom ~46h
gap and resets the streak forever).

Both per-mon mappings share the same 16-mon bucketing so `_applyExpAndFacetDraws` walks the team in one pass and coalesces SSTOREs by bucket.

**Battle rewards (`onBattleEnd`).** CPU side is short-circuited (no SSTOREs, no event). For each human side:

- Base points: `POINTS_PER_WIN` (2) on win, `POINTS_PER_LOSS` (1) otherwise.
- Streak flat: `streakDay` (1..5) added inside the parenthetical of both the points and per-mon-exp formulas. Only granted when the battle qualifies as "first of day" (≥24h since the last grant).
- Points formula: `(basePts + streakFlat) × gachaMult + firstGameEverBonus`. `gachaMult` is `×QUEST_REWARD_MULT` (= 2) when the active daily quest completes (winner-only, one-shot per day), else 1. `firstGameEverBonus` is `+FIRST_GAME_EVER_BONUS` (= 16), one-shot ever, applied *after* the multiplier.
- Per-mon exp formula: `(baseExp + streakFlat) × expMult`, capped at 65535. `baseExp` is `EXP_PER_SURVIVING_MON` (2) for alive slots, `EXP_PER_KOD_MON` (1) for KO'd slots.
- `expMult` stack: a flat `GAME_EXP_MULT` (×2) on **every** battle regardless of game type (PvP, CPU, hard or not), times `QUEST_REWARD_MULT` (×2) on quest completion. Max stack = ×4. (There is no longer a PvP-vs-CPU or hard-CPU exp distinction — the old client-set "hard CPU" flag let any user self-grant the bonus, so it was removed.)
- Level-ups (12-tier curve, capped at level 12 to match `TOTAL_FACETS`) trigger one facet draw per level crossed.

**Facets.** 12 systematically-derived stat tradeoffs across 4 stat groups (`HP`, `Atk`, `Def`, `Speed`). `_facetDef(facetId)` is pure — no constant table. Magnitudes are **boost-indexed**: the boost stat determines both the boost% and the cost% paid on the nerfed stat. HP/Atk/Def boosts are symmetric (+5% / -5%); speed boosts pay a heavier cost (+5% / -10%) so they can't cheaply break speed ties. The percentages live as `BOOST_PCT_*` / `COST_PCT_*` constants in `Facets.sol`. Unlocks are persistent per-mon; `assignFacets(monIds, facetIds)` is a free bulk re-assign that requires the caller to own every listed mon and the facet to be in the unlocked bitmap (`facetId == 0` clears). `GachaTeamRegistry.getTeams()` folds the active facet's delta into each mon's stats before returning, so by the time the Engine stores teams in `BattleConfig` they already reflect the boost/cost. `validateMon` no longer checks stat equality (the round-trip would always fail with facets applied) — moves and ability membership are still enforced.

**CPU opponent facets.** When fighting a whitelisted opponent (CPU), the human caller picks the CPU's team *and* its facet config in one call: `setOpponentTeam(opponent, monIndices, facetIds)`. Per-user-per-CPU storage (`opponentTeamFacetsPacked[opponent][phantomKey]`) keyed by the same `uint16(uint160(msg.sender))` phantom slot as the team. No ownership/unlock checks — any facet 0..12 is allowed. `getTeamsWithDeltas` short-circuits to this slot-indexed config when a side is `isWhitelistedOpponent`, so per-user CPU facet configurations stay isolated even when many users fight the same CPU.

**Quests.** Owner-managed `questPool`. One quest is active per UTC day, derived statelessly as `keccak256(day) % poolLength` (day = `block.timestamp / 1 days` + an owner-settable `_dayOffset`) — no rotation SSTORE and no race between concurrent battles. Each quest has up to `MAX_PREDICATES_PER_QUEST` (6) AND-composed predicates packed into one storage slot (41 bits each: `op` 5b, `cmp` 3b, `negate` 1b, `arg` 16b, `operand` 16b — total 246b + 3b count). Opcodes cover battle context (`TURNS`, `ALIVE_COUNT`, `ACTIVE_SLOT_INDEX`, `MON_KO_AT_SLOT`), team composition (`HAS_MON_ID`), per-mon progression (`MON_LEVEL`, `MON_FACET`), and live battle state (`MON_STATE` via `Engine.getMonStateForBattle`).

**Events.**

- `Roll(address indexed player, uint256[] monIds, uint256 pointsSpent)` — fires on both `firstRoll` (spend = 0) and paid `roll`.
- `GachaEvent(bytes32 indexed battleKey, uint256 p0Packed, uint256 p1Packed)` — one per battle, carrying both sides' packed payloads (CPU side is 0). Layout sized for `MONS_PER_TEAM` up to 8: points (bits 0-15), per-mon exp gain (bits 16-79, 8 lanes × 8b), per-mon facets unlocked this battle (bits 80-175, 8 lanes × 12-bit bitmap = 1 bit per facet id), `BONUS_*` flags (bits 176-183: `FIRST_ROLL` (bit 0) | `FIRST_GAME` (bit 1) | bit 2 reserved/formerly `HARD_CPU` | `QUEST` (bit 3)), combined exp multiplier (bits 184-191), outcome (bits 192-199: 0=loss, 1=win, 2=draw), `streakDay` (bits 200-202). Lanes saturate so a future tuning blow-up can't bleed into neighbouring fields.
