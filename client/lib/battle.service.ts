/**
 * Angular Battle Service
 *
 * Provides battle simulation and on-chain interaction for the Chomp battle system.
 * Supports both local TypeScript simulation and on-chain viem interactions.
 *
 * This service composes the BattleHarness internally for local simulation,
 * providing Angular-specific reactivity via signals while delegating
 * battle logic to the transpiled Engine.
 *
 * Requirements: Angular 20+, viem
 *
 * Usage:
 *   @Component({ ... })
 *   export class BattleComponent {
 *     private battleService = inject(BattleService);
 *
 *     async startBattle() {
 *       await this.battleService.initializeBattle(p0Team, p1Team);
 *       const state = this.battleService.battleState();
 *     }
 *   }
 */

import {
  Injectable,
  Signal,
  WritableSignal,
  signal,
  computed,
  inject,
  PLATFORM_ID,
} from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import {
  createPublicClient,
  http,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Address,
  type Hash,
  keccak256,
  encodeAbiParameters,
  toHex,
} from 'viem';
import { mainnet } from 'viem/chains';

import {
  MoveMetadata,
  MoveType,
  BattleState,
  TeamState,
  MonBattleState,
  BattleEvent,
  BattleServiceConfig,
} from './types';
import { loadMoveMetadata } from './metadata-converter';

// Import harness types and factory
import {
  BattleHarness,
  createBattleHarness,
  type MonConfig,
  type TeamConfig,
  type BattleConfig as HarnessBattleConfig,
  type TurnInput,
  type BattleState as HarnessBattleState,
  type MonState as HarnessMonState,
} from '../../transpiler/runtime/battle-harness';

// =============================================================================
// RE-EXPORT HARNESS TYPES FOR CONVENIENCE
// =============================================================================

export type { MonConfig, TeamConfig };

// =============================================================================
// BATTLE SERVICE
// =============================================================================

@Injectable({
  providedIn: 'root',
})
export class BattleService {
  private readonly platformId = inject(PLATFORM_ID);

  // -------------------------------------------------------------------------
  // Configuration
  // -------------------------------------------------------------------------

  private _config: WritableSignal<BattleServiceConfig> = signal({
    localSimulation: true,
  });

  readonly config: Signal<BattleServiceConfig> = this._config.asReadonly();

  // -------------------------------------------------------------------------
  // Viem Clients (lazy initialized)
  // -------------------------------------------------------------------------

  private _publicClient: PublicClient | null = null;
  private _walletClient: WalletClient | null = null;

  // -------------------------------------------------------------------------
  // Move Metadata
  // -------------------------------------------------------------------------

  private _moveMetadata: WritableSignal<Map<string, MoveMetadata>> = signal(
    new Map()
  );
  private _movesByMon: WritableSignal<Record<string, MoveMetadata[]>> = signal(
    {}
  );
  private _isMetadataLoaded: WritableSignal<boolean> = signal(false);

  readonly moveMetadata: Signal<Map<string, MoveMetadata>> =
    this._moveMetadata.asReadonly();
  readonly movesByMon: Signal<Record<string, MoveMetadata[]>> =
    this._movesByMon.asReadonly();
  readonly isMetadataLoaded: Signal<boolean> =
    this._isMetadataLoaded.asReadonly();

  // -------------------------------------------------------------------------
  // Battle State
  // -------------------------------------------------------------------------

  private _battleKey: WritableSignal<string | null> = signal(null);
  private _battleState: WritableSignal<BattleState | null> = signal(null);
  private _battleEvents: WritableSignal<BattleEvent[]> = signal([]);
  private _isExecuting: WritableSignal<boolean> = signal(false);
  private _error: WritableSignal<string | null> = signal(null);

  readonly battleKey: Signal<string | null> = this._battleKey.asReadonly();
  readonly battleState: Signal<BattleState | null> =
    this._battleState.asReadonly();
  readonly battleEvents: Signal<BattleEvent[]> = this._battleEvents.asReadonly();
  readonly isExecuting: Signal<boolean> = this._isExecuting.asReadonly();
  readonly error: Signal<string | null> = this._error.asReadonly();

