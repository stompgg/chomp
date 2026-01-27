/**
 * Type definitions for Chomp battle system
 *
 * Enums and constants are imported directly from the transpiled Solidity output.
 * Client-specific types (BattleState, MoveMetadata, etc.) are defined here.
 */

// =============================================================================
// IMPORTS FROM TRANSPILED SOLIDITY
// =============================================================================

// Import enums from transpiled Enums.ts (source: src/Enums.sol)
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

// Import constants from transpiled Constants.ts (source: src/Constants.sol)
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
// RE-EXPORTS WITH ALIASES
// =============================================================================

// Re-export Type as MoveType for backwards compatibility
// (Solidity uses "Type" but "MoveType" is clearer in client context)
export { Type as MoveType };

// Re-export other enums directly
export {
  MoveClass,
  ExtraDataType,
  MonStateIndexName,
  GameStatus,
  EffectStep,
  EffectRunCondition,
  StatBoostType,
  StatBoostFlag,
};

// =============================================================================
// CONSTANTS (re-exported with client-friendly format)
// =============================================================================

/**
 * Game constants from src/Constants.sol
 * Values are bigint to match transpiled output.
 */
export const DEFAULT_CONSTANTS = {
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

// =============================================================================
// CLIENT-SPECIFIC TYPES
// =============================================================================

/**
 * Raw move metadata as extracted from Solidity files
 * Values are strings that may need parsing (e.g., "DEFAULT_PRIORITY")
 */
export interface RawMoveMetadata {
  contractName: string;
  filePath: string;
  inheritsFrom: string;
  name: string;
  basePower: string | number;
  staminaCost: string | number;
  accuracy: string | number;
  priority: string | number;
  moveType: string;
  moveClass: string;
  critRate: string | number;
  volatility: string | number;
  effectAccuracy: string | number;
  effect: string | null;
  extraDataType: string;
  customConstants?: Record<string, string | number>;
  customBehavior?: string;
}

/**
 * Parsed move metadata with resolved values
 * Ready for use in the Angular service
 */
export interface MoveMetadata {
  contractName: string;
  filePath: string;
  inheritsFrom: string;
  name: string;
  basePower: number;
  staminaCost: number;
  accuracy: number;
  priority: number;
  moveType: Type;
  moveClass: MoveClass;
  critRate: number;
  effectAccuracy: number;
  volatility: number;
  effect: string | null;
  extraDataType: ExtraDataType;
  customConstants?: Record<string, number>;
  customBehavior?: string;
}

/**
 * Mon (monster) definition
 */
export interface MonDefinition {
  name: string;
  types: [Type, Type];
  baseStats: {
    hp: number;
    attack: number;
    defense: number;
    specialAttack: number;
    specialDefense: number;
    speed: number;
  };
  moves: string[];
  ability?: string;
}

/**
 * Battle state for a single mon
 */
export interface MonBattleState {
  hp: bigint;
  stamina: bigint;
  speed: bigint;
  attack: bigint;
  defense: bigint;
  specialAttack: bigint;
  specialDefense: bigint;
  isKnockedOut: boolean;
  shouldSkipTurn: boolean;
  type1: Type;
  type2: Type;
}

/**
 * Player's team state
 */
export interface TeamState {
  mons: MonBattleState[];
  activeMonIndex: number;
}

/**
 * Full battle state
 */
export interface BattleState {
  battleKey: string;
  players: [TeamState, TeamState];
  turn: number;
  isGameOver: boolean;
  winner?: 0 | 1;
}

/**
 * Move action for battle execution
 */
export interface MoveAction {
  playerIndex: 0 | 1;
  moveIndex: number;
  extraData?: bigint;
}

/**
 * Switch action for battle execution
 */
export interface SwitchAction {
  playerIndex: 0 | 1;
  targetMonIndex: number;
}

export type BattleAction = MoveAction | SwitchAction;

/**
 * Battle event emitted during execution
 */
export interface BattleEvent {
  type: string;
  data: Record<string, unknown>;
  turn: number;
  timestamp: number;
}

/**
 * Configuration for the battle service
 */
export interface BattleServiceConfig {
  rpcUrl?: string;
  chainId?: number;
  engineAddress?: `0x${string}`;
  typeCalculatorAddress?: `0x${string}`;
  localSimulation?: boolean;
}
