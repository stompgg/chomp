/**
 * Self-contained port of munch's `cpu-team-builder.buildRandomTeam`. Reproduces the EXACT rng-draw
 * sequence — including the four facet draws (their values are unused here, but each consumes one draw
 * off the shared teamRng, so dropping them would desync the second team and break cross-repo parity).
 */
import { loadRoster } from '../util/csv-load';
import { TEAM_SIZE } from '../cpu/constants';

type Rng = () => number;

const TOTAL_FACETS = 12;
const RANDOM_REPEAT_BIAS = 0.04;

// Mon ids [0..12] in id order — matches munch's `Object.values(MonMetadata).map(m => BigInt(m.id))`.
const ALL_MON_IDS: readonly bigint[] = loadRoster().mons
  .slice()
  .sort((a, b) => a.id - b.id)
  .map((m) => BigInt(m.id));

function randomFacetId(rand: Rng): number {
  return 1 + Math.floor(rand() * TOTAL_FACETS);
}

export function buildRandomTeam(rand: Rng): { monIndices: bigint[] } {
  const monIndices: bigint[] = [];
  const remaining = ALL_MON_IDS.slice();
  for (let i = 0; i < TEAM_SIZE; i++) {
    if (i > 0 && rand() < RANDOM_REPEAT_BIAS) {
      monIndices.push(monIndices[Math.floor(rand() * i)]);
    } else {
      const idx = Math.floor(rand() * remaining.length);
      monIndices.push(remaining[idx]);
      remaining.splice(idx, 1);
    }
  }
  // Facet draws — value discarded, but the draws must happen to keep the rng stream in lockstep.
  for (let i = 0; i < TEAM_SIZE; i++) randomFacetId(rand);
  return { monIndices };
}
