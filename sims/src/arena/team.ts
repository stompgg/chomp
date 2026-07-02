/**
 * Builds a chomp `Structs.Mon` from a mon id, self-contained for the arena.
 *
 * Reuses only the SAFE chomp util helpers (`moveNameToContract`, `findInlineMoveJson`, the container),
 * but does its OWN type mapping and inline packing so it handles every CSV type name including "Faith"
 * (both `mon-builder.ts`'s TYPE_BY_NAME and `inline-pack.ts`'s TYPE_MAP predate the Mythic->Faith enum
 * rename and would throw). `typeToEnum` reads the `Type` enum by name directly, so it survives renames.
 * `monMoveSlots` is shared with `mon-meta.ts` so the usage-table labels line up with the engine's slots.
 */
import { contracts as CONTRACT_REGISTRY } from '../../../transpiler/ts-output/factories';
import { Type } from '../../../transpiler/ts-output/Enums';
import { addressToUint } from '../../../transpiler/ts-output/runtime';
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
  | { kind: 'contract'; contractName: string; name: string }
  | { kind: 'inline'; json: InlineMoveJson; name: string };

/**
 * The mon's 4 move slots — implemented moves in CSV order, capped at 4 and padded by repeating the last
 * (the engine validator wants exactly 4 slots; padded duplicates are inert). Shared with mon-meta so the
 * usage labels index the same slots the engine stores.
 */
export function monMoveSlots(roster: Roster, mon: MonRow): ResolvedSlot[] {
  const csvMoves = roster.movesByMon.get(mon.name) ?? [];
  const monDir = mon.name.toLowerCase();
  const slots: ResolvedSlot[] = [];
  for (const mv of csvMoves) {
    const contract = moveNameToContract(mv.name);
    if (isImplemented(contract)) {
      slots.push({ kind: 'contract', contractName: contract, name: mv.name });
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
  const four = slots.slice(0, 4);
  while (four.length < 4) four.push(four[four.length - 1]);
  return four;
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

export function buildTeamMon(ctx: SimContext, roster: Roster, monId: number): Structs.Mon {
  const mon = roster.mons.find((m) => m.id === monId);
  if (!mon) throw new Error(`no mon with id ${monId}`);
  const slots = monMoveSlots(roster, mon);

  const moves = slots.map((s) => {
    if (s.kind === 'contract') return resolveContractAddress(ctx, s.contractName);
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
