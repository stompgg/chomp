import { contracts as CONTRACT_REGISTRY } from '../../../transpiler/ts-output/factories';
import { Type } from '../../../transpiler/ts-output/Enums';
import type { MonRow, MoveRow, Roster } from './csv-load';
import type { HarnessMonConfig, MoveSlotSource } from '../harness';
import { findInlineMoveJson, type InlineMoveJson } from './inline-pack';

const TYPE_BY_NAME: Record<string, number> = {
  Yin: Type.Yin,
  Yang: Type.Yang,
  Earth: Type.Earth,
  Liquid: Type.Liquid,
  Fire: Type.Fire,
  Metal: Type.Metal,
  Ice: Type.Ice,
  Nature: Type.Nature,
  Lightning: Type.Lightning,
  Mythic: Type.Mythic,
  Air: Type.Air,
  Math: Type.Math,
  Cyber: Type.Cyber,
  Wild: Type.Wild,
  Cosmic: Type.Cosmic,
  None: Type.None,
  NA: Type.None,
};

export function typeNameToEnum(s: string): number {
  const t = TYPE_BY_NAME[s];
  if (t === undefined) throw new Error(`Unknown type "${s}"`);
  return t;
}

export function moveNameToContract(name: string): string {
  return name
    .split(/[\s\-]+/)
    .filter(Boolean)
    .map((w) => w[0].toUpperCase() + w.slice(1))
    .join('');
}

function isImplemented(contractName: string): boolean {
  return contractName in CONTRACT_REGISTRY;
}

export interface ResolvedMove {
  move: MoveRow;
  index: number;
  source: MoveSlotSource;
}

export interface BuildResult {
  config: HarnessMonConfig | null;
  resolvedMoves: ResolvedMove[];
  missingMoves: string[];
  missingAbility: string | null;
}

export function buildMonConfig(roster: Roster, mon: MonRow, defaultStamina = 5n): BuildResult {
  const csvMoves = roster.movesByMon.get(mon.name) ?? [];
  const monDir = mon.name.toLowerCase();
  const resolvedMoves: ResolvedMove[] = [];
  const missingMoves: string[] = [];
  for (const move of csvMoves) {
    const contract = moveNameToContract(move.name);
    if (isImplemented(contract)) {
      resolvedMoves.push({ move, index: resolvedMoves.length, source: { kind: 'contract', contractName: contract } });
      continue;
    }
    const inlineJson = findInlineMoveJson(monDir, contract);
    if (inlineJson) {
      resolvedMoves.push({ move, index: resolvedMoves.length, source: { kind: 'inline', json: inlineJson } });
      continue;
    }
    missingMoves.push(move.name);
  }
  const ability = roster.abilityByMon.get(mon.name);
  const abilityContract = ability ? moveNameToContract(ability.name) : null;
  const abilityOk = abilityContract === null || isImplemented(abilityContract);
  if (resolvedMoves.length === 0 || !abilityOk) {
    return {
      config: null,
      resolvedMoves,
      missingMoves,
      missingAbility: abilityOk ? null : abilityContract,
    };
  }
  const moveSources: MoveSlotSource[] = resolvedMoves.slice(0, 4).map((rm) => rm.source);
  // Engine validator requires exactly MOVES_PER_MON (4) move slots. Pad short
  // rosters by repeating the last implemented move; sims callers reference
  // moves by the original (pre-pad) index, so duplicates are inert.
  while (moveSources.length < 4) moveSources.push(moveSources[moveSources.length - 1]);
  return {
    config: {
      stats: {
        hp: BigInt(mon.hp),
        stamina: defaultStamina,
        speed: BigInt(mon.speed),
        attack: BigInt(mon.attack),
        defense: BigInt(mon.defense),
        specialAttack: BigInt(mon.specialAttack),
        specialDefense: BigInt(mon.specialDefense),
      },
      type1: typeNameToEnum(mon.type1),
      type2: typeNameToEnum(mon.type2),
      moves: moveSources,
      ability: abilityContract,
    },
    resolvedMoves,
    missingMoves,
    missingAbility: null,
  };
}

export function findDamagingMove(moves: MoveRow[]): { move: MoveRow; index: number } | null {
  for (let i = 0; i < moves.length; i++) {
    const m = moves[i];
    if (m.power !== null && m.power > 0 && (m.cls === 'Physical' || m.cls === 'Special')) {
      return { move: m, index: i };
    }
  }
  return null;
}
