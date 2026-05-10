import type { Roster } from '../../util/csv-load';
import type { OutspeedMatrix, StatRanks, TypeCoverage } from './types';
import { typeMult } from './damage';

const STAT_KEYS = ['hp', 'attack', 'defense', 'specialAttack', 'specialDefense', 'speed'] as const;
type StatKey = typeof STAT_KEYS[number];

const TOP_PERCENTILE = 0.90;
const BOT_PERCENTILE = 0.10;

export function computeStatRanks(roster: Roster): StatRanks {
  const total = roster.mons.length;
  const sortedByStat: Record<StatKey, number[]> = {} as any;
  for (const k of STAT_KEYS) {
    sortedByStat[k] = roster.mons.map((m) => m[k]).sort((a, b) => b - a);
  }

  return {
    byMon: roster.mons.map((mon) => {
      const ranks: Record<string, number> = {};
      let topCount = 0;
      let botCount = 0;
      let composite = 0;
      for (const k of STAT_KEYS) {
        const r = sortedByStat[k].indexOf(mon[k]) + 1;
        ranks[k] = r;
        const pct = 1 - (r - 1) / total;
        composite += pct;
        if (pct >= TOP_PERCENTILE) topCount++;
        if (pct <= BOT_PERCENTILE) botCount++;
      }
      return {
        mon: mon.name,
        bst: mon.bst,
        ranks,
        compositeScore: composite,
        topTenPctCount: topCount,
        botTenPctCount: botCount,
      };
    }),
  };
}

export function computeTypeCoverage(roster: Roster): TypeCoverage {
  return {
    byMon: roster.mons.map((attacker) => {
      const moves = roster.movesByMon.get(attacker.name) ?? [];
      const seTypes = new Set<string>();
      for (const move of moves) {
        if (move.power === null || move.power === 0) continue;
        if (move.cls !== 'Physical' && move.cls !== 'Special') continue;
        for (const def of roster.mons) {
          if (def.name === attacker.name) continue;
          if (typeMult(roster.typeChart, move.type, def.type1, def.type2) > 1) {
            seTypes.add(def.type1);
            if (def.type2 !== 'NA') seTypes.add(def.type2);
          }
        }
      }
      return { mon: attacker.name, superEffectiveTypes: [...seTypes].sort(), count: seTypes.size };
    }),
  };
}

export function computeOutspeed(roster: Roster): OutspeedMatrix {
  const total = roster.mons.length - 1;
  return {
    byMon: roster.mons.map((mon) => {
      const outspeedCount = roster.mons.filter((other) => other.name !== mon.name && mon.speed > other.speed).length;
      return {
        mon: mon.name,
        speed: mon.speed,
        outspeedPct: (outspeedCount / total) * 100,
      };
    }),
  };
}

