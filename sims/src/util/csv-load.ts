import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const DROOL_DIR = join(import.meta.dir, '..', '..', '..', 'drool');

export interface MonRow {
  id: number;
  name: string;
  hp: number;
  attack: number;
  defense: number;
  specialAttack: number;
  specialDefense: number;
  speed: number;
  type1: string;
  type2: string;
  bst: number;
  flavor: string;
}

export type MoveClass = 'Physical' | 'Special' | 'Self' | 'Other';

export interface MoveRow {
  name: string;
  mon: string;
  power: number | null;
  stamina: number | null;
  accuracy: number | null;
  priority: number;
  type: string;
  cls: MoveClass;
  description: string;
  inputType: string;
}

function parseNumOrNull(s: string): number | null {
  if (s === '?' || s === '') return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

export interface AbilityRow {
  name: string;
  mon: string;
  effect: string;
}

export type TypeChart = Record<string, Record<string, number>>;

function parseCsvLine(line: string): string[] {
  const out: string[] = [];
  let cur = '';
  let inQ = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === '"') {
      if (inQ && line[i + 1] === '"') {
        cur += '"';
        i++;
      } else {
        inQ = !inQ;
      }
    } else if (c === ',' && !inQ) {
      out.push(cur);
      cur = '';
    } else {
      cur += c;
    }
  }
  out.push(cur);
  return out;
}

function parseCsv(text: string): { header: string[]; rows: string[][] } {
  const lines = text.split('\n').filter((l) => l.length > 0);
  const header = parseCsvLine(lines[0]);
  const rows = lines.slice(1).map(parseCsvLine).filter((r) => r.some((c) => c.length > 0));
  return { header, rows };
}

export function loadMons(): MonRow[] {
  const text = readFileSync(join(DROOL_DIR, 'mons.csv'), 'utf8');
  const { rows } = parseCsv(text);
  return rows.map((r) => {
    const hp = Number(r[2]);
    const attack = Number(r[3]);
    const defense = Number(r[4]);
    const specialAttack = Number(r[5]);
    const specialDefense = Number(r[6]);
    const speed = Number(r[7]);
    return {
      id: Number(r[0]),
      name: r[1],
      hp,
      attack,
      defense,
      specialAttack,
      specialDefense,
      speed,
      type1: r[8],
      type2: r[9],
      bst: hp + attack + defense + specialAttack + specialDefense + speed,
      flavor: r[10],
    };
  });
}

export function loadMoves(): MoveRow[] {
  const text = readFileSync(join(DROOL_DIR, 'moves.csv'), 'utf8');
  const { rows } = parseCsv(text);
  return rows.map((r) => ({
    name: r[0],
    mon: r[1],
    power: parseNumOrNull(r[2]),
    stamina: parseNumOrNull(r[3]),
    accuracy: parseNumOrNull(r[4]),
    priority: parseNumOrNull(r[5]) ?? 0,
    type: r[6],
    cls: r[7] as MoveClass,
    description: r[8],
    inputType: r[10] ?? 'none',
  }));
}

export function loadAbilities(): AbilityRow[] {
  const text = readFileSync(join(DROOL_DIR, 'abilities.csv'), 'utf8');
  const { rows } = parseCsv(text);
  return rows.map((r) => ({ name: r[0], mon: r[1], effect: r[2] }));
}

export function loadTypeChart(): TypeChart {
  const text = readFileSync(join(DROOL_DIR, 'types.csv'), 'utf8');
  const { rows } = parseCsv(text);
  const chart: TypeChart = {};
  for (const r of rows) {
    const [attacker, defender, mult] = r;
    if (!attacker || !defender) continue;
    const m = Number(mult);
    chart[attacker] ??= {};
    chart[attacker][defender] = m === 5 ? 0.5 : m;
  }
  return chart;
}

export interface Roster {
  mons: MonRow[];
  moves: MoveRow[];
  abilities: AbilityRow[];
  typeChart: TypeChart;
  movesByMon: Map<string, MoveRow[]>;
  abilityByMon: Map<string, AbilityRow | undefined>;
  monByName: Map<string, MonRow>;
}

export function loadRoster(): Roster {
  const mons = loadMons();
  const moves = loadMoves();
  const abilities = loadAbilities();
  const typeChart = loadTypeChart();
  const movesByMon = new Map<string, MoveRow[]>();
  for (const m of moves) {
    if (!movesByMon.has(m.mon)) movesByMon.set(m.mon, []);
    movesByMon.get(m.mon)!.push(m);
  }
  const abilityByMon = new Map<string, AbilityRow | undefined>();
  for (const a of abilities) abilityByMon.set(a.mon, a);
  const monByName = new Map(mons.map((m) => [m.name, m]));
  return { mons, moves, abilities, typeChart, movesByMon, abilityByMon, monByName };
}
