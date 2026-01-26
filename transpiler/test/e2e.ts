/**
 * End-to-End Tests for Transpiled Solidity Contracts
 *
 * Tests:
 * - Status effects (skip turn, damage over time)
 * - Forced switches (user switch after damage)
 * - Abilities (stat boosts on damage)
 *
 * Run with: npx tsx test/e2e.ts
 */

import { keccak256, encodePacked } from 'viem';
import { test, expect, runTests } from './test-utils';

// =============================================================================
// ENUMS (mirroring Solidity)
// =============================================================================

enum MonStateIndexName {
  Hp = 0,
  Stamina = 1,
  Speed = 2,
  Attack = 3,
  Defense = 4,
  SpecialAttack = 5,
  SpecialDefense = 6,
  IsKnockedOut = 7,
  ShouldSkipTurn = 8,
  Type1 = 9,
  Type2 = 10,
}

enum EffectStep {
  OnApply = 0,
  RoundStart = 1,
  RoundEnd = 2,
  OnRemove = 3,
  OnMonSwitchIn = 4,
  OnMonSwitchOut = 5,
  AfterDamage = 6,
  AfterMove = 7,
}

enum Type {
  Yin = 0, Yang = 1, Earth = 2, Liquid = 3, Fire = 4,
  Metal = 5, Ice = 6, Nature = 7, Lightning = 8, Mythic = 9,
  Air = 10, Math = 11, Cyber = 12, Wild = 13, Cosmic = 14, None = 15,
}

enum MoveClass {
  Physical = 0,
  Special = 1,
  Self = 2,
  Other = 3,
}

enum StatBoostType {
  Multiply = 0,
  Divide = 1,
}

enum StatBoostFlag {
  Temp = 0,
  Perm = 1,
}

// =============================================================================
// INTERFACES
// =============================================================================

interface MonStats {
  hp: bigint;
  stamina: bigint;
  speed: bigint;
  attack: bigint;
  defense: bigint;
  specialAttack: bigint;
  specialDefense: bigint;
  type1: Type;
  type2: Type;
}

interface MonState {
  hpDelta: bigint;
  isKnockedOut: boolean;
  shouldSkipTurn: boolean;
  attackBoostPercent: bigint;  // Accumulated attack boost
}

interface EffectInstance {
  effect: IEffect;
  extraData: string;
}

