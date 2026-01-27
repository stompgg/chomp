/**
 * Chomp Client - Angular Battle Service
 *
 * Provides battle simulation and on-chain interaction for the Chomp battle system.
 *
 * Features:
 * - Move metadata extraction and conversion
 * - Local TypeScript battle simulation
 * - On-chain interaction via viem
 * - Angular 20+ signal-based reactive state
 *
 * Usage:
 *   import { BattleService, MoveMetadata, MoveType } from '@chomp/client';
 *
 *   @Component({ ... })
 *   export class BattleComponent {
 *     private battleService = inject(BattleService);
 *   }
 */

// Types
export {
  MoveType,
  MoveClass,
  ExtraDataType,
  MonStateIndexName,
  RawMoveMetadata,
  MoveMetadata,
  MonDefinition,
  MonBattleState,
  TeamState,
  BattleState,
  MoveAction,
  SwitchAction,
  BattleAction,
  BattleEvent,
  BattleServiceConfig,
  DEFAULT_CONSTANTS,
} from './lib/types';

// Metadata Conversion
export {
  resolveConstant,
  resolveMoveType,
  resolveMoveClass,
  resolveExtraDataType,
  convertMoveMetadata,
  convertAllMoveMetadata,
  createMoveMap,
  loadMoveMetadata,
  getTypeEffectiveness,
  isDynamicMove,
  hasCustomBehavior,
  getMoveBehaviors,
  requiresExtraData,
  formatMoveForDisplay,
} from './lib/metadata-converter';

// Angular Service
export { BattleService } from './lib/battle.service';
