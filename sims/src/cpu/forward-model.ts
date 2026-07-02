import { Hex } from './hex';
import { runNested } from '../../../transpiler/ts-output/runtime';
import { SWITCH_MOVE_INDEX, MOVE_INDEX_OFFSET, IS_REAL_TURN_BIT } from '../../../transpiler/ts-output/Constants';
import {
  BattleConfig,
  BattleData,
  createDefaultBattleConfig,
  createDefaultBattleData,
} from '../../../transpiler/ts-output/Structs';
import { BattleView, captureBattleView } from './battle-view';

/**
 * SEARCH SUBSTRATE — layer 2: a NON-DESTRUCTIVE forward model.
 *
 * Lets a strategy ask "what would the position look like if both players played X / Y this turn?"
 * WITHOUT touching the live battle. The trick is a shallow-but-careful clone of the engine's per-
 * battle storage (`battleData[bk]` + `battleConfig[storageKey]`) under a throwaway fork key, then a
 * faithful replay of `Engine.executeWithMoves` against that fork — minus the moveManager authorization
 * gate (which we are deliberately bypassing because the search code is not the registered moveManager).
 *
 * What is and isn't cloned:
 *   - Plain objects / arrays / bigints / strings / booleans  -> DEEP-COPIED (mutating the fork can't
 *     leak back into the live battle's state tree).
 *   - Class instances (`v.constructor !== Object`)            -> SHARED BY REFERENCE. Effects, the
 *     team registry, validator, rng oracle, engine-hook contracts and the packed move/ability
 *     Contract slots are global singletons; cloning them would (a) be wrong (they hold no per-battle
 *     mutable state we own) and (b) break identity comparisons the engine relies on.
 *
 * CPU is p1, human is p0 (inherited convention), but the fork machinery is side-agnostic.
 */

// ---------------------------------------------------------------------------------------------
// cloneState — deep-copy plain data, share class instances by reference.
// ---------------------------------------------------------------------------------------------

/**
 * Deep-copy `v`, but pass anything that is NOT a plain Object/Array (i.e. a class instance, where
 * `v.constructor !== Object`) straight through by reference. This is the single invariant that keeps
 * the fork cheap AND correct: the engine's singletons (Contracts) are shared, the per-battle data
 * tree (structs, packed Records, Mon arrays) is copied.
 *
 * Proxy-wrapped Records (the auto-vivifying `battleConfig.p0Team` etc.) report `constructor === Object`
 * through their target, so they are treated as plain objects and copied via their OWN enumerable keys
 * (the proxy only materializes a key on access, so `Object.keys` already lists every touched slot).
 */
export function cloneState<T>(v: T, seen: WeakMap<object, any> = new WeakMap()): T {
  // Primitives (incl. bigint, string, boolean, number, null, undefined, symbol) — copied by value.
  if (v === null || typeof v !== 'object') return v;

  // Class instances (Contracts, effects, registries, …) — shared by reference, NOT cloned.
  // Arrays and plain/Proxy-wrapped objects have `constructor === Object`/`Array`; everything else
  // (Engine, IEffect impls, ITeamRegistry, the stub `{_contractAddress}` is Object so it copies).
  const ctor = (v as object).constructor;
  if (ctor !== Object && ctor !== Array) return v;

  const cached = seen.get(v as object);
  if (cached !== undefined) return cached;

  if (Array.isArray(v)) {
    const out: any[] = [];
    seen.set(v as object, out);
    for (let i = 0; i < v.length; i++) out[i] = cloneState((v as any[])[i], seen);
    return out as unknown as T;
  }

  const out: Record<string, any> = {};
  seen.set(v as object, out);
  for (const k of Object.keys(v as object)) {
    out[k] = cloneState((v as Record<string, any>)[k], seen);
  }
  return out as unknown as T;
}

// ---------------------------------------------------------------------------------------------
// forkBattle — clone the live battle's storage under a fresh fork key.
// ---------------------------------------------------------------------------------------------

// The `BattleConfig` fields that are auto-vivifying Record Proxies (the engine writes NEW keys into
// these during execution — e.g. `config.p1Effects[slot]` when a move adds an effect — and relies on
// the default-factory `get` trap). A naive deep-clone turns them into plain objects and breaks that,
// so the fork must keep FRESH proxies (from `createDefaultBattleConfig`) and copy materialized
// entries into them. All OTHER config fields are scalars/structs and clone cleanly via `cloneState`.
const CONFIG_PROXY_MAP_FIELDS = [
  'p0States',
  'p1States',
  'globalEffects',
  'p0Effects',
  'p1Effects',
  'engineHooks',
] as const;

