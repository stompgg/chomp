/**
 * Builds a chomp `Structs.Mon` from a mon id, self-contained for the arena.
 *
 * Reuses only the SAFE chomp util helpers (`moveNameToContract`, `findInlineMoveJson`, the container),
 * but does its OWN type mapping and inline packing so it handles every CSV type name including "Faith"
 * (both `mon-builder.ts`'s TYPE_BY_NAME and `inline-pack.ts`'s TYPE_MAP predate the Mythic->Faith enum
 * rename and would throw). `typeToEnum` reads the `Type` enum by name directly, so it survives renames.
 * `monCatalog` is shared with `mon-meta.ts` so the usage-table labels index the same catalog the draft
 * selects a battle loadout from.
 */
import { contracts as CONTRACT_REGISTRY } from '../../../transpiler/ts-output/factories';
import { Type } from '../../../transpiler/ts-output/Enums';
import { addressToUint } from '../../../transpiler/ts-output/runtime';
import { registerMoveInputType, registerMoveTargetSpec } from '../cpu/engine-view';
import * as Structs from '../../../transpiler/ts-output/Structs';
import type { SimContext } from '../harness';
import { moveNameToContract } from '../util/mon-builder';
import { findInlineMoveJson, type InlineMoveJson } from '../util/inline-pack';
import type { Roster, MonRow } from '../util/csv-load';

const DEFAULT_STAMINA = 5n;

const CLASS_MAP: Record<string, number> = { Physical: 0, Special: 1, Self: 2, Other: 3 };

function typeToEnum(name: string): number {
  if (name === 'NA' || name === '') return Type.None;
  const v = (Type as any)[name];
  if (v === undefined) throw new Error(`Unknown type "${name}"`);
  return v as number;
}

function isImplemented(contractName: string): boolean {
  return contractName in CONTRACT_REGISTRY;
}

type ResolvedSlot =
  | { kind: 'contract'; contractName: string; name: string; inputType: string; targetSpec: string }
  | { kind: 'inline'; json: InlineMoveJson; name: string };

/**
 * The mon's full implemented move catalog in learnset (CSV) order — every move with a contract or
 * inline JSON, uncapped and unpadded. Lanes [0,4) are the level-0 moves; a 5th lane, where present, is
 * the mon's level-6 unlock. Treating mons as max level means the whole catalog is selectable; the draft
 * then picks which lanes fill the 4 battle slots. Throws if the mon resolves to zero moves.
 */
export function monCatalog(roster: Roster, mon: MonRow): ResolvedSlot[] {
  const csvMoves = roster.movesByMon.get(mon.name) ?? [];
  const monDir = mon.name.toLowerCase();
  const slots: ResolvedSlot[] = [];
  for (const mv of csvMoves) {
    const contract = moveNameToContract(mv.name);
    if (isImplemented(contract)) {
      slots.push({ kind: 'contract', contractName: contract, name: mv.name, inputType: mv.inputType, targetSpec: mv.targetSpec });
      continue;
    }
    const inlineJson = findInlineMoveJson(monDir, contract);
    if (inlineJson) {
      slots.push({ kind: 'inline', json: inlineJson, name: mv.name });
      continue;
    }
    // Unimplemented move — skip (mirrors buildMonConfig).
  }
  if (slots.length === 0) throw new Error(`mon ${mon.name} has no resolvable moves`);
  return slots;
}

/** A mon drafted into a team slot: its id plus the catalog lanes it fields this draft (`equip`). */
export interface DraftedMon {
  id: number;
  equip: number[];
}

/**
 * Which catalog lanes fill a max-level mon's 4 battle slots. A mon with <=4 catalog moves fields all of
 * them (no draw). A larger catalog — the level-6-unlock mons — drops one random lane per draft, so over a
 * run every catalog move (including the level-6 move) gets played. Drops preserve ascending order, so
 * slot 0 stays the mon's first move. The `rand` here MUST be a stream separate from the team-draw rng —
 * that one is byte-locked to munch's for cross-repo team parity.
 */
export function draftMoveSelection(catalogLen: number, rand: () => number): number[] {
  const pool = Array.from({ length: catalogLen }, (_, i) => i);
  while (pool.length > 4) pool.splice(Math.floor(rand() * pool.length), 1);
  return pool;
}

// Inline-move packing — mirrors sims/src/util/inline-pack.ts:packMove but with a type-robust map.
// Layout: [basePower:8 | moveClass:2 | priority:2 | moveType:4 | stamina:4 | effectAccuracy:8 | ... | effect:160]
function packInlineMove(m: InlineMoveJson, effectAddress: bigint): bigint {
  const movClass = CLASS_MAP[m.moveClass as string];
  const movType = typeToEnum(m.moveType as string);
  const priority = m.priority ?? 0;
  if (movClass === undefined) throw new Error(`Unknown moveClass "${m.moveClass}"`);
  let packed = BigInt(m.basePower) << 248n;
  packed |= BigInt(movClass) << 246n;
  packed |= BigInt(priority) << 244n;
  packed |= BigInt(movType) << 240n;
  packed |= BigInt(m.staminaCost) << 236n;
  packed |= BigInt(m.effectAccuracy) << 228n;
  packed |= effectAddress;
  return packed;
}

function resolveContractAddress(ctx: SimContext, name: string): bigint {
  const c = ctx.container.resolve<any>(name);
  return addressToUint(c._contractAddress);
}

export function buildTeamMon(ctx: SimContext, roster: Roster, monId: number, equip?: number[]): Structs.Mon {
  const mon = roster.mons.find((m) => m.id === monId);
  if (!mon) throw new Error(`no mon with id ${monId}`);
  const catalog = monCatalog(roster, mon);
  // Default loadout = the first up-to-4 catalog lanes (the level-0 moves); callers pass `equip` to field
  // a specific max-level 4-of-N selection. Engine fields exactly 4 lanes, so pad a short loadout by
  // repeating the last (duplicate lanes are inert).
  const lanes = equip ?? Array.from({ length: Math.min(4, catalog.length) }, (_, i) => i);
  const slots = lanes.map((i) => catalog[i]);
  while (slots.length < 4) slots.push(slots[slots.length - 1]);

  const moves = slots.map((s) => {
    if (s.kind === 'contract') {
      const addr = resolveContractAddress(ctx, s.contractName);
      // Address → InputType / TargetSpec registries (the off-chain replacement for the removed
      // on-chain ExtraDataType) — CPU enumeration consults them for payload/slot targeting.
      registerMoveInputType(addr, s.inputType);
      registerMoveTargetSpec(addr, s.targetSpec);
      return addr;
    }
    const effectAddr = s.json.effect ? resolveContractAddress(ctx, s.json.effect) : 0n;
    return packInlineMove(s.json, effectAddr);
  });

  const ability = roster.abilityByMon.get(mon.name);
  const abilityContract = ability ? moveNameToContract(ability.name) : null;
  const abilitySlot = abilityContract && isImplemented(abilityContract)
    ? resolveContractAddress(ctx, abilityContract)
    : 0n;

  return {
    stats: {
      hp: BigInt(mon.hp),
      stamina: DEFAULT_STAMINA,
      speed: BigInt(mon.speed),
      attack: BigInt(mon.attack),
      defense: BigInt(mon.defense),
      specialAttack: BigInt(mon.specialAttack),
      specialDefense: BigInt(mon.specialDefense),
      type1: typeToEnum(mon.type1),
      type2: typeToEnum(mon.type2),
    },
    moves,
    ability: abilitySlot,
  };
}
