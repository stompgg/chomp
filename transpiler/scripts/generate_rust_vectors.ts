// Golden-vector generator: runs the TypeScript transpiled pure libs (the
// fast oracle, itself validated against Solidity) over deterministic input
// sweeps and writes JSON fixtures for the Rust differential tests.
//
//   bun transpiler/scripts/generate_rust_vectors.ts
//
// Prereqs: ts-output regenerated (`python3 -m transpiler src/ -o
// transpiler/ts-output -d src --emit-metadata`) and viem installed at the
// repo root (`bun add viem`; package.json is intentionally gitignored).
//
// Scope note: the TS oracle is bit-exact WITHIN GAME DOMAINS but does not
// model Solidity checked-arithmetic reverts, enum-range panics, or 256-bit
// wrap (JS bigints neither trap nor wrap). Inputs here stay inside domains
// where TS ≡ Solidity; the out-of-domain cases (reverts, mod-2^256 wraps)
// are covered by generate_spec_vectors.py, which encodes EVM semantics
// directly.

import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import { typeCalcLib } from '../ts-output/types/TypeCalcLib';
import { TypeCalculator } from '../ts-output/types/TypeCalculator';
import { rNGLib } from '../ts-output/lib/RNGLib';
import { statBoostLib } from '../ts-output/lib/StatBoostLib';
import { attackCalculator } from '../ts-output/moves/AttackCalculator';
import { moveSlotLib } from '../ts-output/moves/MoveSlotLib';
import { staminaRegenLogic } from '../ts-output/lib/StaminaRegenLogic';
import * as Constants from '../ts-output/Constants';
import * as Structs from '../ts-output/Structs';

const FIXTURES = join(import.meta.dir, '..', 'differential-rs', 'fixtures');
mkdirSync(FIXTURES, { recursive: true });

// ---------------------------------------------------------------------------
// Deterministic PRNG (xorshift64*) — vectors are reproducible by seed.
// ---------------------------------------------------------------------------

const U64 = (1n << 64n) - 1n;
let state = 0x9e3779b97f4a7c15n;

function nextU64(): bigint {
  state ^= state >> 12n;
  state = (state ^ (state << 25n)) & U64;
  state ^= state >> 27n;
  return (state * 0x2545f4914f6cdd1dn) & U64;
}

function nextU256(): bigint {
  return (nextU64() << 192n) | (nextU64() << 128n) | (nextU64() << 64n) | nextU64();
}

/** Uniform-ish integer in [lo, hi] inclusive. */
function rint(lo: number, hi: number): number {
  return lo + Number(nextU64() % BigInt(hi - lo + 1));
}

function rbig(lo: bigint, hi: bigint): bigint {
  return lo + (nextU256() % (hi - lo + 1n));
}

function rbool(): boolean {
  return (nextU64() & 1n) === 1n;
}

// ---------------------------------------------------------------------------
// Serialization: bigint -> decimal string (bigint-safe on both sides)
// ---------------------------------------------------------------------------

type Val = string | number | boolean | Val[];

function ser(v: unknown): Val {
  if (typeof v === 'bigint') return v.toString(10);
  if (Array.isArray(v)) return v.map(ser);
  return v as Val;
}

interface Vector {
  inputs: Val[];
  outputs?: Val[];
  reverts?: boolean;
  tag?: string;
}

function writeSuite(name: string, vectors: Vector[]): void {
  const path = join(FIXTURES, `${name}.json`);
  writeFileSync(path, JSON.stringify({ suite: name, vectors }));
  console.log(`wrote ${path} (${vectors.length} vectors)`);
}

// ---------------------------------------------------------------------------
// 1. Type effectiveness: the full 15x15 matrix x base powers
// ---------------------------------------------------------------------------
{
  const vectors: Vector[] = [];
  // 2147483647 * 2 still fits uint32; larger base powers would revert in
  // Solidity (checked u32 mul) which the TS oracle cannot model.
  const powers = [0n, 1n, 7n, 100n, 65535n, 2147483647n];
  for (let a = 0; a < 15; a++) {
    for (let d = 0; d < 15; d++) {
      for (const p of powers) {
        const out = typeCalcLib.getTypeEffectiveness(a, d, p);
        vectors.push({ inputs: [a, d, ser(p)], outputs: [ser(out)] });
      }
    }
  }
  writeSuite('typecalc_effectiveness', vectors);
}

