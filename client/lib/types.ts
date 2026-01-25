/**
 * Type definitions for Chomp battle system metadata
 * These types mirror the Solidity enums and structs
 */

// Mirrors src/Enums.sol
export enum MoveType {
  Yin = 0,
  Yang = 1,
  Earth = 2,
  Liquid = 3,
  Fire = 4,
  Metal = 5,
  Ice = 6,
  Nature = 7,
  Lightning = 8,
  Mythic = 9,
  Air = 10,
  Math = 11,
  Cyber = 12,
  Wild = 13,
  Cosmic = 14,
  None = 15,
}

export enum MoveClass {
  Physical = 0,
  Special = 1,
  Self = 2,
  Other = 3,
}

export enum ExtraDataType {
  None = 0,
  SelfTeamIndex = 1,
}

export enum MonStateIndexName {
  Hp = 0,
  Stamina = 1,
  Speed = 2,
  Attack = 3,
  Defense = 4,
  SpecialAttack = 5,
  SpecialDefense = 6,
  IsKnockedOut = 7,
  ShouldSkipTurn = 8,
  Type1 = 9,
  Type2 = 10,
}

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
  // Additional custom fields for non-StandardAttack moves
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
  moveType: MoveType;
  moveClass: MoveClass;
  critRate: number;
  volatility: number;
  effectAccuracy: number;
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
  types: [MoveType, MoveType];
  baseStats: {
    hp: number;
    attack: number;
    defense: number;
    specialAttack: number;
    specialDefense: number;
    speed: number;
  };
  moves: string[]; // Contract names
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
  type1: MoveType;
  type2: MoveType;
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
  /** RPC URL for on-chain interactions (optional for local simulation) */
  rpcUrl?: string;
  /** Chain ID (default: 1 for mainnet) */
  chainId?: number;
  /** Engine contract address (required for on-chain mode) */
  engineAddress?: `0x${string}`;
  /** Type calculator contract address */
  typeCalculatorAddress?: `0x${string}`;
  /** Enable local simulation mode (default: true) */
  localSimulation?: boolean;
}

/**
 * Default constant values from src/Constants.sol
 */
export const DEFAULT_CONSTANTS = {
  DEFAULT_PRIORITY: 3,
  DEFAULT_STAMINA: 5,
  DEFAULT_CRIT_RATE: 5,
  DEFAULT_VOL: 10,
  DEFAULT_ACCURACY: 100,
  SWITCH_PRIORITY: 6,
  CRIT_NUM: 3,
  CRIT_DENOM: 2,
  NO_OP_MOVE_INDEX: 126,
  SWITCH_MOVE_INDEX: 125,
} as const;