  // -------------------------------------------------------------------------
  // Derived State
  // -------------------------------------------------------------------------

  readonly isGameOver: Signal<boolean> = computed(
    () => this._battleState()?.isGameOver ?? false
  );

  readonly winner: Signal<0 | 1 | null> = computed(() => {
    const state = this._battleState();
    return state?.isGameOver ? state.winner ?? null : null;
  });

  readonly currentTurn: Signal<number> = computed(
    () => this._battleState()?.turn ?? 0
  );

  readonly player0Team: Signal<TeamState | null> = computed(
    () => this._battleState()?.players[0] ?? null
  );

  readonly player1Team: Signal<TeamState | null> = computed(
    () => this._battleState()?.players[1] ?? null
  );

  // -------------------------------------------------------------------------
  // Battle Harness (for local simulation)
  // -------------------------------------------------------------------------

  private harness: BattleHarness | null = null;

  // -------------------------------------------------------------------------
  // Configuration Methods
  // -------------------------------------------------------------------------

  /**
   * Configure the battle service
   */
  configure(config: Partial<BattleServiceConfig>): void {
    this._config.update((current) => ({ ...current, ...config }));

    // Initialize viem clients if RPC URL provided
    if (config.rpcUrl && !config.localSimulation) {
      this.initializeViemClients(config.rpcUrl, config.chainId);
    }
  }

  /**
   * Initialize viem clients for on-chain interactions
   */
  private initializeViemClients(rpcUrl: string, chainId: number = 1): void {
    if (!isPlatformBrowser(this.platformId)) return;

    const chain: Chain = chainId === 1 ? mainnet : mainnet; // Extend for other chains

    this._publicClient = createPublicClient({
      chain,
      transport: http(rpcUrl),
    });
  }

  // -------------------------------------------------------------------------
  // Metadata Loading
  // -------------------------------------------------------------------------

  /**
   * Load move metadata from JSON data
   */
  loadMetadata(jsonData: {
    allMoves: any[];
    movesByMon: Record<string, any[]>;
  }): void {
    const { allMoves, movesByMon, moveMap } = loadMoveMetadata(jsonData);
    this._moveMetadata.set(moveMap);
    this._movesByMon.set(movesByMon);
    this._isMetadataLoaded.set(true);
  }

  /**
   * Load move metadata from URL (for lazy loading)
   */
  async loadMetadataFromUrl(url: string): Promise<void> {
    try {
      const response = await fetch(url);
      const jsonData = await response.json();
      this.loadMetadata(jsonData);
    } catch (err) {
      this._error.set(`Failed to load metadata: ${(err as Error).message}`);
      throw err;
    }
  }

  /**
   * Get metadata for a specific move
   */
  getMoveMetadata(contractName: string): MoveMetadata | undefined {
    return this._moveMetadata().get(contractName);
  }

  /**
   * Get all moves for a specific mon
   */
  getMovesForMon(monName: string): MoveMetadata[] {
    return this._movesByMon()[monName.toLowerCase()] ?? [];
  }

  // -------------------------------------------------------------------------
  // Local Simulation Methods (using BattleHarness)
  // -------------------------------------------------------------------------

  /**
   * Initialize the local TypeScript simulation engine.
   * Creates a BattleHarness that handles module loading with caching
   * and dependency injection via ContractContainer.
   */
  async initializeLocalEngine(): Promise<void> {
    if (!this._config().localSimulation) {
      throw new Error('Local simulation is disabled');
    }

    try {
      // Create harness with module loader that uses cached dynamic imports
      this.harness = await createBattleHarness(
        (name: string) => import(`../../transpiler/ts-output/${name}`)
      );
    } catch (err) {
      this._error.set(`Failed to initialize local engine: ${(err as Error).message}`);
      throw err;
    }
  }