// ---------------------------------------------------------------------------
// 2. RNG mixing (keccak256 + abi.encode(uint256,uint256))
// ---------------------------------------------------------------------------
{
  const vectors: Vector[] = [];
  const cases: [bigint, bigint][] = [
    [0n, 0n],
    [0n, 1n],
    [1n, 0n],
    [(1n << 256n) - 1n, 1n],
  ];
  for (let i = 0; i < 64; i++) cases.push([nextU256(), nextU64() % 2n]);
  for (const [rng, idx] of cases) {
    vectors.push({ inputs: [ser(rng), ser(idx)], outputs: [ser(rNGLib.mixForAttacker(rng, idx))] });
  }
  writeSuite('rng_mix', vectors);
}

// ---------------------------------------------------------------------------
// 3. shouldApplyEffect (keccak over (uint256,uint256,string) + thresholds)
// ---------------------------------------------------------------------------
{
  const vectors: Vector[] = [];
  for (let i = 0; i < 256; i++) {
    const rng = nextU256();
    const idx = nextU64() % 2n;
    const basePower = [0n, 0n, 50n, 200n][rint(0, 3)];
    const damage = BigInt(rint(-50, 500));
    const ea = BigInt(rint(0, 100));
    const out = attackCalculator.shouldApplyEffect(rng, idx, basePower, damage, ea);
    vectors.push({ inputs: [ser(rng), ser(idx), ser(basePower), ser(damage), ser(ea)], outputs: [out] });
  }
  writeSuite('attack_should_apply', vectors);
}

// ---------------------------------------------------------------------------
// 4. _calculateDamageCore — the spike's target function
// ---------------------------------------------------------------------------

function randomCtx(): Structs.DamageCalcContext {
  const ctx = Structs.createDefaultDamageCalcContext();
  ctx.attackerAttack = BigInt(rint(1, 4000));
  ctx.attackerAttackDelta = BigInt(rint(-2000, 2000));
  ctx.attackerSpAtk = BigInt(rint(1, 4000));
  ctx.attackerSpAtkDelta = BigInt(rint(-2000, 2000));
  ctx.defenderDef = BigInt(rint(1, 4000));
  ctx.defenderDefDelta = BigInt(rint(-2000, 2000));
  ctx.defenderSpDef = BigInt(rint(1, 4000));
  ctx.defenderSpDefDelta = BigInt(rint(-2000, 2000));
  ctx.defenderType1 = rint(0, 14);
  ctx.defenderType2 = rint(0, 14);
  return ctx;
}

function ctxInputs(ctx: Structs.DamageCalcContext): Val[] {
  return [
    ser(ctx.attackerAttack), ser(ctx.attackerAttackDelta),
    ser(ctx.attackerSpAtk), ser(ctx.attackerSpAtkDelta),
    ser(ctx.defenderDef), ser(ctx.defenderDefDelta),
    ser(ctx.defenderSpDef), ser(ctx.defenderSpDefDelta),
    ctx.defenderType1, ctx.defenderType2,
  ];
}

{
  const vectors: Vector[] = [];
  for (let i = 0; i < 400; i++) {
    const ctx = randomCtx();
    const scaledBasePower = BigInt([0, 1, 40, 80, 200, 65535][rint(0, 5)]);
    const supertype = rint(0, 1); // Physical | Special
    const volatility = BigInt(rint(0, 100));
    const h = nextU256();
    const critRate = BigInt(rint(0, 100));
    const [damage, eventType] = attackCalculator._calculateDamageCore(
      ctx, scaledBasePower, supertype, volatility, h, critRate,
    );
    vectors.push({
      inputs: [...ctxInputs(ctx), ser(scaledBasePower), supertype, ser(volatility), ser(h), ser(critRate)],
      outputs: [ser(damage), eventType],
    });
  }
  // Boundary: negative stat wrap (uint32 cast of negative sum) + clamp path
  {
    const ctx = randomCtx();
    ctx.attackerAttack = 10n;
    ctx.attackerAttackDelta = -1000n; // wraps to huge u32
    ctx.defenderDef = 1n;
    ctx.defenderDefDelta = 0n;
    const [damage, eventType] = attackCalculator._calculateDamageCore(ctx, 65535n, 0, 0n, 123456789n, 100n);
    vectors.push({
      inputs: [...ctxInputs(ctx), '65535', 0, '0', '123456789', '100'],
      outputs: [ser(damage), eventType],
      tag: 'negative-stat-wrap-clamp',
    });
  }
  writeSuite('attack_damage_core', vectors);
}