// Team arrays are written only at battle start (`Engine.startBattle`), never during a turn — the engine
// only READS `config.p{0,1}Team` while replaying a move (stat boosts mutate mon STATE deltas, not the
// stored team). So the fork shares the live team proxies by reference instead of deep-cloning ~8
// nested StoredMon structs per fork. Exact: nothing on the replayed turn writes them.
const CONFIG_SHARED_FIELDS = new Set<string>(['p0Team', 'p1Team']);

/**
 * Clone a live `BattleConfig` into a fresh one that PRESERVES the auto-vivifying proxies on its map
 * fields. Scalar/struct fields are deep-copied (`cloneState`); each proxy-map field starts from the
 * fresh default proxy and gets every materialized own-key copied in (deep-cloned), so the engine can
 * keep adding new slots on the fork without `undefined`-slot crashes. The immutable-during-turn team
 * proxies are shared by reference (see {@link CONFIG_SHARED_FIELDS}).
 */
function cloneBattleConfig(src: BattleConfig): BattleConfig {
  const out = createDefaultBattleConfig();
  const proxyFields = new Set<string>(CONFIG_PROXY_MAP_FIELDS as readonly string[]);
  const s = src as unknown as Record<string, any>;
  const o = out as unknown as Record<string, any>;

  for (const k of Object.keys(s)) {
    if (CONFIG_SHARED_FIELDS.has(k)) {
      o[k] = s[k]; // share the live team proxy by reference (read-only during a turn)
    } else if (proxyFields.has(k)) {
      // Copy each materialized entry into the fresh proxy (which retains its default factory).
      const srcMap = s[k] as Record<string, any>;
      const dstMap = o[k] as Record<string, any>;
      for (const mk of Object.keys(srcMap)) {
        dstMap[mk] = cloneState(srcMap[mk]);
      }
    } else {
      o[k] = cloneState(s[k]);
    }
  }
  return out;
}

/** Clone live `BattleData` into a fresh struct (all scalar fields — plain deep-copy). */
function cloneBattleData(src: BattleData): BattleData {
  const out = createDefaultBattleData();
  const s = src as unknown as Record<string, any>;
  const o = out as unknown as Record<string, any>;
  for (const k of Object.keys(s)) o[k] = cloneState(s[k]);
  return out;
}

let _forkCounter = 0;

/** Deterministic-ish unique fork battle key (32-byte hex). Marked with a high tag nibble so it can
 *  never collide with a real keccak battle key in practice. */
function nextForkKey(): Hex {
  _forkCounter = (_forkCounter + 1) >>> 0;
  const tag = 'f0fc'; // "fork"
  const body = _forkCounter.toString(16).padStart(8, '0');
  // 4 (tag) + 8 (counter) = 12 hex; pad the remaining 52 with the counter again for uniqueness.
  return ('0x' + tag + body + body.padStart(52, '0')) as Hex;
}

/**
 * Clone `e.battleData[bk]` and `e.battleConfig[_getStorageKey(bk)]` into a fresh fork key and return
 * that key. The fork's storageKey naturally EQUALS the fork key (no `battleKeyToStorageKey` redirect
 * is wired), mirroring `LocalBattleService.createBattle`'s re-key block — so every engine reader and
 * `_executeInternal` resolves the fork's config at `battleConfig[forkKey]`.
 */
export function forkBattle(e: any, bk: string): Hex {
  const eng = e as any;
  const forkKey = nextForkKey();

  // Source data lives at battleData[bk]; source config at battleConfig[_getStorageKey(bk)].
  const srcStorageKey = eng._getStorageKey(bk);
  const srcData = eng.battleData[bk];
  const srcConfig = eng.battleConfig[srcStorageKey];

  // Deep-clone the per-battle data tree; singletons inside are shared by reference (cloneState). The
  // config clone preserves the auto-vivifying proxies on its map fields so the engine can write new
  // effect / state slots on the fork during execution.
  eng.__mutateBattleData(forkKey, cloneBattleData(srcData));
  eng.__mutateBattleConfig(forkKey, cloneBattleConfig(srcConfig));

  // No redirect: leaving battleKeyToStorageKey[forkKey] == 0 makes _getStorageKey(forkKey) return
  // forkKey itself, so battleConfig[forkKey] is the resolved slot for both reads and execution.
  return forkKey;
}