  /**
   * Initialize a local battle with two teams.
   * Uses the harness's MonConfig format with individual stat fields.
   */
  async initializeLocalBattle(
    p0Address: string,
    p1Address: string,
    p0Team: MonConfig[],
    p1Team: MonConfig[]
  ): Promise<string> {
    if (!this.harness) {
      await this.initializeLocalEngine();
    }

    const battleConfig: HarnessBattleConfig = {
      player0: p0Address,
      player1: p1Address,
      teams: [
        { mons: p0Team },
        { mons: p1Team },
      ],
    };

    const battleKey = await this.harness!.startBattle(battleConfig);

    this._battleKey.set(battleKey);
    this._battleEvents.set([]);

    // Create initial battle state from harness
    this.updateBattleStateFromHarness(battleKey);

    return battleKey;
  }

  /**
   * Execute a turn in the local simulation.
   * Delegates to the BattleHarness which uses Engine's public API.
   */
  async executeLocalTurn(
    p0MoveIndex: number,
    p0ExtraData: bigint = 0n,
    p0Salt: string,
    p1MoveIndex: number,
    p1ExtraData: bigint = 0n,
    p1Salt: string
  ): Promise<void> {
    const battleKey = this._battleKey();
    if (!battleKey || !this.harness) {
      throw new Error('No active battle');
    }

    this._isExecuting.set(true);
    this._error.set(null);

    try {
      const turnInput: TurnInput = {
        player0: {
          moveIndex: p0MoveIndex,
          salt: p0Salt,
          extraData: p0ExtraData,
        },
        player1: {
          moveIndex: p1MoveIndex,
          salt: p1Salt,
          extraData: p1ExtraData,
        },
      };

      // Execute turn via harness (delegates to Engine)
      this.harness.executeTurn(battleKey, turnInput);

      // Update battle state from harness
      this.updateBattleStateFromHarness(battleKey);

      // Record event
      this._battleEvents.update((events) => [
        ...events,
        {
          type: 'turn_executed',
          data: { p0MoveIndex, p1MoveIndex },
          turn: this._battleState()?.turn ?? 0,
          timestamp: Date.now(),
        },
      ]);
    } catch (err) {
      this._error.set(`Turn execution failed: ${(err as Error).message}`);
      throw err;
    } finally {
      this._isExecuting.set(false);
    }
  }

  /**
   * Update battle state from harness.
   * Converts harness state (with deltas) to client state (with absolute values).
   */
  private updateBattleStateFromHarness(battleKey: string): void {
    if (!this.harness) return;

    const harnessState = this.harness.getBattleState(battleKey);

    // Convert harness state to client state
    const p0Mons = harnessState.p0States.map((state) =>
      this.convertHarnessMonState(state)
    );
    const p1Mons = harnessState.p1States.map((state) =>
      this.convertHarnessMonState(state)
    );

    const isGameOver = harnessState.winnerIndex !== 2;
    const winner = isGameOver ? (harnessState.winnerIndex as 0 | 1) : undefined;

    this._battleState.set({
      battleKey,
      players: [
        { mons: p0Mons, activeMonIndex: harnessState.activeMonIndex[0] },
        { mons: p1Mons, activeMonIndex: harnessState.activeMonIndex[1] },
      ],
      turn: Number(harnessState.turnId),
      isGameOver,
      winner,
    });
  }

  /**
   * Convert harness MonState (with deltas) to client MonBattleState.
   * Note: The harness returns stat deltas. For now we return the deltas directly
   * since the base stats would need to be tracked separately.
   */
  private convertHarnessMonState(state: HarnessMonState): MonBattleState {
    return {
      // Deltas represent change from base stats
      hp: state.hpDelta,
      stamina: state.staminaDelta,
      speed: state.speedDelta,
      attack: state.attackDelta,
      defense: state.defenseDelta,
      specialAttack: state.specialAttackDelta,
      specialDefense: state.specialDefenseDelta,
      isKnockedOut: state.isKnockedOut,
      shouldSkipTurn: state.shouldSkipTurn,
      type1: MoveType.None,  // TODO: Get from mon config
      type2: MoveType.None,  // TODO: Get from mon config
    };
  }

