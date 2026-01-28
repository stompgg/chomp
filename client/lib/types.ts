/**
 * Type definitions for Chomp battle system
 *
 * Re-exports enums and constants from the transpiled Solidity output.
 */

// =============================================================================
// IMPORTS FROM TRANSPILED SOLIDITY
// =============================================================================

import {
  Type,
  MoveClass,
  ExtraDataType,
  MonStateIndexName,
  GameStatus,
  EffectStep,
  EffectRunCondition,
  StatBoostType,
  StatBoostFlag,
} from '../../transpiler/ts-output/Enums';

import {
  NO_OP_MOVE_INDEX,
  SWITCH_MOVE_INDEX,
  SWITCH_PRIORITY,
  DEFAULT_PRIORITY,
  DEFAULT_STAMINA,
  DEFAULT_CRIT_RATE,
  DEFAULT_VOL,
  DEFAULT_ACCURACY,
  CRIT_NUM,
  CRIT_DENOM,
} from '../../transpiler/ts-output/Constants';

// =============================================================================
// RE-EXPORTS
// =============================================================================

export { Type as MoveType };

export {
  Type,
  MoveClass,
  ExtraDataType,
  MonStateIndexName,
  GameStatus,
  EffectStep,
  EffectRunCondition,
  StatBoostType,
  StatBoostFlag,
};

export const CONSTANTS = {
  DEFAULT_PRIORITY,
  DEFAULT_STAMINA,
  DEFAULT_CRIT_RATE,
  DEFAULT_VOL,
  DEFAULT_ACCURACY,
  SWITCH_PRIORITY,
  CRIT_NUM,
  CRIT_DENOM,
  NO_OP_MOVE_INDEX,
  SWITCH_MOVE_INDEX,
} as const;
