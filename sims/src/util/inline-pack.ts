/**
 * Port of chomp/processing/packMoves.py — pack a JSON move definition into the
 * uint256 slot value the Engine consumes when `(rawMoveSlot >> 160) != 0`.
 *
 * Layout (256 bits): [basePower:8 | moveClass:2 | priority:2 | moveType:4 |
 *   stamina:4 | effectAccuracy:8 | unused:68 | effect:160]
 *
 * Inline moves always run with DEFAULT_ACCURACY=100, DEFAULT_VOL=10 in the
 * engine — fields not in this format aren't customizable per-move.
 */

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { Type } from '../../../transpiler/ts-output/Enums';

const SRC_MONS_DIR = join(import.meta.dir, '..', '..', '..', 'src', 'mons');

// Current 15-type chart (Mythic→Faith rename; Wild removed) — names must match Enums.Type.
const TYPE_MAP: Record<string, number> = {
  Yin: Type.Yin, Yang: Type.Yang, Earth: Type.Earth, Liquid: Type.Liquid,
  Fire: Type.Fire, Metal: Type.Metal, Ice: Type.Ice, Nature: Type.Nature,
  Lightning: Type.Lightning, Faith: Type.Faith, Air: Type.Air, Math: Type.Math,
  Cyber: Type.Cyber, Cosmic: Type.Cosmic, None: Type.None,
};

const CLASS_MAP: Record<string, number> = {
  Physical: 0, Special: 1, Self: 2, Other: 3,
};

export interface InlineMoveJson {
  name: string;
  basePower: number;
  staminaCost: number;
  moveType: keyof typeof TYPE_MAP;
  moveClass: keyof typeof CLASS_MAP;
  effectAccuracy: number;
  effect: string | null;
  priority?: number;
}

export function packMove(m: InlineMoveJson, effectAddress: bigint = 0n): bigint {
  const movClass = CLASS_MAP[m.moveClass];
  const movType = TYPE_MAP[m.moveType];
  const priority = m.priority ?? 0;
  if (movClass === undefined) throw new Error(`Unknown moveClass "${m.moveClass}"`);
  if (movType === undefined) throw new Error(`Unknown moveType "${m.moveType}"`);
  if (m.basePower < 0 || m.basePower > 255) throw new Error(`basePower ${m.basePower} out of [0,255]`);
  if (priority < 0 || priority > 3) throw new Error(`priority ${priority} out of [0,3]`);
  if (m.staminaCost < 0 || m.staminaCost > 15) throw new Error(`staminaCost ${m.staminaCost} out of [0,15]`);
  if (m.effectAccuracy < 0 || m.effectAccuracy > 255) throw new Error(`effectAccuracy ${m.effectAccuracy} out of [0,255]`);
  if (effectAddress < 0n || effectAddress >= (1n << 160n)) throw new Error('effect address out of range');

  let packed = BigInt(m.basePower) << 248n;
  packed |= BigInt(movClass) << 246n;
  packed |= BigInt(priority) << 244n;
  packed |= BigInt(movType) << 240n;
  packed |= BigInt(m.staminaCost) << 236n;
  packed |= BigInt(m.effectAccuracy) << 228n;
  packed |= effectAddress;
  return packed;
}

export function findInlineMoveJson(monDir: string, contractName: string): InlineMoveJson | null {
  const path = join(SRC_MONS_DIR, monDir, `${contractName}.json`);
  if (!existsSync(path)) return null;
  return JSON.parse(readFileSync(path, 'utf8')) as InlineMoveJson;
}

export function listInlineMovesByMon(): Map<string, Map<string, InlineMoveJson>> {
  const out = new Map<string, Map<string, InlineMoveJson>>();
  if (!existsSync(SRC_MONS_DIR)) return out;
  for (const monDir of readdirSync(SRC_MONS_DIR)) {
    const dirPath = join(SRC_MONS_DIR, monDir);
    let entries: string[];
    try {
      entries = readdirSync(dirPath);
    } catch {
      continue;
    }
    for (const f of entries) {
      if (!f.endsWith('.json')) continue;
      const json = JSON.parse(readFileSync(join(dirPath, f), 'utf8')) as InlineMoveJson;
      const name = f.slice(0, -5);
      if (!out.has(monDir)) out.set(monDir, new Map());
      out.get(monDir)!.set(name, json);
    }
  }
  return out;
}