// ---------------------------------------------------------------------------
// 5. _calculateDamageFromContext (accuracy roll + real TypeCalculator)
// ---------------------------------------------------------------------------
{
  const tc = new TypeCalculator();
  const vectors: Vector[] = [];
  for (let i = 0; i < 300; i++) {
    const ctx = randomCtx();
    const basePower = BigInt([0, 1, 40, 80, 130][rint(0, 4)]);
    const accuracy = BigInt([0, 30, 70, 100][rint(0, 3)]);
    const volatility = BigInt(rint(0, 30));
    const attackType = rint(0, 14);
    const supertype = rint(0, 1);
    const rng = nextU256();
    const critRate = BigInt(rint(0, 100));
    const [damage, eventType] = attackCalculator._calculateDamageFromContext(
      tc, ctx, basePower, accuracy, volatility, attackType, supertype, rng, critRate,
    );
    vectors.push({
      inputs: [
        ...ctxInputs(ctx), ser(basePower), ser(accuracy), ser(volatility),
        attackType, supertype, ser(rng), ser(critRate),
      ],
      outputs: [ser(damage), eventType],
    });
  }
  writeSuite('attack_from_context', vectors);
}

// ---------------------------------------------------------------------------
// 6/7/8. StatBoost packing round-trips
// ---------------------------------------------------------------------------

/** Valid boost stats: Speed(2), Attack(3), Defense(4), SpAtk(5), SpDef(6). */
function randomApplies(maxLen: number): { stat: number; boostPercent: bigint; boostType: number }[] {
  const n = rint(0, maxLen);
  const applies = [];
  for (let i = 0; i < n; i++) {
    applies.push({
      stat: rint(2, 6),
      // Divide caps at 100 (DENOM - pct would revert above); keep Multiply in
      // the same range so vectors stay in the shared TS/Solidity domain.
      boostPercent: BigInt(rint(0, 100)),
      boostType: rint(0, 1),
    });
  }
  return applies;
}

{
  const packVectors: Vector[] = [];
  const unpackVectors: Vector[] = [];
  const packArrVectors: Vector[] = [];
  for (let i = 0; i < 200; i++) {
    const key = rbig(0n, (1n << 168n) - 1n);
    const perm = rbool();
    const applies = randomApplies(5);
    const packed = statBoostLib.packBoostData(key, perm, applies.map(a => ({ ...a })));
    packVectors.push({
      inputs: [ser(key), perm, applies.map(a => [a.stat, ser(a.boostPercent), a.boostType])],
      outputs: [packed],
    });

    const [uPerm, uKey, uPct, uCnt, uMul] = statBoostLib.unpackBoostData(packed);
    unpackVectors.push({
      inputs: [packed],
      outputs: [uPerm, ser(uKey), ser(uPct), ser(uCnt), uMul],
    });

    const repacked = statBoostLib.packBoostDataWithArrays(uKey, uPerm, uPct, uCnt, uMul);
    packArrVectors.push({
      inputs: [ser(uKey), uPerm, ser(uPct), ser(uCnt), uMul],
      outputs: [repacked],
    });
  }
  // Random raw bytes32 unpack (fields decode from arbitrary bit patterns)
  for (let i = 0; i < 100; i++) {
    const raw = '0x' + nextU256().toString(16).padStart(64, '0');
    const [uPerm, uKey, uPct, uCnt, uMul] = statBoostLib.unpackBoostData(raw);
    unpackVectors.push({ inputs: [raw], outputs: [uPerm, ser(uKey), ser(uPct), ser(uCnt), uMul] });
  }
  writeSuite('statboost_pack', packVectors);
  writeSuite('statboost_unpack', unpackVectors);
  writeSuite('statboost_pack_arrays', packArrVectors);
}

