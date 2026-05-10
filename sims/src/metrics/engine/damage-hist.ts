import type { MonRow, MoveRow, Roster } from '../../util/csv-load';
import { buildMonConfig, findDamagingMove } from '../../util/mon-builder';
import { calcDamage } from '../static/damage';
import { buildMon, executeTurn, makeSimContext, startBattle } from '../../harness';

const CRIT_THRESHOLD_MULT = 1.2;

export interface DamageObservation {
  damage: number;
  percentHp: number;
  isKO: boolean;
  isCrit: boolean;
  isMiss: boolean;
}

export interface DamageDistribution {
  attacker: string;
  defender: string;
  moveName: string;
  movePower: number;
  moveStamina: number;
  defenderHp: number;
  staticAvgPercentHp: number;
  seedCount: number;
  min: number;
  max: number;
  mean: number;
  p50: number;
  p95: number;
  ohkoProbability: number;
  critProbability: number;
  critOhkoProbability: number;
  missRate: number;
}

const NO_OP = 126;

function runOneAttackInContext(
  ctx: ReturnType<typeof makeSimContext>,
  attacker: MonRow,
  defender: MonRow,
  attackerConfig: NonNullable<ReturnType<typeof buildMonConfig>['config']>,
  defenderConfig: NonNullable<ReturnType<typeof buildMonConfig>['config']>,
  attackerMoveSlot: number,
  seed: bigint,
): DamageObservation {
  const aBuilt = buildMon(ctx, attackerConfig);
  const dBuilt = buildMon(ctx, defenderConfig);
  const { battleKey } = startBattle(ctx, [aBuilt], [dBuilt]);
  executeTurn(ctx, battleKey, { p0MoveIndex: NO_OP, p1MoveIndex: NO_OP, p0Salt: 0n, p1Salt: 0n });
  const result = executeTurn(ctx, battleKey, {
    p0MoveIndex: attackerMoveSlot,
    p1MoveIndex: NO_OP,
    p0Salt: seed,
    p1Salt: seed ^ 0xdeadbeefn,
  });
  const defState = result.p1States[0];
  const damage = -Number(defState.hpDelta);
  return { damage, percentHp: (damage / defender.hp) * 100, isKO: defState.isKnockedOut, isCrit: false, isMiss: false };
}

export function runOneAttack(
  roster: Roster,
  attacker: MonRow,
  defender: MonRow,
  attackerMoveSlot: number,
  seed: bigint,
): DamageObservation | null {
  const ar = buildMonConfig(roster, attacker);
  const dr = buildMonConfig(roster, defender);
  if (!ar.config || !dr.config) return null;
  const ctx = makeSimContext({ monsPerTeam: 1n });
  return runOneAttackInContext(ctx, attacker, defender, ar.config, dr.config, attackerMoveSlot, seed);
}

function classifyObservations(
  observations: { damage: number; isKO: boolean }[],
  staticDamage: number,
  hp: number,
  accuracy: number,
): { isCrit: boolean; isMiss: boolean }[] {
  return observations.map((o) => {
    if (o.damage === 0 && staticDamage > 0 && accuracy < 100) return { isCrit: false, isMiss: true };
    if (staticDamage > 0 && o.damage >= staticDamage * CRIT_THRESHOLD_MULT) return { isCrit: true, isMiss: false };
    return { isCrit: false, isMiss: false };
  });
}

function quantile(sorted: number[], q: number): number {
  if (sorted.length === 0) return 0;
  const idx = (sorted.length - 1) * q;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}

export function runDamageDistribution(
  roster: Roster,
  attacker: MonRow,
  defender: MonRow,
  move: MoveRow,
  attackerMoveSlot: number,
  seedCount: number,
  seedBase: bigint = 1n,
): DamageDistribution {
  const ar = buildMonConfig(roster, attacker);
  const dr = buildMonConfig(roster, defender);
  if (!ar.config || !dr.config) {
    return {
      attacker: attacker.name,
      defender: defender.name,
      moveName: move.name,
      movePower: move.power ?? 0,
      moveStamina: move.stamina ?? 0,
      defenderHp: defender.hp,
      staticAvgPercentHp: 0,
      seedCount: 0,
      min: 0, max: 0, mean: 0, p50: 0, p95: 0,
      ohkoProbability: 0,
      critProbability: 0,
      critOhkoProbability: 0,
      missRate: 0,
    };
  }
  const baseStatic = calcDamage(move, attacker, defender, roster.typeChart);
  const staticDamage = baseStatic?.damage ?? 0;
  const staticAvgPercentHp = baseStatic?.percentHp ?? 0;
  const ctx = makeSimContext({ monsPerTeam: 1n });
  const observations: { damage: number; percentHp: number; isKO: boolean }[] = [];
  for (let i = 0; i < seedCount; i++) {
    observations.push(runOneAttackInContext(ctx, attacker, defender, ar.config, dr.config, attackerMoveSlot, seedBase + BigInt(i)));
  }
  const classes = classifyObservations(observations, staticDamage, defender.hp, move.accuracy ?? 100);
  let kos = 0;
  let critKos = 0;
  let crits = 0;
  let misses = 0;
  for (let i = 0; i < observations.length; i++) {
    if (observations[i].isKO) {
      kos++;
      if (classes[i].isCrit) critKos++;
    }
    if (classes[i].isCrit) crits++;
    if (classes[i].isMiss) misses++;
  }
  const damages = observations.map((o) => o.percentHp).sort((a, b) => a - b);
  return {
    attacker: attacker.name,
    defender: defender.name,
    moveName: move.name,
    movePower: move.power ?? 0,
    moveStamina: move.stamina ?? 0,
    defenderHp: defender.hp,
    staticAvgPercentHp,
    seedCount,
    min: damages[0],
    max: damages[damages.length - 1],
    mean: damages.reduce((a, b) => a + b, 0) / damages.length,
    p50: quantile(damages, 0.5),
    p95: quantile(damages, 0.95),
    ohkoProbability: kos / seedCount,
    critProbability: crits / seedCount,
    critOhkoProbability: crits > 0 ? critKos / crits : 0,
    missRate: misses / seedCount,
  };
}