  /**
   * Get access to the underlying harness for advanced usage.
   */
  getHarness(): BattleHarness | null {
    return this.harness;
  }

  // -------------------------------------------------------------------------
  // On-Chain Methods (using viem)
  // -------------------------------------------------------------------------

  /**
   * Start a battle on-chain
   */
  async startOnChainBattle(
    p0Address: Address,
    p1Address: Address,
    p0TeamIndex: number,
    p1TeamIndex: number
  ): Promise<Hash> {
    if (this._config().localSimulation) {
      throw new Error('On-chain mode is disabled');
    }

    if (!this._publicClient || !this._walletClient) {
      throw new Error('Viem clients not initialized');
    }

    const engineAddress = this._config().engineAddress;
    if (!engineAddress) {
      throw new Error('Engine address not configured');
    }

    // TODO: Implement actual contract call
    // This would use viem's writeContract function
    throw new Error('On-chain battle not yet implemented');
  }

  /**
   * Submit a move on-chain
   */
  async submitOnChainMove(
    battleKey: string,
    moveIndex: number,
    extraData: bigint,
    salt: string
  ): Promise<Hash> {
    if (this._config().localSimulation) {
      throw new Error('On-chain mode is disabled');
    }

    // TODO: Implement actual contract call
    throw new Error('On-chain move submission not yet implemented');
  }

  /**
   * Fetch battle state from chain
   */
  async fetchOnChainBattleState(battleKey: string): Promise<BattleState> {
    if (!this._publicClient) {
      throw new Error('Public client not initialized');
    }

    // TODO: Implement actual contract read
    throw new Error('On-chain state fetch not yet implemented');
  }

  // -------------------------------------------------------------------------
  // Utility Methods
  // -------------------------------------------------------------------------

  /**
   * Generate a random salt for move commitment
   */
  generateSalt(): string {
    if (!isPlatformBrowser(this.platformId)) {
      // Server-side fallback
      return `0x${'00'.repeat(32)}`;
    }

    const bytes = new Uint8Array(32);
    crypto.getRandomValues(bytes);
    return toHex(bytes);
  }

  /**
   * Compute move commitment hash
   */
  computeMoveCommitment(moveIndex: number, extraData: bigint, salt: string): string {
    const encoded = encodeAbiParameters(
      [{ type: 'uint8' }, { type: 'uint240' }, { type: 'bytes32' }],
      [moveIndex, extraData, salt as `0x${string}`]
    );
    return keccak256(encoded);
  }

  /**
   * Get available moves for a mon in battle
   */
  getAvailableMovesForMon(
    playerIndex: 0 | 1,
    monIndex?: number
  ): MoveMetadata[] {
    const state = this._battleState();
    if (!state) return [];

    const team = state.players[playerIndex];
    const idx = monIndex ?? team.activeMonIndex;
    const mon = team.mons[idx];

    if (!mon || mon.isKnockedOut) return [];

    // TODO: Filter by stamina cost, status effects, etc.
    return Array.from(this._moveMetadata().values());
  }

  /**
   * Check if a switch is valid
   */
  isValidSwitch(playerIndex: 0 | 1, targetMonIndex: number): boolean {
    const state = this._battleState();
    if (!state) return false;

    const team = state.players[playerIndex];
    if (targetMonIndex === team.activeMonIndex) return false;
    if (targetMonIndex < 0 || targetMonIndex >= team.mons.length) return false;

    const targetMon = team.mons[targetMonIndex];
    return !targetMon.isKnockedOut;
  }

  /**
   * Reset battle state
   */
  reset(): void {
    this._battleKey.set(null);
    this._battleState.set(null);
    this._battleEvents.set([]);
    this._isExecuting.set(false);
    this._error.set(null);
    this.harness = null;
  }
}