// ---------------------------------------------------------------------------
// 9. Accumulate + finalize pipeline (in-place &mut array mutation)
// ---------------------------------------------------------------------------
{
  const vectors: Vector[] = [];
  for (let i = 0; i < 200; i++) {
    const baseStats = [0, 0, 0, 0, 0].map(() => BigInt(rint(1, 3000)));
    const numSources = rint(0, 4);
    const sources: [bigint[], bigint[], boolean[]][] = [];
    for (let s = 0; s < numSources; s++) {
      const pct = [0, 0, 0, 0, 0].map(() => BigInt(rint(0, 50)));
      const cnt = [0, 0, 0, 0, 0].map(() => BigInt(rint(0, 4)));
      const mul = [0, 0, 0, 0, 0].map(() => rbool());
      sources.push([pct, cnt, mul]);
    }
    const applies = randomApplies(4);

    const numBoosts = [0n, 0n, 0n, 0n, 0n];
    const acc = [0n, 0n, 0n, 0n, 0n];
    const base = baseStats.slice();
    for (const [pct, cnt, mul] of sources) {
      statBoostLib.accumulateBoosts(base, pct.slice(), cnt.slice(), mul.slice(), numBoosts, acc);
    }
    statBoostLib.accumulateBoostsToApply(base, applies.map(a => ({ ...a })), numBoosts, acc);
    const finalStats = statBoostLib.finalizeBoostedStats(base, numBoosts, acc);

    vectors.push({
      inputs: [
        ser(baseStats),
        sources.map(([p, c, m]) => [ser(p), ser(c), m]),
        applies.map(a => [a.stat, ser(a.boostPercent), a.boostType]),
      ],
      outputs: [ser(finalStats), ser(numBoosts), ser(acc)],
    });
  }
  writeSuite('statboost_accumulate', vectors);
}

// ---------------------------------------------------------------------------
// 10. mergeExistingAndNewBoosts — including the memory-aliasing case
//     (two new boosts on the same fresh stat in one call)
// ---------------------------------------------------------------------------
{
  const vectors: Vector[] = [];
  for (let i = 0; i < 150; i++) {
    const ep = [0, 0, 0, 0, 0].map(() => BigInt(rint(0, 1) === 0 ? 0 : rint(1, 100)));
    const ec = ep.map(p => (p === 0n ? 0n : BigInt(rint(1, 126))));
    const em = [0, 0, 0, 0, 0].map(() => rbool());
    const applies = randomApplies(4);
    const [mp, mc, mm] = statBoostLib.mergeExistingAndNewBoosts(
      ep.slice(), ec.slice(), em.slice(), applies.map(a => ({ ...a })),
    );
    vectors.push({
      inputs: [ser(ep), ser(ec), em, applies.map(a => [a.stat, ser(a.boostPercent), a.boostType])],
      outputs: [ser(mp), ser(mc), ser(mm)],
    });
  }
  // Deterministic aliasing probe: existing all-zero, two boosts on the same
  // stat. Solidity/TS: iteration 2 reads the alias-updated array -> count 2.
  {
    const ep = [0n, 0n, 0n, 0n, 0n];
    const ec = [0n, 0n, 0n, 0n, 0n];
    const em = [false, false, false, false, false];
    const applies = [
      { stat: 3, boostPercent: 10n, boostType: 0 },
      { stat: 3, boostPercent: 25n, boostType: 1 },
    ];
    const [mp, mc, mm] = statBoostLib.mergeExistingAndNewBoosts(
      ep.slice(), ec.slice(), em.slice(), applies.map(a => ({ ...a })),
    );
    vectors.push({
      inputs: [['0', '0', '0', '0', '0'], ['0', '0', '0', '0', '0'], em,
        applies.map(a => [a.stat, ser(a.boostPercent), a.boostType])],
      outputs: [ser(mp), ser(mc), ser(mm)],
      tag: 'same-stat-twice-aliasing',
    });
  }
  writeSuite('statboost_merge', vectors);
}

// ---------------------------------------------------------------------------
// 11. generateKeyNoSalt + stat index maps + denomPower (in-domain)
// ---------------------------------------------------------------------------
{
  const keyVectors: Vector[] = [];
  for (let i = 0; i < 100; i++) {
    const target = BigInt(rint(0, 1));
    const mon = BigInt(rint(0, 63));
    const addr = '0x' + nextU256().toString(16).padStart(64, '0').slice(24);
    const out = statBoostLib.generateKeyNoSalt(target, mon, addr);
    keyVectors.push({ inputs: [ser(target), ser(mon), addr], outputs: [ser(out)] });
  }
  writeSuite('statboost_key', keyVectors);

  const idxVectors: Vector[] = [];
  for (const stat of [2, 3, 4, 5, 6]) {
    idxVectors.push({ inputs: [stat], outputs: [ser(statBoostLib.monStateIndexToStatBoostIndex(stat))] });
  }
  for (const idx of [0n, 1n, 2n, 3n, 4n]) {
    idxVectors.push({
      inputs: [ser(idx)],
      outputs: [Number(statBoostLib.statBoostIndexToMonStateIndex(idx))],
      tag: 'toMonState',
    });
  }
  writeSuite('statboost_stat_index', idxVectors);

  const denomVectors: Vector[] = [];
  // 100^38 = 10^76 < 2^256 but 100^39 overflows: beyond exp 38 the unchecked
  // Solidity math wraps mod 2^256, which JS bigints do not — those exps are
  // covered by generate_spec_vectors.py instead.
  for (let e = 0n; e <= 38n; e++) {
    denomVectors.push({ inputs: [ser(e)], outputs: [ser(statBoostLib.denomPower(e))] });
  }
  writeSuite('statboost_denom_power', denomVectors);
}

