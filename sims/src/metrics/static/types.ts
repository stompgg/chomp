import type { MoveClass } from '../../util/csv-load';

export interface BestMoveCell {
  attacker: string;
  defender: string;
  moveName: string | null;
  moveType: string | null;
  moveClass: MoveClass | null;
  damage: number;
  percentHp: number;
  htko: number;
  typeMult: number;
}

export interface DamageMatrix {
  defenders: string[];
  attackers: string[];
  cells: BestMoveCell[][];
}

export interface MonOpponentList {
  mon: string;
  opponents: string[];
}

export interface DamageDerivedMetrics {
  twoHkoRatePct: number;
  hardWallRatePct: number;
  coverageGapsByMon: MonOpponentList[];
  vulnerabilityByMon: MonOpponentList[];
}

export interface StatRanks {
  byMon: {
    mon: string;
    bst: number;
    ranks: Record<string, number>;
    compositeScore: number;
    topTenPctCount: number;
    botTenPctCount: number;
  }[];
}

export interface TypeCoverage {
  byMon: { mon: string; superEffectiveTypes: string[]; count: number }[];
}

export interface OutspeedMatrix {
  byMon: { mon: string; speed: number; outspeedPct: number }[];
}

export interface StaticMetrics {
  damageMatrix: DamageMatrix;
  damageDerived: DamageDerivedMetrics;
  statRanks: StatRanks;
  typeCoverage: TypeCoverage;
  outspeed: OutspeedMatrix;
}
