import type { StaticMetrics } from '../metrics/static';
import type { EngineDamageHistogram } from '../metrics/engine/damage-hist';
import type { Roster } from '../util/csv-load';
import { calcDamage } from '../metrics/static/damage';
import type { Flag } from './types';

const STAT_DOMINANCE_MIN = 3;
const STAT_DUMP_MIN = 3;
const COVERAGE_GAP_PCT = 0.40;
const VULNERABILITY_PCT = 0.25;
const HARD_WALL_PCT_THRESHOLD = 15;

const EMPIRICAL_OHKO_THRESHOLD = 0.50;
const CRIT_OHKO_THRESHOLD = 0.80;
const CRIT_OHKO_MIN_DEFENDERS = 3;

const THREE_HKO_PCT = 100 / 3;

interface BumpSuggestion {
  move: string;
  from: number;
  to: number;
  opps: string[];
}

function suggestOffensiveBumps(roster: Roster, attackerName: string, gapOpponents: string[]): BumpSuggestion[] {
  const attacker = roster.monByName.get(attackerName);
  if (!attacker) return [];
  const moves = (roster.movesByMon.get(attackerName) ?? []).filter(
    (m) => m.power !== null && m.power > 0 && (m.cls === 'Physical' || m.cls === 'Special'),
  );
  // For each gap opponent, find the move with the smallest power bump that 3HKOs them.
  type Cheapest = { move: string; from: number; to: number; opp: string };
  const perOpp: Cheapest[] = [];
  for (const opName of gapOpponents) {
    const op = roster.monByName.get(opName);
    if (!op) continue;
    let best: Cheapest | null = null;
    for (const mv of moves) {
      const r = calcDamage(mv, attacker, op, roster.typeChart);
      if (!r || r.damage <= 0) continue;
      const targetDamage = op.hp / 3 + 0.01;
      const ratio = targetDamage / r.damage;
      const newPower = Math.min(255, Math.ceil((mv.power! * ratio) / 5) * 5);
      if (newPower <= mv.power!) continue;
      if (!best || newPower - mv.power! < best.to - best.from) {
        best = { move: mv.name, from: mv.power!, to: newPower, opp: opName };
      }
    }
    if (best) perOpp.push(best);
  }
  // Group by (move, target power) so a single bump that fixes multiple opponents shows as one suggestion.
  const grouped = new Map<string, BumpSuggestion>();
  for (const c of perOpp) {
    const key = `${c.move}@${c.to}`;
    if (!grouped.has(key)) grouped.set(key, { move: c.move, from: c.from, to: c.to, opps: [] });
    grouped.get(key)!.opps.push(c.opp);
  }
  return [...grouped.values()].sort(
    (a, b) => b.opps.length - a.opps.length || (a.to - a.from) - (b.to - b.from),
  );
}

