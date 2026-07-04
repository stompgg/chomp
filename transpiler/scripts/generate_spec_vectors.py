#!/usr/bin/env python3
"""Spec vectors: Solidity-semantics cases the TS oracle cannot model.

The TS sim runs on JS bigints, which neither trap (checked arithmetic,
enum-range checks) nor wrap (mod 2^256). Inside game domains TS == Solidity
bit-for-bit; outside, Solidity semantics are encoded HERE with Python
integers (arbitrary precision + explicit masking = exact EVM arithmetic):

- checked-arithmetic reverts (underflow in monStateIndexToStatBoostIndex,
  the 100-x volatility branch, int32 stat-add overflow, uint32 mul overflow
  in type effectiveness);
- enum conversion panics (Type nibble 15 in MoveSlotLib);
- unchecked 256-bit wrap (denomPower for exp >= 128, accumulate stacks).

Output shapes mirror the TS-generated suites so the Rust golden runners are
shared. Run: python3 transpiler/scripts/generate_spec_vectors.py
"""

import json
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent.parent / 'differential-rs' / 'fixtures'
FIXTURES.mkdir(parents=True, exist_ok=True)

MASK256 = (1 << 256) - 1

# Mirrors TypeCalcLib.sol (the packed 2-bit-per-cell chart constants).
MULTIPLIERS_1 = 75716198549227936736822982812955249159801631152768380745492221486153227130200
MULTIPLIERS_2 = 35843740606796099032740410262627249642837


def write_suite(name: str, vectors: list) -> None:
    path = FIXTURES / f'{name}.json'
    path.write_text(json.dumps({'suite': name, 'vectors': vectors}))
    print(f'wrote {path} ({len(vectors)} vectors)')


def type_effectiveness_code(attacker: int, defender: int) -> int:
    """0 = immune, 1 = neutral, 2 = double, 3 = half (raw 2-bit cell)."""
    index = attacker * 14 + defender
    if index < 128:
        return (MULTIPLIERS_1 >> (index * 2)) & 3
    return (MULTIPLIERS_2 >> ((index - 128) * 2)) & 3


# ---------------------------------------------------------------------------
# Type effectiveness: checked u32 overflow on the x2 branch
# ---------------------------------------------------------------------------