/**
 * Reclaim a fork's cloned state — deletes the `battleData` / `battleConfig` entries `forkBattle` added
 * (the fork's storageKey equals its key, so both live under `forkKey`). A 1-ply search can skip this,
 * but a deep search forks O(branching^depth) times per turn and must dispose each fork once its subtree
 * is scored, or the fork maps grow without bound across a session.
 */
export function disposeFork(e: any, forkKey: string): void {
  const eng = e as any;
  delete eng.battleData[forkKey];
  delete eng.battleConfig[forkKey];
}

// ---------------------------------------------------------------------------------------------
// applyHypotheticalMove — replay one turn on a fork, return the resulting view.
// ---------------------------------------------------------------------------------------------

export interface HypotheticalMove {
  moveIndex: number;
  salt: bigint;
  extraData: number;
}

/**
 * Fork `bk`, submit `p0` / `p1` (either may be null on a forced-switch turn where that side doesn't
 * act), run ONE turn on the fork, and return a `BattleView` of the result. The original `bk` is left
 * completely untouched.
 *
 * The turn is run by replicating `Engine.executeWithMoves` WITHOUT the moveManager gate:
 *   1. Write both moves onto the fork config via `_setMoveInternal` (so config.p{0,1}Move/Salt are set
 *      exactly as a real submit would leave them).
 *   2. Set storageKeyForWrite + the `_turnP0Packed` / `_turnP1Packed` encoded transients the way
 *      executeWithMoves does (these take precedence inside `_getCurrentTurnMove`).
 *   3. Call `_executeInternal(forkKey, forkKey, false)` — `emitEvents=false` to keep the simulation
 *      silent (no BattleComplete / EngineExecute events leaking into the live event stream).
 *   4. `resetCallContext()` to clear the write-context transients.
 *
 * Boundary note: the runtime resets ALL transient storage at a transaction boundary (the depth
 * 0→1 entry) — which would wipe the `_turnP*Packed` we just set. `executeWithMoves` avoids this
 * because it sets the transients INSIDE its own already-entered frame. We reproduce that by running
 * the whole sequence inside `runNested`, which keeps callDepth > 0 so the inner `_executeInternal` /
 * `resetCallContext` calls are seen as nested (no boundary reset).
 */
export function applyHypotheticalMove(
  e: any,
  bk: string,
  p0: HypotheticalMove | null,
  p1: HypotheticalMove | null,
): BattleView {
  const eng = e as any;
  const forkKey = forkBattle(eng, bk);
  const config = eng.battleConfig[forkKey];

  // runNested keeps callDepth > 0 so the transaction-boundary transient reset does NOT
  // fire between us setting the turn transients and `_executeInternal` reading them.
  runNested(() => {
    eng.__mutateStorageKeyForWrite(forkKey);

    // (1) write both moves onto the fork config, and (2) set the encoded turn transients that
    // executeWithMoves would set (these win in _getCurrentTurnMove / _getCurrentTurnSalt).
    if (p0) {
      eng._setMoveInternal(config, 0n, BigInt(p0.moveIndex), p0.salt, BigInt(p0.extraData));
      eng.__mutate_turnP0Packed(packTurn(p0));
    }
    if (p1) {
      eng._setMoveInternal(config, 1n, BigInt(p1.moveIndex), p1.salt, BigInt(p1.extraData));
      eng.__mutate_turnP1Packed(packTurn(p1));
    }

    try {
      // (3) run the turn on the fork (silent).
      eng._executeInternal(forkKey, forkKey, false);
    } finally {
      // (4) clear write-context transients.
      eng.resetCallContext();
    }
  });

  return captureBattleView(eng, forkKey);
}

// Mirror Engine.executeWithMoves's transient packing: storedIndex = moveIndex (+offset if a real
// move slot), then `(storedIndex | IS_REAL_TURN_BIT) | (extraData << 8)` shifted into the high bits
// by `_packTurn` (salt in the low 104 bits). We read the engine's own constants off the instance to
// avoid duplicating magic numbers.
function packTurn(m: HypotheticalMove): bigint {
  // _packTurn(encoded, salt) = salt | (encoded << 104). We replicate inline rather than call the
  // protected helper through the proxy (which is fine, but inlining keeps the math visible/auditable).
  const mi = BigInt(m.moveIndex);
  const stored = mi < SWITCH_MOVE_INDEX ? mi + MOVE_INDEX_OFFSET : mi;
  const encoded = (stored | IS_REAL_TURN_BIT) | (BigInt(m.extraData) << 8n);
  return m.salt | (encoded << 104n);
}
