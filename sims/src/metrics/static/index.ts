import type { Roster } from '../../util/csv-load';
import { buildDamageMatrix, deriveDamageMetrics } from './damage';
import { computeOutspeed, computeStatRanks, computeTypeCoverage } from './stats';
import type { StaticMetrics } from './types';

export function computeStaticMetrics(roster: Roster): StaticMetrics {
  const damageMatrix = buildDamageMatrix(roster);
  return {
    damageMatrix,
    damageDerived: deriveDamageMetrics(roster, damageMatrix),
    statRanks: computeStatRanks(roster),
    typeCoverage: computeTypeCoverage(roster),
    outspeed: computeOutspeed(roster),
  };
}

export type { StaticMetrics } from './types';
