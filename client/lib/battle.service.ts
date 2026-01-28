/**
 * Angular Battle Service
 *
 * Thin wrapper around BattleHarness for running local battle simulations.
 * Supports multiple concurrent battles through a single harness instance.
 *
 * Usage:
 *   @Component({ ... })
 *   export class BattleComponent {
 *     private battleService = inject(BattleService);
 *
 *     async runSimulation() {
 *       await this.battleService.initialize();
 *       const battleKey = await this.battleService.createBattle(p0, p1, p0Team, p1Team);
 *       this.battleService.executeTurn(battleKey, p0Move, p1Move);
 *       const state = this.battleService.getBattleState(battleKey);
 *     }
 *   }
 */

import { Injectable } from '@angular/core';

import {
  BattleHarness,
  createBattleHarness,
  type MonConfig,
  type TeamConfig,
  type BattleConfig,
  type TurnInput,
  type MoveDecision,
  type BattleState,
  type MonState,
  type AddressConfig,
} from '../../transpiler/runtime/battle-harness';

// =============================================================================
// RE-EXPORT HARNESS TYPES
// =============================================================================

export type {
  MonConfig,
  TeamConfig,
  BattleConfig,
  TurnInput,
  MoveDecision,
  BattleState,
  MonState,
  AddressConfig,
};

// =============================================================================
// MOVE INPUT TYPE
// =============================================================================

/**
 * Input for a single player's move in a turn
 */
export interface MoveInput {
  moveIndex: number;
  salt: string;
  extraData?: bigint;
}

// =============================================================================
// BATTLE SERVICE
// =============================================================================

@Injectable({
  providedIn: 'root',
})
export class BattleService {
  private harness: BattleHarness | null = null;

  /**
   * Initialize the battle harness.
   * Must be called before creating battles.
   */
  async initialize(): Promise<void> {
    if (this.harness) {
      return; // Already initialized
    }

    this.harness = await createBattleHarness(
      (name: string) => import(`../../transpiler/ts-output/${name}`)
    );
  }

  /**
   * Create a new battle with two teams.
   * Returns the unique battleKey for this battle.
   *
   * Multiple battles can be created and run concurrently through the same
   * harness - the Engine guarantees state isolation via battleKey.
   *
   * @param addresses Optional mapping of contract names to addresses for resolution
   */
  async createBattle(
    p0Address: string,
    p1Address: string,
    p0Team: MonConfig[],
    p1Team: MonConfig[],
    addresses: AddressConfig
  ): Promise<string> {
    if (!this.harness) {
      await this.initialize();
    }

    const battleConfig: BattleConfig = {
      player0: p0Address,
      player1: p1Address,
      teams: [{ mons: p0Team }, { mons: p1Team }],
      addresses,
    };

    return this.harness!.startBattle(battleConfig);
  }

  /**
   * Execute a turn for a battle.
   * Both players' moves are submitted and the turn is executed.
   */
  executeTurn(
    battleKey: string,
    p0Move: MoveInput,
    p1Move: MoveInput
  ): void {
    if (!this.harness) {
      throw new Error('BattleService not initialized. Call initialize() first.');
    }

    const turnInput: TurnInput = {
      player0: {
        moveIndex: p0Move.moveIndex,
        salt: p0Move.salt,
        extraData: p0Move.extraData,
      },
      player1: {
        moveIndex: p1Move.moveIndex,
        salt: p1Move.salt,
        extraData: p1Move.extraData,
      },
    };

    this.harness.executeTurn(battleKey, turnInput);
  }

  /**
   * Get the current state for a battle.
   * Returns the harness BattleState directly (with stat deltas, not absolute values).
   */
  getBattleState(battleKey: string): BattleState {
    if (!this.harness) {
      throw new Error('BattleService not initialized. Call initialize() first.');
    }

    return this.harness.getBattleState(battleKey);
  }

  /**
   * Get access to the underlying harness for advanced usage.
   */
  getHarness(): BattleHarness | null {
    return this.harness;
  }

  // TODO: hydrateBattle(battleKey: string, state: HydrationState): void
  // For initializing mid-battle state from on-chain data
}