export interface EngineDamageHistogram {
  cells: DamageDistribution[];
  seedsPerCell: number;
  buildableMons: string[];
  unbuildableMons: { mon: string; missingMoves: string[]; missingAbility: string | null }[];
}

function bestStaticMoveAgainst(
  roster: Roster,
  attacker: MonRow,
  defender: MonRow,
  resolvedMoves: { move: MoveRow; index: number }[],
): { move: MoveRow; index: number } | null {
  // resolvedMoves entries may also carry a `.source` we don't need here.
  let best: { move: MoveRow; index: number; damage: number } | null = null;
  for (const rm of resolvedMoves) {
    const r = calcDamage(rm.move, attacker, defender, roster.typeChart);
    if (!r) continue;
    if (best === null || r.damage > best.damage) {
      best = { move: rm.move, index: rm.index, damage: r.damage };
    }
  }
  return best ? { move: best.move, index: best.index } : null;
}

export function runEngineDamageHistogram(roster: Roster, seedsPerCell: number): EngineDamageHistogram {
  type Buildable = {
    mon: MonRow;
    config: NonNullable<ReturnType<typeof buildMonConfig>['config']>;
    resolvedMoves: ReturnType<typeof buildMonConfig>['resolvedMoves'];
  };
  const buildable: Buildable[] = [];
  const unbuildable: { mon: string; missingMoves: string[]; missingAbility: string | null }[] = [];
  for (const m of roster.mons) {
    const r = buildMonConfig(roster, m);
    if (!r.config) {
      unbuildable.push({ mon: m.name, missingMoves: r.missingMoves, missingAbility: r.missingAbility });
      continue;
    }
    if (!findDamagingMove(r.resolvedMoves.map((rm) => rm.move))) {
      unbuildable.push({ mon: m.name, missingMoves: ['no damaging move available'], missingAbility: null });
      continue;
    }
    buildable.push({ mon: m, config: r.config, resolvedMoves: r.resolvedMoves });
  }
  const cells: DamageDistribution[] = [];
  const ctx = makeSimContext({ monsPerTeam: 1n });
  for (const att of buildable) {
    for (const def of buildable) {
      if (att.mon.name === def.mon.name) continue;
      const best = bestStaticMoveAgainst(roster, att.mon, def.mon, att.resolvedMoves);
      if (!best) continue;
      const baseStatic = calcDamage(best.move, att.mon, def.mon, roster.typeChart);
      const staticAvgPercentHp = baseStatic?.percentHp ?? 0;
      const observations: { damage: number; percentHp: number; isKO: boolean }[] = [];
      for (let i = 0; i < seedsPerCell; i++) {
        observations.push(runOneAttackInContext(ctx, att.mon, def.mon, att.config, def.config, best.index, BigInt(i + 1)));
      }
      const classes = classifyObservations(observations, baseStatic?.damage ?? 0, def.mon.hp, best.move.accuracy ?? 100);
      let kos = 0, critKos = 0, crits = 0, misses = 0;
      for (let i = 0; i < observations.length; i++) {
        if (observations[i].isKO) {
          kos++;
          if (classes[i].isCrit) critKos++;
        }
        if (classes[i].isCrit) crits++;
        if (classes[i].isMiss) misses++;
      }
      const damages = observations.map((o) => o.percentHp).sort((a, b) => a - b);
      cells.push({
        attacker: att.mon.name,
        defender: def.mon.name,
        moveName: best.move.name,
        movePower: best.move.power ?? 0,
        moveStamina: best.move.stamina ?? 0,
        defenderHp: def.mon.hp,
        staticAvgPercentHp,
        seedCount: seedsPerCell,
        min: damages[0],
        max: damages[damages.length - 1],
        mean: damages.reduce((a, b) => a + b, 0) / damages.length,
        p50: quantile(damages, 0.5),
        p95: quantile(damages, 0.95),
        ohkoProbability: kos / seedsPerCell,
        critProbability: crits / seedsPerCell,
        critOhkoProbability: crits > 0 ? critKos / crits : 0,
        missRate: misses / seedsPerCell,
      });
    }
  }
  return { cells, seedsPerCell, buildableMons: buildable.map((b) => b.mon.name), unbuildableMons: unbuildable };
}