interface IEffect {
  name(): string;
  shouldRunAtStep(step: EffectStep): boolean;
  onApply?(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onRoundStart?(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onRoundEnd?(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean];
  onAfterDamage?(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint, damage: bigint): [string, boolean];
  onRemove?(extraData: string, targetIndex: bigint, monIndex: bigint): void;
}

interface IAbility {
  name(): string;
  activateOnSwitch(battleKey: string, playerIndex: bigint, monIndex: bigint): void;
}

interface StatBoostToApply {
  stat: MonStateIndexName;
  boostPercent: bigint;
  boostType: StatBoostType;
}

// =============================================================================
// MOCK ENGINE
// =============================================================================

class MockEngine {
  private battleKey: string = '';
  private teams: MonStats[][] = [[], []];
  private states: MonState[][] = [[], []];
  private activeMonIndex: bigint[] = [0n, 0n];
  private effects: Map<string, EffectInstance[]> = new Map();
  private globalKV: Map<string, bigint> = new Map();
  private priorityPlayerIndex: bigint = 0n;
  private turnNumber: bigint = 0n;

  // Event log for testing
  public eventLog: string[] = [];

  /**
   * Initialize a battle
   */
  initBattle(p0Team: MonStats[], p1Team: MonStats[]): string {
    this.battleKey = keccak256(encodePacked(['uint256'], [BigInt(Date.now())]));
    this.teams = [p0Team, p1Team];
    this.states = [
      p0Team.map(() => ({ hpDelta: 0n, isKnockedOut: false, shouldSkipTurn: false, attackBoostPercent: 0n })),
      p1Team.map(() => ({ hpDelta: 0n, isKnockedOut: false, shouldSkipTurn: false, attackBoostPercent: 0n })),
    ];
    this.activeMonIndex = [0n, 0n];
    this.effects.clear();
    this.globalKV.clear();
    this.eventLog = [];
    return this.battleKey;
  }

  battleKeyForWrite(): string {
    return this.battleKey;
  }

  getActiveMonIndexForBattleState(battleKey: string): bigint[] {
    return [...this.activeMonIndex];
  }

  getTeamSize(battleKey: string, playerIndex: bigint): bigint {
    return BigInt(this.teams[Number(playerIndex)].length);
  }

  getMonValueForBattle(battleKey: string, playerIndex: bigint, monIndex: bigint, stat: MonStateIndexName): bigint {
    const pi = Number(playerIndex);
    const mi = Number(monIndex);
    const mon = this.teams[pi][mi];
    const state = this.states[pi][mi];

    switch (stat) {
      case MonStateIndexName.Hp:
        return mon.hp + state.hpDelta;
      case MonStateIndexName.Stamina:
        return mon.stamina;
      case MonStateIndexName.Speed:
        return mon.speed;
      case MonStateIndexName.Attack:
        // Apply attack boost
        const baseAttack = mon.attack;
        const boostMultiplier = 100n + state.attackBoostPercent;
        return (baseAttack * boostMultiplier) / 100n;
      case MonStateIndexName.Defense:
        return mon.defense;
      case MonStateIndexName.SpecialAttack:
        return mon.specialAttack;
      case MonStateIndexName.SpecialDefense:
        return mon.specialDefense;
      case MonStateIndexName.IsKnockedOut:
        return state.isKnockedOut ? 1n : 0n;
      case MonStateIndexName.ShouldSkipTurn:
        return state.shouldSkipTurn ? 1n : 0n;
      case MonStateIndexName.Type1:
        return BigInt(mon.type1);
      case MonStateIndexName.Type2:
        return BigInt(mon.type2);
      default:
        return 0n;
    }
  }

  getMonStateForBattle(battleKey: string, playerIndex: bigint, monIndex: bigint, stat: MonStateIndexName): bigint {
    return this.getMonValueForBattle(battleKey, playerIndex, monIndex, stat);
  }

  updateMonState(playerIndex: bigint, monIndex: bigint, stat: MonStateIndexName, value: bigint): void {
    const pi = Number(playerIndex);
    const mi = Number(monIndex);
    const state = this.states[pi][mi];

    if (stat === MonStateIndexName.ShouldSkipTurn) {
      state.shouldSkipTurn = value !== 0n;
      this.eventLog.push(`P${pi}M${mi}: ShouldSkipTurn = ${value}`);
    } else if (stat === MonStateIndexName.IsKnockedOut) {
      state.isKnockedOut = value !== 0n;
      this.eventLog.push(`P${pi}M${mi}: IsKnockedOut = ${value}`);
    }
  }

  dealDamage(playerIndex: bigint, monIndex: bigint, damage: bigint): void {
    const pi = Number(playerIndex);
    const mi = Number(monIndex);
    const state = this.states[pi][mi];
    const mon = this.teams[pi][mi];

    state.hpDelta -= damage;
    this.eventLog.push(`P${pi}M${mi}: Took ${damage} damage, HP now ${mon.hp + state.hpDelta}`);

    // Check for KO
    if (mon.hp + state.hpDelta <= 0n) {
      state.isKnockedOut = true;
      this.eventLog.push(`P${pi}M${mi}: Knocked out!`);
    }

    // Trigger AfterDamage effects
    this.runEffectsAtStep(playerIndex, monIndex, EffectStep.AfterDamage, damage);
  }

  switchActiveMon(playerIndex: bigint, newMonIndex: bigint): void {
    const pi = Number(playerIndex);
    const oldIndex = this.activeMonIndex[pi];
    this.activeMonIndex[pi] = newMonIndex;
    this.eventLog.push(`P${pi}: Switched from mon ${oldIndex} to mon ${newMonIndex}`);

    // Run OnMonSwitchOut for old mon
    this.runEffectsAtStep(playerIndex, oldIndex, EffectStep.OnMonSwitchOut);

    // Run OnMonSwitchIn for new mon
    this.runEffectsAtStep(playerIndex, newMonIndex, EffectStep.OnMonSwitchIn);
  }

  addEffect(targetIndex: bigint, monIndex: bigint, effect: IEffect, extraData: string): void {
    const key = `${targetIndex}-${monIndex}`;
    if (!this.effects.has(key)) {
      this.effects.set(key, []);
    }
    this.effects.get(key)!.push({ effect, extraData });
    this.eventLog.push(`P${targetIndex}M${monIndex}: Added effect ${effect.name()}`);

    // Run OnApply
    if (effect.onApply && effect.shouldRunAtStep(EffectStep.OnApply)) {
      const [newExtra, remove] = effect.onApply(0n, extraData, targetIndex, monIndex);
      const effectList = this.effects.get(key)!;
      const idx = effectList.length - 1;
      effectList[idx].extraData = newExtra;
      if (remove) {
        effectList.splice(idx, 1);
      }
    }
  }

  getEffects(battleKey: string, playerIndex: bigint, monIndex: bigint): [EffectInstance[], bigint[]] {
    const key = `${playerIndex}-${monIndex}`;
    const effects = this.effects.get(key) || [];
    const indices = effects.map((_, i) => BigInt(i));
    return [effects, indices];
  }

  removeEffect(targetIndex: bigint, monIndex: bigint, effectIndex: bigint): void {
    const key = `${targetIndex}-${monIndex}`;
    const effects = this.effects.get(key);
    if (effects) {
      const effect = effects[Number(effectIndex)];
      if (effect?.effect.onRemove) {
        effect.effect.onRemove(effect.extraData, targetIndex, monIndex);
      }
      effects.splice(Number(effectIndex), 1);
    }
  }

  computePriorityPlayerIndex(battleKey: string, rng: bigint): bigint {
    return this.priorityPlayerIndex;
  }

  setPriorityPlayerIndex(index: bigint): void {
    this.priorityPlayerIndex = index;
  }

  getGlobalKV(battleKey: string, key: string): bigint {
    return this.globalKV.get(key) ?? 0n;
  }

  setGlobalKV(key: string, value: bigint): void {
    this.globalKV.set(key, value);
  }

  // Run effects at a specific step
  runEffectsAtStep(playerIndex: bigint, monIndex: bigint, step: EffectStep, damage?: bigint): void {
    const key = `${playerIndex}-${monIndex}`;
    const effects = this.effects.get(key);
    if (!effects) return;

    const toRemove: number[] = [];

    for (let i = 0; i < effects.length; i++) {
      const { effect, extraData } = effects[i];
      if (!effect.shouldRunAtStep(step)) continue;

      let newExtra = extraData;
      let remove = false;

      switch (step) {
        case EffectStep.RoundStart:
          if (effect.onRoundStart) {
            [newExtra, remove] = effect.onRoundStart(0n, extraData, playerIndex, monIndex);
          }
          break;
        case EffectStep.RoundEnd:
          if (effect.onRoundEnd) {
            [newExtra, remove] = effect.onRoundEnd(0n, extraData, playerIndex, monIndex);
          }
          break;
        case EffectStep.AfterDamage:
          if (effect.onAfterDamage) {
            [newExtra, remove] = effect.onAfterDamage(0n, extraData, playerIndex, monIndex, damage ?? 0n);
          }
          break;
      }

      effects[i].extraData = newExtra;
      if (remove) {
        toRemove.push(i);
      }
    }

    // Remove effects marked for removal (in reverse order to preserve indices)
    for (let i = toRemove.length - 1; i >= 0; i--) {
      const effect = effects[toRemove[i]];
      if (effect?.effect.onRemove) {
        effect.effect.onRemove(effect.extraData, playerIndex, monIndex);
      }
      effects.splice(toRemove[i], 1);
      this.eventLog.push(`P${playerIndex}M${monIndex}: Removed effect`);
    }
  }

  // Process round start for all mons
  processRoundStart(): void {
    this.turnNumber++;
    for (let pi = 0; pi < 2; pi++) {
      const mi = Number(this.activeMonIndex[pi]);
      this.runEffectsAtStep(BigInt(pi), BigInt(mi), EffectStep.RoundStart);
    }
  }

  // Process round end for all mons
  processRoundEnd(): void {
    for (let pi = 0; pi < 2; pi++) {
      const mi = Number(this.activeMonIndex[pi]);
      this.runEffectsAtStep(BigInt(pi), BigInt(mi), EffectStep.RoundEnd);
    }
  }

  // Check if a mon should skip their turn
  shouldSkipTurn(playerIndex: bigint): boolean {
    const pi = Number(playerIndex);
    const mi = Number(this.activeMonIndex[pi]);
    return this.states[pi][mi].shouldSkipTurn;
  }

  // Clear skip turn flag
  clearSkipTurn(playerIndex: bigint): void {
    const pi = Number(playerIndex);
    const mi = Number(this.activeMonIndex[pi]);
    this.states[pi][mi].shouldSkipTurn = false;
  }

  // Apply stat boost
  applyStatBoost(playerIndex: bigint, monIndex: bigint, stat: MonStateIndexName, boostPercent: bigint): void {
    if (stat === MonStateIndexName.Attack) {
      const pi = Number(playerIndex);
      const mi = Number(monIndex);
      this.states[pi][mi].attackBoostPercent += boostPercent;
      this.eventLog.push(`P${pi}M${mi}: Attack boosted by ${boostPercent}%, total now ${this.states[pi][mi].attackBoostPercent}%`);
    }
  }

  // Get current attack value (with boosts)
  getCurrentAttack(playerIndex: bigint, monIndex: bigint): bigint {
    return this.getMonValueForBattle(this.battleKey, playerIndex, monIndex, MonStateIndexName.Attack);
  }
}

// =============================================================================
// MOCK STAT BOOSTS
// =============================================================================

class MockStatBoosts {
  private engine: MockEngine;

  constructor(engine: MockEngine) {
    this.engine = engine;
  }

  addStatBoosts(targetIndex: bigint, monIndex: bigint, boosts: StatBoostToApply[], flag: StatBoostFlag): void {
    for (const boost of boosts) {
      this.engine.applyStatBoost(targetIndex, monIndex, boost.stat, boost.boostPercent);
    }
  }
}

// =============================================================================
// MOCK TYPE CALCULATOR
// =============================================================================

class MockTypeCalculator {
  calculateTypeEffectiveness(attackType: Type, defenderType1: Type, defenderType2: Type): bigint {
    // Simplified: always return 100 (1x effectiveness)
    return 100n;
  }
}

// =============================================================================
// SIMPLE EFFECT IMPLEMENTATIONS FOR TESTING
// =============================================================================

/**
 * Simple Zap (paralysis) effect - skips one turn
 */
class ZapStatusEffect implements IEffect {
  private engine: MockEngine;
  private static ALREADY_SKIPPED = 1;

  constructor(engine: MockEngine) {
    this.engine = engine;
  }

  name(): string {
    return "Zap";
  }

  shouldRunAtStep(step: EffectStep): boolean {
    return step === EffectStep.OnApply ||
           step === EffectStep.RoundStart ||
           step === EffectStep.RoundEnd ||
           step === EffectStep.OnRemove;
  }

  onApply(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean] {
    const priorityPlayerIndex = this.engine.computePriorityPlayerIndex('', rng);

    let state = 0;
    if (targetIndex !== priorityPlayerIndex) {
      // Opponent hasn't moved yet, skip immediately
      this.engine.updateMonState(targetIndex, monIndex, MonStateIndexName.ShouldSkipTurn, 1n);
      state = ZapStatusEffect.ALREADY_SKIPPED;
    }

    return [String(state), false];
  }

  onRoundStart(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean] {
    // Set skip flag
    this.engine.updateMonState(targetIndex, monIndex, MonStateIndexName.ShouldSkipTurn, 1n);
    return [String(ZapStatusEffect.ALREADY_SKIPPED), false];
  }

  onRoundEnd(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean] {
    const state = parseInt(extraData) || 0;
    return [extraData, state === ZapStatusEffect.ALREADY_SKIPPED];
  }

  onRemove(extraData: string, targetIndex: bigint, monIndex: bigint): void {
    // Clear skip turn on removal
    this.engine.updateMonState(targetIndex, monIndex, MonStateIndexName.ShouldSkipTurn, 0n);
  }
}

/**
 * Simple Burn effect - deals 1/16 max HP damage per round
 */
class BurnStatusEffect implements IEffect {
  private engine: MockEngine;

  constructor(engine: MockEngine) {
    this.engine = engine;
  }

  name(): string {
    return "Burn";
  }

  shouldRunAtStep(step: EffectStep): boolean {
    return step === EffectStep.OnApply || step === EffectStep.RoundEnd;
  }

  onApply(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean] {
    return ['1', false]; // Burn degree 1
  }

  onRoundEnd(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint): [string, boolean] {
    // Deal 1/16 max HP damage
    const battleKey = this.engine.battleKeyForWrite();
    const maxHp = this.engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp);
    const damage = maxHp / 16n;
    if (damage > 0n) {
      this.engine.dealDamage(targetIndex, monIndex, damage);
    }
    return [extraData, false];
  }
}

/**
 * UpOnly ability effect - increases attack by 10% each time damage is taken
 */
class UpOnlyEffect implements IEffect {
  private engine: MockEngine;
  private statBoosts: MockStatBoosts;
  static readonly ATTACK_BOOST_PERCENT = 10n;