export function evaluateFlags(metrics: StaticMetrics, roster: Roster, engine: EngineDamageHistogram | null = null): Flag[] {
  const flags: Flag[] = [];
  const rosterSize = metrics.statRanks.byMon.length;

  for (const s of metrics.statRanks.byMon) {
    if (s.topTenPctCount >= STAT_DOMINANCE_MIN) {
      flags.push({
        rule: 'stat-dominance',
        severity: 'flag',
        target: s.mon,
        detail: `top 10% in ${s.topTenPctCount} of 6 stats (BST ${s.bst}, composite ${s.compositeScore.toFixed(2)})`,
        metric: s.topTenPctCount,
        suggestion: 'consider trimming the highest-ranked stat by ~5',
      });
    }
    if (s.botTenPctCount >= STAT_DUMP_MIN) {
      flags.push({
        rule: 'stat-dump',
        severity: 'warn',
        target: s.mon,
        detail: `bottom 10% in ${s.botTenPctCount} of 6 stats (BST ${s.bst})`,
        metric: s.botTenPctCount,
        suggestion: 'may be unviable; check whether ability/moves compensate',
      });
    }
  }

  const opponentCount = rosterSize - 1;
  for (const c of metrics.damageDerived.coverageGapsByMon) {
    const count = c.opponents.length;
    if (count / opponentCount > COVERAGE_GAP_PCT) {
      const bumps = suggestOffensiveBumps(roster, c.mon, c.opponents);
      const suggestion = bumps.length === 0
        ? 'no power bump can 3HKO any gap opponent (likely type-immunity); add an off-type move'
        : bumps
          .slice(0, 3)
          .map((b) => `bump ${b.move} ${b.from}→${b.to} to 3HKO ${b.opps.join(', ')}`)
          .join('\n');
      flags.push({
        rule: 'offensive-vacuum',
        severity: 'flag',
        target: c.mon,
        detail: `no 3HKO against ${count}/${opponentCount} opponents (${c.opponents.join(', ')})`,
        metric: count,
        suggestion,
      });
    }
  }
  for (const v of metrics.damageDerived.vulnerabilityByMon) {
    const count = v.opponents.length;
    if (count / opponentCount > VULNERABILITY_PCT) {
      flags.push({
        rule: 'defensive-vacuum',
        severity: 'flag',
        target: v.mon,
        detail: `OHKO'd at avg roll by ${count}/${opponentCount} opponents (${v.opponents.join(', ')})`,
        metric: count,
        suggestion: 'raise HP or a defensive stat',
      });
    }
  }

  for (const t of metrics.typeCoverage.byMon) {
    if (t.count === 0) {
      flags.push({
        rule: 'type-coverage-gap',
        severity: 'warn',
        target: t.mon,
        detail: 'no moves are super-effective against any roster type',
        metric: 0,
        suggestion: 'swap one move for off-type coverage',
      });
    }
  }

  for (let i = 0; i < metrics.damageMatrix.attackers.length; i++) {
    for (let j = i + 1; j < metrics.damageMatrix.defenders.length; j++) {
      const ab = metrics.damageMatrix.cells[i][j];
      const ba = metrics.damageMatrix.cells[j][i];
      if (ab.percentHp < HARD_WALL_PCT_THRESHOLD && ba.percentHp < HARD_WALL_PCT_THRESHOLD) {
        flags.push({
          rule: 'hard-wall',
          severity: 'info',
          target: `${ab.attacker} ↔ ${ab.defender}`,
          detail: `mutual best-move damage <${HARD_WALL_PCT_THRESHOLD}% HP (${ab.percentHp.toFixed(0)}% / ${ba.percentHp.toFixed(0)}%)`,
          metric: Math.max(ab.percentHp, ba.percentHp),
          suggestion: 'matchup is a stalemate',
        });
      }
      if (ab.htko <= 1 && ba.htko <= 1) {
        flags.push({
          rule: 'mutual-ohko',
          severity: 'flag',
          target: `${ab.attacker} ↔ ${ab.defender}`,
          detail: `both sides OHKO at avg roll — speed tier alone decides outcome`,
          metric: 1,
          suggestion: 'elevate one mon\'s bulk or lower the other\'s offense',
        });
      }
    }
  }

  if (engine) {
    for (const c of engine.cells) {
      if (c.ohkoProbability >= EMPIRICAL_OHKO_THRESHOLD) {
        flags.push({
          rule: 'empirical-ohko',
          severity: 'flag',
          target: `${c.attacker} → ${c.defender}`,
          detail: `${c.moveName} OHKOs in ${(c.ohkoProbability * 100).toFixed(0)}% of ${c.seedCount} seeds (mean ${c.mean.toFixed(0)}% HP)`,
          metric: c.ohkoProbability,
          suggestion: 'matchup is decided pre-roll',
        });
      }
    }
    const critOhkoTargets = new Map<string, { defenders: string[]; max: number }>();
    for (const c of engine.cells) {
      if (c.critOhkoProbability >= CRIT_OHKO_THRESHOLD) {
        const key = `${c.attacker}/${c.moveName}`;
        const e = critOhkoTargets.get(key) ?? { defenders: [], max: 0 };
        e.defenders.push(c.defender);
        e.max = Math.max(e.max, c.critOhkoProbability);
        critOhkoTargets.set(key, e);
      }
    }
    for (const [key, e] of critOhkoTargets) {
      if (e.defenders.length >= CRIT_OHKO_MIN_DEFENDERS) {
        flags.push({
          rule: 'crit-ohko-rate',
          severity: 'flag',
          target: key,
          detail: `crit-conditional OHKO rate ≥${(CRIT_OHKO_THRESHOLD * 100).toFixed(0)}% against ${e.defenders.length} defenders (max ${(e.max * 100).toFixed(0)}%)`,
          metric: e.max,
          suggestion: 'crit ceiling too lethal; lower base power or raise stamina cost (crit mult is global, not a per-move lever)',
        });
      }
    }
  }

  const severityOrder: Record<Flag['severity'], number> = { flag: 0, warn: 1, info: 2 };
  flags.sort((a, b) => severityOrder[a.severity] - severityOrder[b.severity] || a.rule.localeCompare(b.rule));
  return flags;
}
