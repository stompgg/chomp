import type { StaticMetrics } from '../metrics/static';
import type { EngineDamageHistogram } from '../metrics/engine/damage-hist';

export type FlagSeverity = 'info' | 'warn' | 'flag';

export interface Flag {
  rule: string;
  severity: FlagSeverity;
  target: string;
  detail: string;
  metric: number | string;
  suggestion: string;
}

export interface ReportMeta {
  generatedAt: string;
  rosterSize: number;
  movesCount: number;
  seedCount: number | null;
  notes: string[];
}

export interface Report {
  meta: ReportMeta;
  flags: Flag[];
  static: StaticMetrics;
  engine: EngineDamageHistogram | null;
}
