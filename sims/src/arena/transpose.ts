/**
 * Transposed engine view for the CPU arena.
 *
 * Every CPU strategy hardcodes the production convention "the CPU is p1, the
 * opponent is p0". To let a strategy play the p0 seat of a real battle, we hand
 * it a Proxy of the engine that flips the playerIndex argument (0n <-> 1n) on
 * the strategy-facing read surface, so the seat-0 strategy sees itself as p1.
 *
 * Scope: this transposes exactly the methods the strategies + their helpers
 * (engine-view / heuristic-shared / battle-view / forward-model) reach, plus
 * the forward-model's fork submission hooks. Engine-internal self-calls are
 * unaffected (wrapped methods are applied to the raw target). A known hole:
 * an EXTERNAL move whose getMeta/basePower reads battle state through a
 * captured engine singleton (rather than the engine argument it receives)
 * would bypass the proxy — no current move does this; inline moves decode
 * purely from the packed slot.
 */

// Methods whose playerIndex argument(s) get flipped, by argument position.
const FLIP_ARG_POSITIONS: Record<string, number[]> = {
  getMonStatsForBattle: [1],
  getMonStateForBattle: [1],
  getMonValueForBattle: [1],
  getMoveForMonForBattle: [1],
  getKOBitmap: [1],
  getMoveDecisionForSlot: [1],
  validatePlayerMoveForBattle: [2],
  getDamageCalcContext: [1, 3], // (bk, atkPlayer, atkMon, defPlayer, defMon) — player args at 1 & 3
  // forward-model fork submission: _setMoveInternal(config, playerIndex, ...)
  _setMoveInternal: [1],
};

// Methods whose names swap with each other (forward-model turn transients).
const SWAP_NAMES: Record<string, string> = {
  __mutate_turnP0Packed: '__mutate_turnP1Packed',
  __mutate_turnP1Packed: '__mutate_turnP0Packed',
};

function flipPlayerIndex(v: unknown): unknown {
  if (v === 0n) return 1n;
  if (v === 1n) return 0n;
  if (v === 0) return 1;
  if (v === 1) return 0;
  return v;
}

/** Wrap `engine` so playerIndex-sensitive reads are seen from the p0 seat as if it were p1. */
export function transposeEngine(engine: any): any {
  const wrapped = new Map<PropertyKey, any>();
  return new Proxy(engine, {
    get(target, prop) {
      if (wrapped.has(prop)) return wrapped.get(prop);
      const name = String(prop);
      const swapped = SWAP_NAMES[name];
      const val = target[swapped ?? name];
      if (typeof val !== 'function') return val;

      let out: any;
      if (name in FLIP_ARG_POSITIONS) {
        const positions = FLIP_ARG_POSITIONS[name];
        out = (...args: any[]) => {
          for (const p of positions) args[p] = flipPlayerIndex(args[p]);
          return val.apply(target, args);
        };
      } else if (name === 'getActiveMonIndexForBattleState') {
        out = (...args: any[]) => {
          const r = val.apply(target, args);
          return [r[1], r[0]];
        };
      } else if (name === 'getBattleContext') {
        out = (...args: any[]) => {
          const ctx = val.apply(target, args);
          const flag = Number(ctx.playerSwitchForTurnFlag);
          // Seat-swap the active indices; flip the singles switch flag (0/1).
          return {
            ...ctx,
            p0ActiveMonIndex: ctx.p1ActiveMonIndex,
            p1ActiveMonIndex: ctx.p0ActiveMonIndex,
            playerSwitchForTurnFlag: flag === 0 || flag === 1 ? BigInt(1 - flag) : ctx.playerSwitchForTurnFlag,
          };
        };
      } else {
        out = val.bind(target);
      }
      wrapped.set(prop, out);
      return out;
    },
  });
}
