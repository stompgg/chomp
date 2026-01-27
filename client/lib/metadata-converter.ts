/**
 * Metadata Converter
 *
 * Converts raw extracted move metadata to typed, resolved values.
 * Resolves constant references (e.g., "DEFAULT_PRIORITY" -> 3)
 */

import {
  RawMoveMetadata,
  MoveMetadata,
  MoveType,
  MoveClass,
  ExtraDataType,
  DEFAULT_CONSTANTS,
} from './types';

/**
 * Maps string type names to MoveType enum values
 */
const MOVE_TYPE_MAP: Record<string, MoveType> = {
  Yin: MoveType.Yin,
  Yang: MoveType.Yang,
  Earth: MoveType.Earth,
  Liquid: MoveType.Liquid,
  Fire: MoveType.Fire,
  Metal: MoveType.Metal,
  Ice: MoveType.Ice,
  Nature: MoveType.Nature,
  Lightning: MoveType.Lightning,
  Mythic: MoveType.Mythic,
  Air: MoveType.Air,
  Math: MoveType.Math,
  Cyber: MoveType.Cyber,
  Wild: MoveType.Wild,
  Cosmic: MoveType.Cosmic,
  None: MoveType.None,
};

/**
 * Maps string class names to MoveClass enum values
 */
const MOVE_CLASS_MAP: Record<string, MoveClass> = {
  Physical: MoveClass.Physical,
  Special: MoveClass.Special,
  Self: MoveClass.Self,
  Other: MoveClass.Other,
};

/**
 * Maps string extra data types to ExtraDataType enum values
 */
const EXTRA_DATA_TYPE_MAP: Record<string, ExtraDataType> = {
  None: ExtraDataType.None,
  SelfTeamIndex: ExtraDataType.SelfTeamIndex,
};

/**
 * Resolves a constant reference to its numeric value
 *
 * @param value - The value which may be a number, constant name, or "dynamic"
 * @param defaultValue - Default value if resolution fails
 * @returns Resolved numeric value
 */
export function resolveConstant(
  value: string | number | undefined,
  defaultValue: number = 0
): number {
  if (value === undefined || value === null) {
    return defaultValue;
  }

  // Already a number
  if (typeof value === 'number') {
    return value;
  }

  // Constant references (constants are bigint from transpiled output)
  switch (value) {
    case 'DEFAULT_PRIORITY':
      return Number(DEFAULT_CONSTANTS.DEFAULT_PRIORITY);
    case 'DEFAULT_STAMINA':
      return Number(DEFAULT_CONSTANTS.DEFAULT_STAMINA);
    case 'DEFAULT_CRIT_RATE':
      return Number(DEFAULT_CONSTANTS.DEFAULT_CRIT_RATE);
    case 'DEFAULT_VOL':
      return Number(DEFAULT_CONSTANTS.DEFAULT_VOL);
    case 'DEFAULT_ACCURACY':
      return Number(DEFAULT_CONSTANTS.DEFAULT_ACCURACY);
    case 'SWITCH_PRIORITY':
      return Number(DEFAULT_CONSTANTS.SWITCH_PRIORITY);
    case 'dynamic':
      // Dynamic values are calculated at runtime, return 0 as placeholder
      return 0;
    default:
      // Try to parse as number
      const parsed = parseInt(value, 10);
      return isNaN(parsed) ? defaultValue : parsed;
  }
}

/**
 * Resolves MoveType from string
 */
export function resolveMoveType(value: string): MoveType {
  return MOVE_TYPE_MAP[value] ?? MoveType.None;
}

/**
 * Resolves MoveClass from string
 */
export function resolveMoveClass(value: string): MoveClass {
  return MOVE_CLASS_MAP[value] ?? MoveClass.Other;
}

/**
 * Resolves ExtraDataType from string
 */
export function resolveExtraDataType(value: string): ExtraDataType {
  return EXTRA_DATA_TYPE_MAP[value] ?? ExtraDataType.None;
}

/**
 * Converts raw move metadata to typed, resolved metadata
 *
 * @param raw - Raw metadata from extraction script
 * @returns Fully typed and resolved MoveMetadata
 */
export function convertMoveMetadata(raw: RawMoveMetadata): MoveMetadata {
  const customConstants = raw.customConstants
    ? Object.fromEntries(
        Object.entries(raw.customConstants).map(([key, value]) => [
          key,
          typeof value === 'number' ? value : resolveConstant(value),
        ])
      )
    : undefined;

  return {
    contractName: raw.contractName,
    filePath: raw.filePath,
    inheritsFrom: raw.inheritsFrom,
    name: raw.name,
    basePower: resolveConstant(raw.basePower),
    staminaCost: resolveConstant(raw.staminaCost, Number(DEFAULT_CONSTANTS.DEFAULT_STAMINA)),
    accuracy: resolveConstant(raw.accuracy, Number(DEFAULT_CONSTANTS.DEFAULT_ACCURACY)),
    priority: resolveConstant(raw.priority, Number(DEFAULT_CONSTANTS.DEFAULT_PRIORITY)),
    moveType: resolveMoveType(raw.moveType),
    moveClass: resolveMoveClass(raw.moveClass),
    critRate: resolveConstant(raw.critRate, Number(DEFAULT_CONSTANTS.DEFAULT_CRIT_RATE)),
    volatility: resolveConstant(raw.volatility, Number(DEFAULT_CONSTANTS.DEFAULT_VOL)),
    effectAccuracy: resolveConstant(raw.effectAccuracy),
    effect: raw.effect,
    extraDataType: resolveExtraDataType(raw.extraDataType),
    ...(customConstants && { customConstants }),
    ...(raw.customBehavior && { customBehavior: raw.customBehavior }),
  };
}

