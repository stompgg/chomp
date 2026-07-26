---
name: add-game-content
description: Workflow for adding a new mon, move, ability, or effect to chomp — CSV data, contract patterns, and validation steps. Use when adding/creating a new mon, move, ability, or status/battlefield effect.
---

### Adding a New Mon

1. Add mon stats to `drool/mons.csv` (HP, Attack, Defense, SpAtk, SpDef, Speed, Types)
2. Add 4 moves to `drool/moves.csv` (Name, Mon, Power, Stamina, Accuracy, Priority, Type, Class, etc.)
3. Add ability to `drool/abilities.csv` (Name, Mon, Effect description)
4. Create directory `src/mons/<monname>/` (lowercase, e.g., `src/mons/aurox/`)
5. Implement 4 move contracts as `PascalCase.sol` files (see "Move Implementation Patterns" below)
6. Implement 1 ability contract as `PascalCase.sol` (see "Ability Patterns" below)
7. Run `python processing/validateMoves.py` to validate contracts match CSV data
8. Run `python processing/generateSolidity.py` to regenerate `SetupMons.s.sol`
9. Add tests in `test/mons/<MonName>Test.sol` extending `BattleHelper`

### Move Implementation Patterns

Choose the simplest pattern that fits the move's behavior:

**1. Pure `StandardAttack`** — constructor-only, no `move()` override. For straightforward damaging moves or simple effect-applying moves. Pass `EFFECT` + `EFFECT_ACCURACY` for probabilistic status application (e.g., 30% chance to burn):

```solidity
contract Blow is StandardAttack {
    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR)
        StandardAttack(msg.sender, _ENGINE, _TYPE_CALCULATOR, ATTACK_PARAMS({
            BASE_POWER: 70, STAMINA_COST: 2, ACCURACY: DEFAULT_ACCURACY,
            PRIORITY: DEFAULT_PRIORITY, MOVE_TYPE: Type.Air,
            EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
            CRIT_RATE: DEFAULT_CRIT_RATE, VOLATILITY: DEFAULT_VOL,
            NAME: "Blow", EFFECT: IEffect(address(0))
        }))
    {}
}
```

**2. `StandardAttack` + `move()` override** — for moves with side effects after damage (recoil, self-switch, self-status, multi-hit). Override the full `move(...)` signature and call `_move()`, which returns `(int32 damage, bytes32 eventType)`, then add custom logic:

```solidity
function move(
    IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex,
    uint256 targetBits, uint256 activesPacked, uint16 extraData, uint256 rng
) public override {
    (int32 damage,) = _move(engine, battleKey, attackerPlayerIndex, targetBits, rng);
    if (damage > 0) {
        engine.dealDamage(attackerPlayerIndex, attackerMonIndex, selfDamage); // recoil
    }
}
```

A move's target domain is client-facing metadata in `moves.csv`'s `TargetSpec` column (→ TS `Move.targetSpec`), not a Solidity declaration; `validateMoves.py` checks each move's `targetBits` behavior against it. The player's chosen target arrives as `targetBits` (resolved against `activesPacked` via `TargetLib`); the old `targetSpec()` / `extraDataType()` / `ExtraDataType` selector layers have been removed.

**3. Custom `IMoveSet`** — for complex conditional moves (variable power, healing, stat manipulation, reading opponent state). Implement the `IMoveSet` functions directly (`move` + metadata getters + `getMeta`). Deal damage via `engine.dispatchStandardAttack` / `dispatchCustomAttack` (passing `targetBits`); `AttackCalculator._calculateDamage()` now just delegates to `dispatchCustomAttack`. Store dependencies as `immutable`.

**4. `IMoveSet` + `BasicEffect` hybrid** — for moves that persist as effects across turns (traps, delayed damage, per-turn modifiers). Implement both interfaces in one contract. The `move()` function calls `ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), ...)`.

**Shared libraries** — when multiple moves in the same mon share logic, extract into a `library` contract in the same directory (e.g., `NineNineNineLib.sol`, `HeatBeaconLib.sol`).

### Ability Patterns

Each mon has exactly one ability, implemented in its own `PascalCase.sol` file within the mon directory.

**Pure `IAbility`** — for one-time switch-in actions (deal damage, apply a stat boost). Implement `name()` and `activateOnSwitch()`. No persistent state. (e.g., `PreemptiveShock`, `SaviorComplex`)