// ---------------------------------------------------------------------------
// 12. MoveSlotLib inline decoding
// ---------------------------------------------------------------------------
{
  const BK = '0x' + '00'.repeat(32);
  const vectors: Vector[] = [];
  for (let i = 0; i < 250; i++) {
    // Compose an inline slot: [8b basePower | 2b class | 2b prio | 4b type | 4b stamina | ...addr junk]
    const basePower = BigInt(rint(0, 255));
    const cls = BigInt(rint(0, 3));
    const prio = BigInt(rint(0, 3));
    const typ = BigInt(rint(0, 14)); // 15 would panic in Rust; TS can't model it (spec vector covers)
    const stam = BigInt(rint(0, 15));
    const junk = nextU256() & ((1n << 236n) - 1n);
    const raw = (basePower << 248n) | (cls << 246n) | (prio << 244n) | (typ << 240n) | (stam << 236n) | junk;
    if (raw >> 160n === 0n) continue; // must be inline
    const meta = moveSlotLib.decodeMeta(raw, null as any, BK, 0n, 0n);
    vectors.push({
      inputs: [ser(raw)],
      outputs: [
        moveSlotLib.isInline(raw),
        ser(moveSlotLib.basePower(raw, BK)),
        Number(moveSlotLib.moveClass(raw, null as any, BK)),
        ser(moveSlotLib.priority(raw, null as any, BK, 0n)),
        Number(moveSlotLib.moveType(raw, null as any, BK)),
        ser(moveSlotLib.stamina(raw, null as any, BK, 0n, 0n)),
        // decodeMeta mirrors the five + extraDataType
        Number(meta.moveClass), ser(meta.priority), Number(meta.moveType),
        ser(meta.stamina), ser(meta.basePower), Number(meta.extraDataType),
      ],
    });
  }
  // External (non-inline) slot: isInline false + basePower reverts
  const extRaw = 0xdeadbeefn;
  vectors.push({ inputs: [ser(extRaw)], outputs: [false], reverts: false, tag: 'external-isinline' });
  writeSuite('moveslot_inline', vectors);
}

// ---------------------------------------------------------------------------
// 13. StaminaRegen pure predicates
// ---------------------------------------------------------------------------
{
  const vectors: Vector[] = [];
  for (let flag = 0n; flag <= 3n; flag++) {
    for (const packed of [0n, 1n, 125n, 126n, 127n, 128n, 254n, 255n]) {
      vectors.push({
        inputs: [ser(flag), ser(packed)],
        outputs: [
          staminaRegenLogic._shouldRegenOnRoundEnd(flag),
          staminaRegenLogic._isRestingMove(packed),
        ],
      });
    }
  }
  writeSuite('stamina_pure', vectors);
}

// ---------------------------------------------------------------------------
// 14. Constants parity (runtime-computed event types, packed sentinels)
// ---------------------------------------------------------------------------
{
  const vectors: Vector[] = [{
    inputs: [],
    outputs: [
      Constants.MOVE_MISS_EVENT_TYPE,
      Constants.MOVE_CRIT_EVENT_TYPE,
      Constants.MOVE_TYPE_IMMUNITY_EVENT_TYPE,
      Constants.NONE_EVENT_TYPE,
      ser(Constants.PACKED_CLEARED_MON_STATE),
      ser(Constants.CLEARED_MON_STATE_SENTINEL),
      ser(Constants.MAX_BATTLE_DURATION),
      ser(Constants.STREAK_GRACE_WINDOW),
      ser(Constants.MAX_EFFECTS_PER_MON),
    ],
  }];
  writeSuite('constants_parity', vectors);
}

console.log('done');