/**
 * Converts an array of raw move metadata
 */
export function convertAllMoveMetadata(rawMoves: RawMoveMetadata[]): MoveMetadata[] {
  return rawMoves.map(convertMoveMetadata);
}

/**
 * Creates a lookup map of moves by contract name
 */
export function createMoveMap(moves: MoveMetadata[]): Map<string, MoveMetadata> {
  return new Map(moves.map(m => [m.contractName, m]));
}

/**
 * Loads and converts move metadata from JSON data
 *
 * @param jsonData - Parsed JSON data (from transpiler's dependency-manifest.json or other source)
 * @returns Converted metadata with moves indexed by name
 */
export function loadMoveMetadata(jsonData: {
  allMoves: RawMoveMetadata[];
  movesByMon: Record<string, RawMoveMetadata[]>;
}): {
  allMoves: MoveMetadata[];
  movesByMon: Record<string, MoveMetadata[]>;
  moveMap: Map<string, MoveMetadata>;
} {
  const allMoves = convertAllMoveMetadata(jsonData.allMoves);
  const movesByMon: Record<string, MoveMetadata[]> = {};

  for (const [mon, rawMoves] of Object.entries(jsonData.movesByMon)) {
    movesByMon[mon] = convertAllMoveMetadata(rawMoves);
  }

  return {
    allMoves,
    movesByMon,
    moveMap: createMoveMap(allMoves),
  };
}

/**
 * Gets move type effectiveness multiplier (basic version)
 * Full type chart would be loaded from TypeCalculator contract
 */
export function getTypeEffectiveness(
  attackType: MoveType,
  defenderType1: MoveType,
  defenderType2: MoveType
): number {
  // Placeholder - in production this would query the TypeCalculator
  // or use a precomputed type chart
  return 1.0;
}

/**
 * Checks if a move is dynamic (has runtime-calculated values)
 * A move is dynamic if it has basePower=0 (dynamic) OR staminaCost=0 (dynamic)
 * and directly implements IMoveSet (not StandardAttack)
 */
export function isDynamicMove(move: MoveMetadata): boolean {
  return (move.basePower === 0 || move.staminaCost === 0) && move.inheritsFrom === 'IMoveSet';
}

/**
 * Checks if a move has dynamic stamina cost
 */
export function hasDynamicStamina(move: MoveMetadata): boolean {
  return move.staminaCost === 0 && move.inheritsFrom === 'IMoveSet';
}

/**
 * Checks if a move has dynamic base power
 */
export function hasDynamicPower(move: MoveMetadata): boolean {
  return move.basePower === 0 && move.inheritsFrom === 'IMoveSet';
}

/**
 * Checks if a move has custom behavior beyond StandardAttack
 */
export function hasCustomBehavior(move: MoveMetadata): boolean {
  return !!move.customBehavior;
}

/**
 * Gets the behavior tags for a move
 */
export function getMoveBehaviors(move: MoveMetadata): string[] {
  if (!move.customBehavior) return [];
  return move.customBehavior.split(', ');
}

/**
 * Checks if a move requires extra data (targeting info)
 */
export function requiresExtraData(move: MoveMetadata): boolean {
  return move.extraDataType !== ExtraDataType.None;
}

/**
 * Formats move metadata for display
 */
export function formatMoveForDisplay(move: MoveMetadata): {
  name: string;
  type: string;
  class: string;
  power: string;
  accuracy: string;
  stamina: string;
  description: string;
} {
  const typeKey = Object.entries(MOVE_TYPE_MAP).find(([, v]) => v === move.moveType)?.[0] ?? 'None';
  const classKey = Object.entries(MOVE_CLASS_MAP).find(([, v]) => v === move.moveClass)?.[0] ?? 'Other';

  const powerDisplay = hasDynamicPower(move) ? 'Varies' : move.basePower.toString();
  const staminaDisplay = hasDynamicStamina(move) ? 'Varies' : move.staminaCost.toString();
  const accuracyDisplay = move.accuracy === 100 ? '100%' : `${move.accuracy}%`;

  let description = `${classKey} ${typeKey}-type move.`;
  if (move.customBehavior) {
    const behaviors = getMoveBehaviors(move);
    description += ` ${behaviors.map(b => b.replace('-', ' ')).join(', ')}.`;
  }

  return {
    name: move.name,
    type: typeKey,
    class: classKey,
    power: powerDisplay,
    accuracy: accuracyDisplay,
    stamina: staminaDisplay,
    description,
  };
}