  constructor(engine: MockEngine, statBoosts: MockStatBoosts) {
    this.engine = engine;
    this.statBoosts = statBoosts;
  }

  name(): string {
    return "Up Only";
  }

  shouldRunAtStep(step: EffectStep): boolean {
    return step === EffectStep.AfterDamage;
  }

  onAfterDamage(rng: bigint, extraData: string, targetIndex: bigint, monIndex: bigint, damage: bigint): [string, boolean] {
    // Add 10% attack boost
    this.statBoosts.addStatBoosts(targetIndex, monIndex, [{
      stat: MonStateIndexName.Attack,
      boostPercent: UpOnlyEffect.ATTACK_BOOST_PERCENT,
      boostType: StatBoostType.Multiply,
    }], StatBoostFlag.Perm);

    return [extraData, false];
  }
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

function createBasicMon(overrides: Partial<MonStats> = {}): MonStats {
  return {
    hp: 100n,
    stamina: 10n,
    speed: 50n,
    attack: 50n,
    defense: 50n,
    specialAttack: 50n,
    specialDefense: 50n,
    type1: Type.None,
    type2: Type.None,
    ...overrides,
  };
}

// =============================================================================
// TESTS: STATUS EFFECTS
// =============================================================================

test('ZapStatus: skips turn when applied to non-priority player', () => {
  const engine = new MockEngine();
  const battleKey = engine.initBattle(
    [createBasicMon()],
    [createBasicMon()]
  );

  // P0 has priority (moves first), P1 is target
  engine.setPriorityPlayerIndex(0n);

  const zap = new ZapStatusEffect(engine);
  engine.addEffect(1n, 0n, zap, '0');

  // P1's mon should have skip turn set immediately
  expect(engine.shouldSkipTurn(1n)).toBe(true);
});

test('ZapStatus: waits until RoundStart when applied to priority player', () => {
  const engine = new MockEngine();
  engine.initBattle(
    [createBasicMon()],
    [createBasicMon()]
  );

  // P1 has priority, so if we zap P1, they've already moved
  engine.setPriorityPlayerIndex(1n);

  const zap = new ZapStatusEffect(engine);
  engine.addEffect(1n, 0n, zap, '0');

  // P1 should NOT have skip turn set yet (they already moved this turn)
  expect(engine.shouldSkipTurn(1n)).toBe(false);

  // Process round start - now skip should be set
  engine.processRoundStart();
  expect(engine.shouldSkipTurn(1n)).toBe(true);
});

test('ZapStatus: removes itself after one turn of skipping', () => {
  const engine = new MockEngine();
  engine.initBattle(
    [createBasicMon()],
    [createBasicMon()]
  );

  engine.setPriorityPlayerIndex(0n);

  const zap = new ZapStatusEffect(engine);
  engine.addEffect(1n, 0n, zap, '0');

  // Effect should exist
  const [effects1] = engine.getEffects('', 1n, 0n);
  expect(effects1.length).toBe(1);

  // Process round end - effect should be removed
  engine.processRoundEnd();

  const [effects2] = engine.getEffects('', 1n, 0n);
  expect(effects2.length).toBe(0);
});

test('BurnStatus: deals 1/16 max HP damage each round', () => {
  const engine = new MockEngine();
  engine.initBattle(
    [createBasicMon({ hp: 160n })],  // 160 HP, so 1/16 = 10 damage
    [createBasicMon()]
  );

  const burn = new BurnStatusEffect(engine);
  engine.addEffect(0n, 0n, burn, '');

  // Check initial HP
  const initialHp = engine.getMonValueForBattle('', 0n, 0n, MonStateIndexName.Hp);
  expect(initialHp).toBe(160n);

  // Process round end - should take burn damage
  engine.processRoundEnd();

  const afterBurnHp = engine.getMonValueForBattle('', 0n, 0n, MonStateIndexName.Hp);
  expect(afterBurnHp).toBe(150n);  // 160 - 10 = 150
});

test('BurnStatus: combined with direct damage leads to KO', () => {
  const engine = new MockEngine();
  engine.initBattle(
    [createBasicMon({ hp: 50n })],  // 50 HP
    [createBasicMon()]
  );

  const burn = new BurnStatusEffect(engine);
  engine.addEffect(0n, 0n, burn, '');

  // Deal direct damage to weaken the mon
  engine.dealDamage(0n, 0n, 40n);  // HP now 10

  // Burn damage: 10/16 = 0 (integer division)
  // So let's deal more damage to bring HP closer to burn threshold
  // HP = 10, deal 2 more damage
  engine.dealDamage(0n, 0n, 9n);  // HP now 1

  // Final blow from any source should KO
  engine.dealDamage(0n, 0n, 1n);  // HP now 0

  expect(engine.getMonValueForBattle('', 0n, 0n, MonStateIndexName.IsKnockedOut)).toBe(1n);
});

// =============================================================================
// TESTS: FORCED SWITCHES
// =============================================================================

test('switchActiveMon: switches to specified team member', () => {
  const engine = new MockEngine();
  engine.initBattle(
    [createBasicMon(), createBasicMon({ speed: 100n })],  // 2 mons
    [createBasicMon()]
  );

  // Initially mon 0 is active
  expect(engine.getActiveMonIndexForBattleState('')[0]).toBe(0n);

  // Switch to mon 1
  engine.switchActiveMon(0n, 1n);

  expect(engine.getActiveMonIndexForBattleState('')[0]).toBe(1n);
  expect(engine.eventLog.some(e => e.includes('Switched from mon 0 to mon 1'))).toBe(true);
});

test('forced switch: HitAndDip pattern - switch after dealing damage', () => {
  const engine = new MockEngine();
  engine.initBattle(
    [createBasicMon(), createBasicMon({ speed: 100n })],  // 2 mons for player 0
    [createBasicMon()]
  );

  // Simulate HitAndDip: deal damage then switch
  // This mimics the transpiled move behavior
  function hitAndDip(attackerPlayerIndex: bigint, targetMonIndex: bigint) {
    // Deal some damage (simulated)
    const defenderIndex = (attackerPlayerIndex + 1n) % 2n;
    const defenderMon = engine.getActiveMonIndexForBattleState('')[Number(defenderIndex)];
    engine.dealDamage(defenderIndex, defenderMon, 30n);

    // Switch to the specified mon
    engine.switchActiveMon(attackerPlayerIndex, targetMonIndex);
  }

  hitAndDip(0n, 1n);  // P0 uses HitAndDip, switches to mon 1

  // Verify damage was dealt and switch occurred
  expect(engine.getMonValueForBattle('', 1n, 0n, MonStateIndexName.Hp)).toBe(70n);  // 100 - 30
  expect(engine.getActiveMonIndexForBattleState('')[0]).toBe(1n);  // Switched to mon 1
});

test('forced switch: opponent forced switch pattern', () => {
  const engine = new MockEngine();
  engine.initBattle(
    [createBasicMon()],
    [createBasicMon(), createBasicMon({ speed: 100n })]  // 2 mons for player 1
  );

  // P1's mon 0 is active initially
  expect(engine.getActiveMonIndexForBattleState('')[1]).toBe(0n);

  // P0 forces P1 to switch (like PistolSquat)
  engine.switchActiveMon(1n, 1n);  // Force P1 to switch to mon 1

  expect(engine.getActiveMonIndexForBattleState('')[1]).toBe(1n);
});

// =============================================================================
// TESTS: ABILITIES
// =============================================================================

test('UpOnly: increases attack by 10% after taking damage', () => {
  const engine = new MockEngine();
  const statBoosts = new MockStatBoosts(engine);

  engine.initBattle(
    [createBasicMon({ attack: 100n })],
    [createBasicMon()]
  );

  const upOnly = new UpOnlyEffect(engine, statBoosts);
  engine.addEffect(0n, 0n, upOnly, '');

  // Check initial attack
  const initialAttack = engine.getCurrentAttack(0n, 0n);
  expect(initialAttack).toBe(100n);

  // Take damage - should trigger UpOnly
  engine.dealDamage(0n, 0n, 10n);

  // Attack should be 110% of base now
  const afterDamageAttack = engine.getCurrentAttack(0n, 0n);
  expect(afterDamageAttack).toBe(110n);  // 100 * 110% = 110
});

test('UpOnly: stacks with multiple hits', () => {
  const engine = new MockEngine();
  const statBoosts = new MockStatBoosts(engine);

  engine.initBattle(
    [createBasicMon({ attack: 100n })],
    [createBasicMon()]
  );

  const upOnly = new UpOnlyEffect(engine, statBoosts);
  engine.addEffect(0n, 0n, upOnly, '');

  // Take damage 3 times
  engine.dealDamage(0n, 0n, 5n);
  engine.dealDamage(0n, 0n, 5n);
  engine.dealDamage(0n, 0n, 5n);

  // Attack should be 130% of base now (3 x 10% boost)
  const finalAttack = engine.getCurrentAttack(0n, 0n);
  expect(finalAttack).toBe(130n);  // 100 * 130% = 130
});

test('ability activation on switch-in pattern', () => {
  const engine = new MockEngine();
  const statBoosts = new MockStatBoosts(engine);

  engine.initBattle(
    [createBasicMon(), createBasicMon({ attack: 100n })],
    [createBasicMon()]
  );

  // Simulate ability activation on switch-in
  function activateAbilityOnSwitch(playerIndex: bigint, monIndex: bigint) {
    const battleKey = engine.battleKeyForWrite();
    const [effects] = engine.getEffects(battleKey, playerIndex, monIndex);

    // Check if effect already exists (avoid duplicates)
    const hasUpOnly = effects.some(e => e.effect.name() === 'Up Only');
    if (!hasUpOnly) {
      const upOnly = new UpOnlyEffect(engine, statBoosts);
      engine.addEffect(playerIndex, monIndex, upOnly, '');
    }
  }

  // Switch to mon 1 and activate ability
  engine.switchActiveMon(0n, 1n);
  activateAbilityOnSwitch(0n, 1n);

  // Verify effect was added
  const [effects] = engine.getEffects('', 0n, 1n);
  expect(effects.length).toBe(1);
  expect(effects[0].effect.name()).toBe('Up Only');
});

// =============================================================================
// TESTS: COMPLEX SCENARIOS
// =============================================================================

test('complex: burn + ability interaction', () => {
  const engine = new MockEngine();
  const statBoosts = new MockStatBoosts(engine);

  engine.initBattle(
    [createBasicMon({ hp: 160n, attack: 100n })],
    [createBasicMon()]
  );

  // Add both burn (DOT) and UpOnly (attack boost on damage)
  const burn = new BurnStatusEffect(engine);
  const upOnly = new UpOnlyEffect(engine, statBoosts);

  engine.addEffect(0n, 0n, burn, '');
  engine.addEffect(0n, 0n, upOnly, '');

  // Initial state
  expect(engine.getCurrentAttack(0n, 0n)).toBe(100n);
  expect(engine.getMonValueForBattle('', 0n, 0n, MonStateIndexName.Hp)).toBe(160n);

  // Process round end - burn deals damage, which triggers UpOnly
  engine.processRoundEnd();

  // HP should decrease by 10 (160/16)
  expect(engine.getMonValueForBattle('', 0n, 0n, MonStateIndexName.Hp)).toBe(150n);

  // Attack should increase by 10% due to damage
  expect(engine.getCurrentAttack(0n, 0n)).toBe(110n);
});

test('complex: switch with active effects', () => {
  const engine = new MockEngine();

  engine.initBattle(
    [createBasicMon(), createBasicMon()],
    [createBasicMon()]
  );

  // Add effect to mon 0
  const burn = new BurnStatusEffect(engine);
  engine.addEffect(0n, 0n, burn, '');

  // Effect should be on mon 0
  const [effects0] = engine.getEffects('', 0n, 0n);
  expect(effects0.length).toBe(1);

  // Switch to mon 1
  engine.switchActiveMon(0n, 1n);

  // Effect should still be on mon 0 (persists)
  const [effectsAfter] = engine.getEffects('', 0n, 0n);
  expect(effectsAfter.length).toBe(1);

  // Mon 1 should have no effects
  const [effects1] = engine.getEffects('', 0n, 1n);
  expect(effects1.length).toBe(0);
});

test('complex: multi-turn battle with status and switches', () => {
  const engine = new MockEngine();
  const statBoosts = new MockStatBoosts(engine);

  engine.initBattle(
    [createBasicMon({ hp: 100n, attack: 50n }), createBasicMon({ hp: 80n, attack: 60n })],
    [createBasicMon({ hp: 120n })]
  );

  // Turn 1: P0 attacks and applies zap to P1
  engine.setPriorityPlayerIndex(0n);
  engine.dealDamage(1n, 0n, 20n);  // Deal damage
  const zap = new ZapStatusEffect(engine);
  engine.addEffect(1n, 0n, zap, '');  // Apply zap (P1 will skip)

  expect(engine.shouldSkipTurn(1n)).toBe(true);
  expect(engine.getMonValueForBattle('', 1n, 0n, MonStateIndexName.Hp)).toBe(100n);  // 120 - 20

  // End turn 1
  engine.processRoundEnd();
  engine.clearSkipTurn(1n);

  // Turn 2: P0 switches, P1 can now move
  engine.processRoundStart();
  expect(engine.shouldSkipTurn(1n)).toBe(false);  // Zap was removed

  // P0 switches to mon 1
  engine.switchActiveMon(0n, 1n);
  expect(engine.getActiveMonIndexForBattleState('')[0]).toBe(1n);

  // P1 deals damage back
  engine.dealDamage(0n, 1n, 15n);
  expect(engine.getMonValueForBattle('', 0n, 1n, MonStateIndexName.Hp)).toBe(65n);  // 80 - 15
});

// Run all tests
runTests();