def spec_typecalc() -> None:
    vectors = []
    pair2 = pair1 = pair3 = pair0 = None
    for a in range(15):
        for d in range(15):
            c = type_effectiveness_code(a, d)
            if c == 2 and pair2 is None:
                pair2 = (a, d)
            elif c == 1 and pair1 is None:
                pair1 = (a, d)
            elif c == 3 and pair3 is None:
                pair3 = (a, d)
            elif c == 0 and pair0 is None:
                pair0 = (a, d)
    assert pair2 and pair1 and pair3 and pair0, 'type chart should contain every code'
    big = 3_000_000_000  # * 2 overflows uint32 -> Solidity Panic(0x11)
    a, d = pair2
    vectors.append({'inputs': [a, d, str(big)], 'reverts': True,
                    'tag': f'x2 cell ({a},{d}) with basePower*2 > uint32'})
    a, d = pair1
    vectors.append({'inputs': [a, d, str(big)], 'outputs': [str(big)],
                    'tag': 'neutral cell passes big basePower through'})
    a, d = pair3
    vectors.append({'inputs': [a, d, str(big)], 'outputs': [str(big // 2)],
                    'tag': 'half cell divides without overflow'})
    a, d = pair0
    vectors.append({'inputs': [a, d, str(big)], 'outputs': ['0'], 'tag': 'immune cell'})
    write_suite('spec_typecalc', vectors)


# ---------------------------------------------------------------------------
# Stat index maps: checked underflow + enum conversion checks
# ---------------------------------------------------------------------------

def spec_stat_index() -> None:
    vectors = []
    # monStateIndexToStatBoostIndex: Hp(0)/Stamina(1) -> idx-3 underflows.
    vectors.append({'inputs': [0], 'reverts': True, 'tag': 'Hp underflows idx-3'})
    vectors.append({'inputs': [1], 'reverts': True, 'tag': 'Stamina underflows idx-3'})
    for stat, expected in ((2, 4), (3, 0), (4, 1), (5, 2), (6, 3), (7, 4 + 0), (10, 7)):
        # 7..10 are legal inputs to the pure function (idx-3), even though the
        # engine only passes stat lanes; keep the math honest.
        if stat == 7:
            expected = 4
        if stat == 10:
            expected = 7
        vectors.append({'inputs': [stat], 'outputs': [str(expected)]})
    # statBoostIndexToMonStateIndex: idx+3 -> enum(11 variants, 0..10).
    for idx, out in ((5, 8), (6, 9), (7, 10)):
        vectors.append({'inputs': [str(idx)], 'outputs': [out], 'tag': 'toMonState'})
    for idx in (8, 100, (1 << 256) - 1):
        # 8+3=11 is out of enum range; MAX+3 overflows checked add first.
        vectors.append({'inputs': [str(idx)], 'reverts': True, 'tag': 'toMonState'})
    write_suite('spec_stat_index', vectors)


# ---------------------------------------------------------------------------
# MoveSlotLib: Type nibble 15 must panic (enum has 15 variants: 0..14)
# ---------------------------------------------------------------------------

def spec_enum_reverts() -> None:
    base_power, cls, prio, typ, stam = 55, 1, 2, 15, 3
    raw = (base_power << 248) | (cls << 246) | (prio << 244) | (typ << 240) | (stam << 236) | 0x1234
    # One vector PER decode path: moveType and decodeMeta emit the enum-range
    # check independently, and a single bundled probe would let a regression
    # in one path hide behind the other's panic (proven by a surviving
    # mutant). The runner dispatches on the tag.
    vectors = [
        {'inputs': [str(raw)], 'reverts': True, 'tag': 'moveType'},
        {'inputs': [str(raw)], 'reverts': True, 'tag': 'decodeMeta'},
    ]
    write_suite('spec_enum_reverts', vectors)


# ---------------------------------------------------------------------------
# denomPower: unchecked wrap for exp >= 128 (and exact wrapped values below)
# ---------------------------------------------------------------------------

def denom_power(exp: int) -> int:
    if exp <= 7:
        return 100 ** exp
    wrapped = pow(100, exp, 1 << 256)
    return 1 if wrapped == 0 else wrapped


def spec_denom_power() -> None:
    vectors = []
    for exp in (8, 39, 40, 41, 63, 64, 100, 120, 127, 128, 129, 200, 255, 1000, (1 << 64), (1 << 256) - 1):
        vectors.append({'inputs': [str(exp)], 'outputs': [str(denom_power(exp))]})
    write_suite('spec_denom_power', vectors)


# ---------------------------------------------------------------------------
# Accumulate pipeline with 256-bit wrap (unchecked mul/pow in _accumulateOne)
# ---------------------------------------------------------------------------

def accumulate_pipeline(base_stats, sources, applies):
    """Exact Solidity semantics for accumulateBoosts* + finalizeBoostedStats."""
    num = [0] * 5
    acc = [0] * 5

    def accumulate_one(k, pct, cnt, is_mul):
        existing = base_stats[k] if acc[k] == 0 else acc[k]
        factor = 100 + pct if is_mul else 100 - pct
        assert factor >= 0
        acc[k] = (existing * pow(factor, cnt, 1 << 256)) & MASK256
        num[k] = (num[k] + (cnt & 0xFFFFFFFF)) & 0xFFFFFFFF

    for pct, cnt, mul in sources:
        for k in range(5):
            if cnt[k] == 0:
                continue
            accumulate_one(k, pct[k], cnt[k], mul[k])
    for stat, pct, btype in applies:
        k = 4 if stat == 2 else stat - 3
        accumulate_one(k, pct, 1, btype == 0)

    final = [0] * 5
    for i in range(5):
        if num[i] > 0:
            raw = acc[i] // denom_power(num[i])
            if raw > 0x7FFFFFFF:
                final[i] = 0x7FFFFFFF
            elif raw == 0:
                final[i] = 1
            else:
                final[i] = raw
        else:
            final[i] = base_stats[i]
    return final, num, acc


def spec_accumulate_wrap() -> None:
    vectors = []
    cases = [
        # (base stats, sources [(pct[5], cnt[5], mul[5])], applies)
        # Big multiplicative stack on lane 0: wraps the numerator.
        ([100, 200, 300, 400, 500],
         [([50, 0, 0, 0, 0], [255, 0, 0, 0, 0], [True, False, False, False, False])],
         []),
        # Two big stacks: lane 0 wraps, lane 2 clamps to int32 max.
        ([7, 7, 7, 7, 7],
         [([99, 0, 30, 0, 0], [200, 0, 40, 0, 0], [True, False, True, False, False])],
         [(3, 100, 0)]),
        # Divide stack driving the numerator to zero (raw==0 -> stores 1).
        ([1, 1, 1, 1, 1],
         [([100, 100, 100, 100, 100], [1, 1, 1, 1, 1], [False, False, False, False, False])],
         []),
    ]
    for base, sources, applies in cases:
        final, num, acc = accumulate_pipeline(list(base), sources, applies)
        vectors.append({
            'inputs': [
                [str(b) for b in base],
                [[[str(p) for p in pct], [str(c) for c in cnt], mul] for pct, cnt, mul in sources],
                [[stat, str(pct), btype] for stat, pct, btype in applies],
            ],
            'outputs': [
                [str(x) for x in final],
                [str(x) for x in num],
                [str(x) for x in acc],
            ],
        })

    # Checked underflow: `DENOM - boostPercent` sits OUTSIDE the unchecked
    # block in _accumulateOne, so a Divide boost with percent > 100 reverts
    # with Panic(0x11). Cover BOTH entry points of the shared core (a
    # wrapping_sub mutant survived the gate without these).
    def revert_case(sources, applies, tag):
        vectors.append({
            'inputs': [
                ['100', '100', '100', '100', '100'],
                [[[str(p) for p in pct], [str(c) for c in cnt], mul] for pct, cnt, mul in sources],
                [[stat, str(pct), btype] for stat, pct, btype in applies],
            ],
            'reverts': True,
            'tag': tag,
        })

    for pct in (101, 255):
        revert_case(
            [([pct, 0, 0, 0, 0], [1, 0, 0, 0, 0], [False, False, False, False, False])],
            [],
            f'accumulateBoosts divide lane pct={pct} underflows DENOM-pct',
        )
        revert_case(
            [],
            [(3, pct, 1)],  # StatBoostType.Divide == 1
            f'accumulateBoostsToApply Divide pct={pct} underflows DENOM-pct',
        )
    write_suite('spec_accumulate_wrap', vectors)


# ---------------------------------------------------------------------------
# Damage core: checked reverts (volatility underflow, int32 stat overflow)
# ---------------------------------------------------------------------------

def spec_damage_core() -> None:
    def ctx_inputs(aa, aad, asp, aspd, dd, ddd, dsd, dsdd, t1, t2):
        return [str(aa), str(aad), str(asp), str(aspd), str(dd), str(ddd),
                str(dsd), str(dsdd), t1, t2]

    vectors = []

    # Find h with scalingRoll%100 <= 50 (else-branch) and scalingRoll%201 > 100
    # so `100 - uint32(scalingRoll % (vol+1))` underflows for volatility=200.
    h = None
    for candidate in range(1, 100000):
        roll = (candidate >> 64) & ((1 << 64) - 1)
        scaled = candidate << 64  # put candidate's low bits into the roll slice
        roll = candidate
        if roll % 100 <= 50 and roll % 201 > 100:
            h = candidate << 64  # scalingRoll = uint64(h >> 64) = candidate
            break
    assert h is not None
    # accuracy check uses uint64(h) % 100 -> h low 64 bits are zero -> 0 < any
    # accuracy... but _calculateDamageCore takes h directly (no accuracy).
    vectors.append({
        'inputs': ctx_inputs(100, 0, 100, 0, 100, 0, 100, 0, 0, 14)
        + ['80', 0, '200', str(h), '0'],
        'reverts': True,
        'tag': 'volatility 200: 100 - roll%201 underflows uint32',
    })

    # int32 overflow in the stat adds: all four (attacker/defender x
    # Physical/Special) branches emit the checked add independently — cover
    # each with the non-target lanes benign so only the target add can trap.
    vectors.append({
        'inputs': ctx_inputs(0x7FFFFFFF, 1, 100, 0, 100, 0, 100, 0, 0, 14)
        + ['80', 0, '0', '12345', '0'],
        'reverts': True,
        'tag': 'int32(attackerAttack) + delta overflows i32',
    })
    vectors.append({
        'inputs': ctx_inputs(100, 0, 100, 0, 0x7FFFFFFF, 1, 100, 0, 0, 14)
        + ['80', 0, '0', '12345', '0'],
        'reverts': True,
        'tag': 'int32(defenderDef) + delta overflows i32',
    })
    vectors.append({
        'inputs': ctx_inputs(100, 0, 0x7FFFFFFF, 1, 100, 0, 100, 0, 0, 14)
        + ['80', 1, '0', '12345', '0'],
        'reverts': True,
        'tag': 'int32(attackerSpAtk) + delta overflows i32',
    })
    vectors.append({
        'inputs': ctx_inputs(100, 0, 100, 0, 100, 0, 0x7FFFFFFF, 1, 0, 14)
        + ['80', 1, '0', '12345', '0'],
        'reverts': True,
        'tag': 'int32(defenderSpDef) + delta overflows i32',
    })
    write_suite('spec_damage_core', vectors)


if __name__ == '__main__':
    spec_typecalc()
    spec_stat_index()
    spec_enum_reverts()
    spec_denom_power()
    spec_accumulate_wrap()
    spec_damage_core()
    print('done')