**`IAbility` + `BasicEffect`** (most common) — for abilities with ongoing lifecycle effects. `activateOnSwitch()` registers `address(this)` as an effect on the mon, then hooks into effect lifecycle via `getStepsBitmap()`. Must override `name()` with `override(IAbility, BasicEffect)`. Uses an idempotency guard to prevent duplicate registration:

```solidity
function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
    (EffectInstance[] memory effects,) = ENGINE.getEffects(battleKey, playerIndex, monIndex);
    for (uint256 i; i < effects.length; i++) {
        if (address(effects[i].effect) == address(this)) return;
    }
    ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
}
```

For once-per-battle abilities (e.g., `RiseFromTheGrave`), use a `globalKV` flag instead of the effect-list check.

### Adding a New Effect

Effects fall into several categories depending on scope:

- **Status effects** (`src/effects/status/`): Extend the `StatusEffect` marker base. One-status-per-mon is **Engine-native**: each status folds a unique class id into `getStepsBitmap()` bits 10-13 (an internal `STATUS_CLASS` constant; deployable ids 1-14, 15 reserved for test mocks), and the Engine tracks it in a per-mon lane (`BattleConfig.monStatusLanes`, slot 3) — gating adds before any external call, setting the lane on apply, clearing it on removal. Readers use `engine.getMonStatusClass` (identity/existence) and `engine.clearMonStatus(player, mon, expectedClass)` (remove; 0 = any class); reader contracts cache the class id as a constructor `immutable` derived from the injected status's `getStepsBitmap()`. Escalating statuses (Burn) set `HAS_REAPPLY_BIT` (bit 14) and implement `IStatusEffect.onReapply`, which the Engine calls on a same-class re-apply; without the bit a re-apply is a zero-call no-op. Extra apply conditions beyond exclusivity (Sleep's single-sleeper rule) live in a `shouldApply` override (no `ALWAYS_APPLIES_BIT`). Shared across mons — deployed once, injected into moves via constructor parameters. (e.g., `BurnStatus`, `FrostbiteStatus`, `SleepStatus`)
- **Battlefield effects** (`src/effects/battlefield/`): Extend `BasicEffect`, use `targetIndex=2` for global scope. (e.g., `Overclock`)
- **Shared utility effects** (`src/effects/`): Deployed once, used by many contracts. (e.g., `StaminaRegen` for per-turn recovery). NOTE: stat modifiers are **not** an effect — they are inlined Engine functions (`addStatBoost`/`removeStatBoost`/…); see "Stat Boosts" in the root CLAUDE.md.
- **Mon-local effects** (`src/mons/<monname>/`): Abilities or move-effect hybrids that only apply to one mon. These live in the mon's directory, not in `src/effects/`.

To implement a new effect:
1. Extend `BasicEffect` (or `StatusEffect` for status conditions)
2. Override the relevant lifecycle hooks (`onRoundEnd`, `onAfterDamage`, `onPreDamage`, …) — each receives `activesPacked` for local slot resolution via `TargetLib`
3. Return a bitmap from `getStepsBitmap()` indicating which hooks to call. Before adding callback getters, opt into a supported fresh context by mirroring the applicable low lifecycle bit into bits 16-31 as described in the root CLAUDE.md. If the effect doesn't override `shouldApply()` (i.e. it relies on `BasicEffect`'s default, which always returns `true`), OR the low bitmap with `ALWAYS_APPLIES_BIT` (`src/Constants.sol`) so the Engine skips the external `shouldApply()` call on `addEffect`. Effects that override `shouldApply()` with real gating logic (e.g. `SleepStatus`'s single-sleeper rule) must NOT set this bit. Statuses additionally carry their class id in bits 10-13 and `HAS_REAPPLY_BIT` (bit 14) iff they implement `onReapply`. `python processing/validateEffectBitmaps.py` checks all of these invariants (bit pairing, class range 1-14, cross-src uniqueness) and is run as part of `deploy.py`.
4. Return `(updatedExtraData, removeAfterRun)` from hooks — use `extraData` (bytes32) to carry state between turns (counters, degrees, flags)
5. Shared effects are injected into moves/abilities via constructor parameters at deploy time — there is no runtime effect registry
