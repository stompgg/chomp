import { StatusEffectLib } from '../../../transpiler/ts-output/effects/status/StatusEffectLib';

/**
 * SIM-ONLY perf install (imported for its side effect). `StatusEffectLib.getKeyForMonIndex` derives a
 * status-effect storage key as `keccak256(encodePacked(STATUS_EFFECT, playerIndex, monIndex)) & mask64`.
 * It is PURE — the only varying inputs are `playerIndex ∈ {0,1}` and `monIndex ∈ {0..7}`, so there are
 * 16 possible results — yet the engine re-derives it ~8x per turn and every forward-model fork replays
 * those turns, making it the dominant keccak in arena runs (~9x the volume of the per-turn RNG hash).
 *
 * The effects call it through the module singleton `statusEffectLib`, which shares this prototype, so
 * memoizing the prototype method covers every caller with a ≤16-entry cache. Values are byte identical;
 * only the repeated hashing is skipped. (A general proxy-layer memo was measured and REJECTED: gating
 * every external contract call cost more than the keccak it saved — a targeted memo on this one hot pure
 * method is strictly cheaper.) Lives in `sims/` (never the deployed contracts) and survives transpiler
 * regeneration since the method name is stable.
 */
const proto = StatusEffectLib.prototype as unknown as {
  getKeyForMonIndex(playerIndex: bigint, monIndex: bigint): bigint;
  __simMemoizedKey?: boolean;
};
if (!proto.__simMemoizedKey) {
  const orig = proto.getKeyForMonIndex;
  const cache = new Map<number, bigint>();
  proto.getKeyForMonIndex = function (playerIndex: bigint, monIndex: bigint): bigint {
    const k = Number(playerIndex) * 256 + Number(monIndex);
    let v = cache.get(k);
    if (v === undefined) {
      v = orig.call(this, playerIndex, monIndex);
      cache.set(k, v);
    }
    return v;
  };
  proto.__simMemoizedKey = true;
}
