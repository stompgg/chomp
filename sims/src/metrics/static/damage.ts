import type { MonRow, MoveRow, Roster } from '../../util/csv-load';
import type { BestMoveCell, DamageDerivedMetrics, DamageMatrix } from './types';

const HARD_WALL_PCT = 15;
const COVERAGE_3HKO_HP_PCT = 100 / 3;

export function typeMult(typeChart: Roster['typeChart'], moveType: string, t1: string, t2: string): number {
  const m1 = typeChart[moveType]?.[t1] ?? 1;
  const m2 = t2 === 'NA' ? 1 : (typeChart[moveType]?.[t2] ?? 1);
  return m1 * m2;
}

export function calcDamage(move: MoveRow, attacker: MonRow, defender: MonRow, typeChart: Roster['typeChart']): { damage: number; percentHp: number; typeMult: number } | null {
  if (move.power === null || move.power === 0) return null;
  if (move.cls !== 'Physical' && move.cls !== 'Special') return null;
  const atk = move.cls === 'Physical' ? attacker.attack : attacker.specialAttack;
  const def = move.cls === 'Physical' ? defender.defense : defender.specialDefense;
  const tm = typeMult(typeChart, move.type, defender.type1, defender.type2);
  const damage = ((move.power * atk) / def) * tm;
  return { damage, percentHp: (damage / defender.hp) * 100, typeMult: tm };
}

export function bestMoveAgainst(roster: Roster, attacker: MonRow, defender: MonRow): BestMoveCell {
  const moves = roster.movesByMon.get(attacker.name) ?? [];
  let best: BestMoveCell = {
    attacker: attacker.name,
    defender: defender.name,
    moveName: null,
    moveType: null,
    moveClass: null,
    damage: 0,
    percentHp: 0,
    htko: Infinity,
    typeMult: 0,
  };
  for (const move of moves) {
    const r = calcDamage(move, attacker, defender, roster.typeChart);
    if (!r) continue;
    if (r.percentHp > best.percentHp) {
      best = {
        attacker: attacker.name,
        defender: defender.name,
        moveName: move.name,
        moveType: move.type,
        moveClass: move.cls,
        damage: r.damage,
        percentHp: r.percentHp,
        htko: r.damage > 0 ? Math.ceil(defender.hp / r.damage) : Infinity,
        typeMult: r.typeMult,
      };
    }
  }
  return best;
}

export function buildDamageMatrix(roster: Roster): DamageMatrix {
  const names = roster.mons.map((m) => m.name);
  const cells: BestMoveCell[][] = roster.mons.map((att) =>
    roster.mons.map((def) => bestMoveAgainst(roster, att, def)),
  );
  return { attackers: names, defenders: names, cells };
}

export function deriveDamageMetrics(roster: Roster, matrix: DamageMatrix): DamageDerivedMetrics {
  let twoHkoCount = 0;
  let hardWallCount = 0;
  let totalPairs = 0;
  for (let i = 0; i < matrix.attackers.length; i++) {
    for (let j = 0; j < matrix.defenders.length; j++) {
      if (i === j) continue;
      totalPairs++;
      const c = matrix.cells[i][j];
      if (c.htko <= 2) twoHkoCount++;
      if (c.percentHp < HARD_WALL_PCT) hardWallCount++;
    }
  }
  const coverageGapsByMon = matrix.attackers.map((mon, i) => {
    const opponents: string[] = [];
    for (let j = 0; j < matrix.defenders.length; j++) {
      if (i === j) continue;
      if (matrix.cells[i][j].percentHp < COVERAGE_3HKO_HP_PCT) {
        opponents.push(matrix.defenders[j]);
      }
    }
    return { mon, opponents };
  });
  const vulnerabilityByMon = matrix.defenders.map((mon, j) => {
    const opponents: string[] = [];
    for (let i = 0; i < matrix.attackers.length; i++) {
      if (i === j) continue;
      if (matrix.cells[i][j].htko <= 1) opponents.push(matrix.attackers[i]);
    }
    return { mon, opponents };
  });
  return {
    twoHkoRatePct: (twoHkoCount / totalPairs) * 100,
    hardWallRatePct: (hardWallCount / totalPairs) * 100,
    coverageGapsByMon,
    vulnerabilityByMon,
  };
}
