/**
 * Angular Battle Service
 *
 * Provides battle simulation and on-chain interaction for the Chomp battle system.
 * Supports both local TypeScript simulation and on-chain viem interactions.
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
  effect,
  inject,
  PLATFORM_ID,
} from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import {
  createPublicClient,
  createWalletClient,
  http,
  type PublicClient,
  type WalletClient,
  type Chain,
  type Address,
  type Hash,
  keccak256,
  encodePacked,
  encodeAbiParameters,
  toHex,
} from 'viem';
import { mainnet } from 'viem/chains';

import {
  MoveMetadata,
  MoveType,
  MoveClass,
  ExtraDataType,
  BattleState,
  TeamState,
  MonBattleState,
  BattleEvent,
  BattleServiceConfig,
  MonDefinition,
  DEFAULT_CONSTANTS,
} from './types';
import { loadMoveMetadata, convertMoveMetadata } from './metadata-converter';

// =============================================================================
// LOCAL SIMULATION TYPES (matches transpiled code)
// =============================================================================

/**
 * Mon structure as used by the Engine
 */
interface EngineMon {
  stats: bigint;
  moves: string[];
  ability: string;
}

/**
 * Move selection structure
 */
interface MoveSelection {
  packedMoveIndex: bigint;
  extraData: bigint;
}

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
  // Local Simulation State (for TypeScript engine)
  // -------------------------------------------------------------------------

  private localEngine: any = null;
  private localTypeCalculator: any = null;
  private localMoves: Map<string, any> = new Map();

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
  // Local Simulation Methods
  // -------------------------------------------------------------------------

  /**
   * Initialize the local TypeScript simulation engine
   * This dynamically imports the transpiled Engine
   */
  async initializeLocalEngine(): Promise<void> {
    if (!this._config().localSimulation) {
      throw new Error('Local simulation is disabled');
    }

    try {
      // Dynamic imports for the transpiled code
      // These paths should be adjusted based on your build setup
      const [
        { Engine },
        { TypeCalculator },
        { StandardAttack },
        Structs,
        Enums,
        Constants,
      ] = await Promise.all([
        import('../../scripts/transpiler/ts-output/Engine'),
        import('../../scripts/transpiler/ts-output/TypeCalculator'),
        import('../../scripts/transpiler/ts-output/StandardAttack'),
        import('../../scripts/transpiler/ts-output/Structs'),
        import('../../scripts/transpiler/ts-output/Enums'),
        import('../../scripts/transpiler/ts-output/Constants'),
      ]);

      // Create engine instance
      this.localEngine = new Engine();
      this.localTypeCalculator = new TypeCalculator();

      // Initialize battle config storage
      (this.localEngine as any).battleConfig = {};
      (this.localEngine as any).battleData = {};
      (this.localEngine as any).storageKeyMap = {};
    } catch (err) {
      this._error.set(`Failed to initialize local engine: ${(err as Error).message}`);
      throw err;
    }
  }

  /**
   * Initialize a local battle with two teams
   */
  async initializeLocalBattle(
    p0Address: string,
    p1Address: string,
    p0Team: EngineMon[],
    p1Team: EngineMon[]
  ): Promise<string> {
    if (!this.localEngine) {
      await this.initializeLocalEngine();
    }

    const engine = this.localEngine;

    // Compute battle key
    const [battleKey] = engine.computeBattleKey(p0Address, p1Address);

    // Initialize storage
    this.initializeLocalBattleConfig(battleKey);
    this.initializeLocalBattleData(battleKey, p0Address, p1Address);

    // Set up teams
    this.setupLocalTeams(battleKey, p0Team, p1Team);

    this._battleKey.set(battleKey);
    this._battleEvents.set([]);

    // Create initial battle state
    this.updateBattleStateFromEngine(battleKey);

    return battleKey;
  }

  private initializeLocalBattleConfig(battleKey: string): void {
    const engine = this.localEngine as any;

    const emptyConfig = {
      validator: new MockValidator(),
      packedP0EffectsCount: 0n,
      rngOracle: new MockRNGOracle(),
      packedP1EffectsCount: 0n,
      moveManager: '0x0000000000000000000000000000000000000000',
      globalEffectsLength: 0n,
      teamSizes: 0n,
      engineHooksLength: 0n,
      koBitmaps: 0n,
      startTimestamp: BigInt(Math.floor(Date.now() / 1000)),
      p0Salt: '0x0000000000000000000000000000000000000000000000000000000000000000',
      p1Salt: '0x0000000000000000000000000000000000000000000000000000000000000000',
      p0Move: { packedMoveIndex: 0n, extraData: 0n },
      p1Move: { packedMoveIndex: 0n, extraData: 0n },
      p0Team: {} as any,
      p1Team: {} as any,
      p0States: {} as any,
      p1States: {} as any,
      globalEffects: {} as any,
      p0Effects: {} as any,
      p1Effects: {} as any,
      engineHooks: {} as any,
    };

    engine.battleConfig[battleKey] = emptyConfig;
    engine.storageKeyForWrite = battleKey;
    engine.storageKeyMap[battleKey] = battleKey;
  }

  private initializeLocalBattleData(
    battleKey: string,
    p0: string,
    p1: string
  ): void {
    const engine = this.localEngine as any;
    engine.battleData[battleKey] = {
      p0,
      p1,
      winnerIndex: 2n, // No winner yet
      prevPlayerSwitchForTurnFlag: 2n,
      playerSwitchForTurnFlag: 2n, // Both players move
      activeMonIndex: 0n, // Both start with mon 0
      turnId: 0n,
    };
  }

  private setupLocalTeams(
    battleKey: string,
    p0Team: EngineMon[],
    p1Team: EngineMon[]
  ): void {
    const engine = this.localEngine as any;
    const config = engine.battleConfig[battleKey];

    // Set team sizes (p0 in lower 4 bits, p1 in upper 4 bits)
    config.teamSizes = BigInt(p0Team.length) | (BigInt(p1Team.length) << 4n);

    // Add mons to teams
    for (let i = 0; i < p0Team.length; i++) {
      config.p0Team[i] = p0Team[i];
      config.p0States[i] = this.createEmptyMonState();
    }
    for (let i = 0; i < p1Team.length; i++) {
      config.p1Team[i] = p1Team[i];
      config.p1States[i] = this.createEmptyMonState();
    }
  }

  private createEmptyMonState(): any {
    return {
      packedStatDeltas: 0n,
      isKnockedOut: false,
      shouldSkipTurn: false,
    };
  }

  /**
   * Execute a turn in the local simulation
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
    if (!battleKey || !this.localEngine) {
      throw new Error('No active battle');
    }

    this._isExecuting.set(true);
    this._error.set(null);

    try {
      const engine = this.localEngine;

      // Advance block timestamp
      engine._block = engine._block || { timestamp: BigInt(Math.floor(Date.now() / 1000)) };
      engine._block.timestamp += 1n;

      // Set moves for both players
      engine.setMove(battleKey, 0n, BigInt(p0MoveIndex), p0Salt, p0ExtraData);
      engine.setMove(battleKey, 1n, BigInt(p1MoveIndex), p1Salt, p1ExtraData);

      // Execute the turn
      engine.execute(battleKey);

      // Update battle state
      this.updateBattleStateFromEngine(battleKey);

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
   * Update battle state from engine data
   */
  private updateBattleStateFromEngine(battleKey: string): void {
    const engine = this.localEngine as any;
    const config = engine.battleConfig[battleKey];
    const data = engine.battleData[battleKey];

    if (!config || !data) return;

    // Extract team sizes
    const p0Size = Number(config.teamSizes & 0xfn);
    const p1Size = Number(config.teamSizes >> 4n);

    // Build team states
    const p0Mons: MonBattleState[] = [];
    const p1Mons: MonBattleState[] = [];

    for (let i = 0; i < p0Size; i++) {
      const mon = config.p0Team[i];
      const state = config.p0States[i];
      p0Mons.push(this.extractMonState(mon, state));
    }

    for (let i = 0; i < p1Size; i++) {
      const mon = config.p1Team[i];
      const state = config.p1States[i];
      p1Mons.push(this.extractMonState(mon, state));
    }

    // Extract active mon indices
    const p0Active = Number(data.activeMonIndex & 0xfn);
    const p1Active = Number(data.activeMonIndex >> 4n);

    // Determine game over state
    const isGameOver = data.winnerIndex !== 2n;
    const winner = isGameOver ? (Number(data.winnerIndex) as 0 | 1) : undefined;

    this._battleState.set({
      battleKey,
      players: [
        { mons: p0Mons, activeMonIndex: p0Active },
        { mons: p1Mons, activeMonIndex: p1Active },
      ],
      turn: Number(data.turnId),
      isGameOver,
      winner,
    });
  }

  /**
   * Extract mon state from engine data
   */
  private extractMonState(mon: any, state: any): MonBattleState {
    // Parse packed stats from mon
    const stats = mon?.stats ?? 0n;

    return {
      hp: this.extractStat(stats, 0),
      stamina: this.extractStat(stats, 1),
      speed: this.extractStat(stats, 2),
      attack: this.extractStat(stats, 3),
      defense: this.extractStat(stats, 4),
      specialAttack: this.extractStat(stats, 5),
      specialDefense: this.extractStat(stats, 6),
      isKnockedOut: state?.isKnockedOut ?? false,
      shouldSkipTurn: state?.shouldSkipTurn ?? false,
      type1: MoveType.None,
      type2: MoveType.None,
    };
  }

  private extractStat(packedStats: bigint, index: number): bigint {
    // Stats are packed as uint32 values
    return (packedStats >> BigInt(index * 32)) & 0xffffffffn;
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
  }
}

// =============================================================================
// MOCK IMPLEMENTATIONS FOR LOCAL SIMULATION
// =============================================================================

/**
 * Mock RNG Oracle - computes deterministic RNG from both salts
 */
class MockRNGOracle {
  getRNG(p0Salt: string, p1Salt: string): bigint {
    const encoded = encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'bytes32' }],
      [p0Salt as `0x${string}`, p1Salt as `0x${string}`]
    );
    return BigInt(keccak256(encoded));
  }
}

/**
 * Mock Validator - allows all moves
 */
class MockValidator {
  validateGameStart(): boolean {
    return true;
  }

  validateSwitch(): boolean {
    return true;
  }

  validateSpecificMoveSelection(): boolean {
    return true;
  }

  validateTimeout(): string {
    return '0x0000000000000000000000000000000000000000';
  }
}
