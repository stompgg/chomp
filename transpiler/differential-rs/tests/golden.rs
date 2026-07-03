//! Golden-vector differential tests: generated Rust engine vs the TS oracle
//! (fixtures from scripts/generate_rust_vectors.ts) and vs Solidity spec
//! semantics for trap/wrap paths (scripts/generate_spec_vectors.py).
//!
//! Every runner is shared between the TS-derived suite and its spec suite —
//! same input/output shapes, different provenance.

#![allow(non_snake_case)]

use chomp_differential::*;
use chomp_differential::mock_engine::PanicEngine;

use chomp_engine::Enums::{MonStateIndexName, MoveClass, StatBoostType, Type};
use chomp_engine::Structs::{DamageCalcContext, StatBoostToApply};
use chomp_engine::lib::{RNGLib, StaminaRegenLogic, StatBoostLib};
use chomp_engine::moves::{AttackCalculator, MoveSlotLib};
use chomp_engine::types::ITypeCalculator::ITypeCalculator;
use chomp_engine::types::TypeCalculator::TypeCalculator;
use chomp_engine::types::TypeCalcLib;
use chomp_engine::Constants;

fn arr(v: &serde_json::Value) -> &Vec<serde_json::Value> {
    v.as_array().expect("expected JSON array")
}

fn u8x5(v: &serde_json::Value) -> [u8; 5] {
    let a = arr(v);
    std::array::from_fn(|i| as_u8(&a[i]))
}

fn u32x5(v: &serde_json::Value) -> [u32; 5] {
    let a = arr(v);
    std::array::from_fn(|i| as_u32(&a[i]))
}

fn u256x5(v: &serde_json::Value) -> [U256; 5] {
    let a = arr(v);
    std::array::from_fn(|i| as_u256(&a[i]))
}

fn boolx5(v: &serde_json::Value) -> [bool; 5] {
    let a = arr(v);
    std::array::from_fn(|i| as_bool(&a[i]))
}

fn applies(v: &serde_json::Value) -> Vec<StatBoostToApply> {
    arr(v)
        .iter()
        .map(|e| {
            let e = arr(e);
            StatBoostToApply {
                stat: MonStateIndexName::from_u8(as_u8(&e[0])),
                boostPercent: as_u8(&e[1]),
                boostType: StatBoostType::from_u8(as_u8(&e[2])),
            }
        })
        .collect()
}

fn damage_ctx(inputs: &[serde_json::Value]) -> DamageCalcContext {
    DamageCalcContext {
        attackerMonIndex: 0,
        defenderMonIndex: 0,
        attackerAttack: as_u32(&inputs[0]),
        attackerAttackDelta: as_i32(&inputs[1]),
        attackerSpAtk: as_u32(&inputs[2]),
        attackerSpAtkDelta: as_i32(&inputs[3]),
        defenderDef: as_u32(&inputs[4]),
        defenderDefDelta: as_i32(&inputs[5]),
        defenderSpDef: as_u32(&inputs[6]),
        defenderSpDefDelta: as_i32(&inputs[7]),
        defenderType1: Type::from_u8(as_u8(&inputs[8])),
        defenderType2: Type::from_u8(as_u8(&inputs[9])),
    }
}

fn for_each(suites: &[&str], mut body: impl FnMut(&str, usize, &Vector)) {
    for name in suites {
        let suite = load_suite(name);
        assert!(!suite.vectors.is_empty(), "{name}: empty suite");
        for (i, v) in suite.vectors.iter().enumerate() {
            body(name, i, v);
        }
    }
}

// ---------------------------------------------------------------------------

#[test]
fn typecalc_effectiveness() {
    for_each(&["typecalc_effectiveness", "spec_typecalc"], |name, i, v| {
        run_vector(name, i, v, || {
            let out = TypeCalcLib::getTypeEffectiveness(
                Type::from_u8(as_u8(&v.inputs[0])),
                Type::from_u8(as_u8(&v.inputs[1])),
                as_u32(&v.inputs[2]),
            );
            if !v.reverts {
                assert_eq!(out, as_u32(&v.outputs[0]), "{name}[{i}]");
            }
        });
    });
}

#[test]
fn rng_mix() {
    for_each(&["rng_mix"], |name, i, v| {
        run_vector(name, i, v, || {
            let out = RNGLib::mixForAttacker(as_u256(&v.inputs[0]), as_u256(&v.inputs[1]));
            assert_eq!(out, as_u256(&v.outputs[0]), "{name}[{i}]");
        });
    });
}

#[test]
fn attack_should_apply() {
    for_each(&["attack_should_apply"], |name, i, v| {
        run_vector(name, i, v, || {
            let out = AttackCalculator::shouldApplyEffect(
                as_u256(&v.inputs[0]),
                as_u256(&v.inputs[1]),
                as_u32(&v.inputs[2]),
                as_i32(&v.inputs[3]),
                as_u32(&v.inputs[4]),
            );
            assert_eq!(out, as_bool(&v.outputs[0]), "{name}[{i}]");
        });
    });
}

#[test]
fn attack_damage_core() {
    for_each(&["attack_damage_core", "spec_damage_core"], |name, i, v| {
        run_vector(name, i, v, || {
            let mut ctx = damage_ctx(&v.inputs);
            let (damage, event) = AttackCalculator::_calculateDamageCore(
                &mut ctx,
                as_u32(&v.inputs[10]),
                MoveClass::from_u8(as_u8(&v.inputs[11])),
                as_u256(&v.inputs[12]),
                as_u256(&v.inputs[13]),
                as_u256(&v.inputs[14]),
            );
            if !v.reverts {
                assert_eq!(damage, as_i32(&v.outputs[0]), "{name}[{i}] damage");
                assert_eq!(event, as_b256(&v.outputs[1]), "{name}[{i}] eventType");
            }
        });
    });
}

#[test]
fn attack_from_context() {
    for_each(&["attack_from_context"], |name, i, v| {
        run_vector(name, i, v, || {
            let mut tc = TypeCalculator::default();
            let mut ctx = damage_ctx(&v.inputs);
            let (damage, event) = AttackCalculator::_calculateDamageFromContext(
                &mut tc as &mut dyn ITypeCalculator,
                &mut ctx,
                as_u32(&v.inputs[10]),
                as_u32(&v.inputs[11]),
                as_u256(&v.inputs[12]),
                Type::from_u8(as_u8(&v.inputs[13])),
                MoveClass::from_u8(as_u8(&v.inputs[14])),
                as_u256(&v.inputs[15]),
                as_u256(&v.inputs[16]),
            );
            assert_eq!(damage, as_i32(&v.outputs[0]), "{name}[{i}] damage");
            assert_eq!(event, as_b256(&v.outputs[1]), "{name}[{i}] eventType");
        });
    });
}

// ---------------------------------------------------------------------------

#[test]
fn statboost_pack() {
    for_each(&["statboost_pack"], |name, i, v| {
        run_vector(name, i, v, || {
            let mut a = applies(&v.inputs[2]);
            let out = StatBoostLib::packBoostData(as_u256(&v.inputs[0]), as_bool(&v.inputs[1]), &mut a);
            assert_eq!(out, as_b256(&v.outputs[0]), "{name}[{i}]");
        });
    });
}

#[test]
fn statboost_unpack() {
    for_each(&["statboost_unpack"], |name, i, v| {
        run_vector(name, i, v, || {
            let (perm, key, pct, cnt, mul) = StatBoostLib::unpackBoostData(as_b256(&v.inputs[0]));
            assert_eq!(perm, as_bool(&v.outputs[0]), "{name}[{i}] perm");
            assert_eq!(key, as_u256(&v.outputs[1]), "{name}[{i}] key");
            assert_eq!(pct, u8x5(&v.outputs[2]), "{name}[{i}] percents");
            assert_eq!(cnt, u8x5(&v.outputs[3]), "{name}[{i}] counts");
            assert_eq!(mul, boolx5(&v.outputs[4]), "{name}[{i}] isMul");
        });
    });
}

#[test]
fn statboost_pack_arrays() {
    for_each(&["statboost_pack_arrays"], |name, i, v| {
        run_vector(name, i, v, || {
            let mut pct = u8x5(&v.inputs[2]);
            let mut cnt = u8x5(&v.inputs[3]);
            let mut mul = boolx5(&v.inputs[4]);
            let out = StatBoostLib::packBoostDataWithArrays(
                as_u256(&v.inputs[0]), as_bool(&v.inputs[1]), &mut pct, &mut cnt, &mut mul,
            );
            assert_eq!(out, as_b256(&v.outputs[0]), "{name}[{i}]");
        });
    });
}

#[test]
fn statboost_accumulate_finalize() {
    for_each(&["statboost_accumulate", "spec_accumulate_wrap"], |name, i, v| {
        run_vector(name, i, v, || {
            let mut base = u32x5(&v.inputs[0]);
            let mut num = [0u32; 5];
            let mut acc = [U256::ZERO; 5];
            for source in arr(&v.inputs[1]) {
                let s = arr(source);
                let mut pct = u8x5(&s[0]);
                let mut cnt = u8x5(&s[1]);
                let mut mul = boolx5(&s[2]);
                StatBoostLib::accumulateBoosts(
                    &mut base, &mut pct, &mut cnt, &mut mul, &mut num, &mut acc,
                );
            }
            let mut a = applies(&v.inputs[2]);
            StatBoostLib::accumulateBoostsToApply(&mut base, &mut a, &mut num, &mut acc);
            let finalized = StatBoostLib::finalizeBoostedStats(&mut base, &mut num, &mut acc);
            // Revert vectors carry no outputs; indexing them would panic and
            // SATISFY the revert expectation, masking a non-trapping engine.
            if !v.reverts {
                assert_eq!(finalized, u32x5(&v.outputs[0]), "{name}[{i}] final");
                assert_eq!(num, u32x5(&v.outputs[1]), "{name}[{i}] numBoosts");
                assert_eq!(acc, u256x5(&v.outputs[2]), "{name}[{i}] accumulated");
            }
        });
    });
}

#[test]
fn statboost_merge() {
    for_each(&["statboost_merge"], |name, i, v| {
        run_vector(name, i, v, || {
            let mut ep = u8x5(&v.inputs[0]);
            let mut ec = u8x5(&v.inputs[1]);
            let mut em = boolx5(&v.inputs[2]);
            let mut a = applies(&v.inputs[3]);
            let (mp, mc, mm) =
                StatBoostLib::mergeExistingAndNewBoosts(&mut ep, &mut ec, &mut em, &mut a);
            assert_eq!(mp, u8x5(&v.outputs[0]), "{name}[{i}] percents");
            assert_eq!(mc, u8x5(&v.outputs[1]), "{name}[{i}] counts");
            assert_eq!(mm, boolx5(&v.outputs[2]), "{name}[{i}] isMul");
        });
    });
}

#[test]
fn statboost_key() {
    for_each(&["statboost_key"], |name, i, v| {
        run_vector(name, i, v, || {
            let out = StatBoostLib::generateKeyNoSalt(
                as_u256(&v.inputs[0]), as_u256(&v.inputs[1]), as_address(&v.inputs[2]),
            );
            assert_eq!(out, as_u256(&v.outputs[0]), "{name}[{i}]");
        });
    });
}

#[test]
fn statboost_stat_index_maps() {
    for_each(&["statboost_stat_index", "spec_stat_index"], |name, i, v| {
        run_vector(name, i, v, || {
            if v.tag == "toMonState" {
                let out = StatBoostLib::statBoostIndexToMonStateIndex(as_u256(&v.inputs[0]));
                if !v.reverts {
                    assert_eq!(out as u8, as_u8(&v.outputs[0]), "{name}[{i}]");
                }
            } else {
                let out = StatBoostLib::monStateIndexToStatBoostIndex(
                    MonStateIndexName::from_u8(as_u8(&v.inputs[0])),
                );
                if !v.reverts {
                    assert_eq!(out, as_u256(&v.outputs[0]), "{name}[{i}]");
                }
            }
        });
    });
}

#[test]
fn statboost_denom_power() {
    for_each(&["statboost_denom_power", "spec_denom_power"], |name, i, v| {
        run_vector(name, i, v, || {
            let out = StatBoostLib::denomPower(as_u256(&v.inputs[0]));
            assert_eq!(out, as_u256(&v.outputs[0]), "{name}[{i}]");
        });
    });
}

// ---------------------------------------------------------------------------

#[test]
fn moveslot_inline_decoding() {
    for_each(&["moveslot_inline", "spec_enum_reverts"], |name, i, v| {
        // Revert vectors are FUNCTION-ATTRIBUTED via the tag: bundling all
        // six decode calls under one catch_unwind would let a regression in
        // one path hide behind another path's panic (a `% 15` mutant on
        // moveType survived the bundled version of this gate).
        if v.reverts {
            let raw = as_u256(&v.inputs[0]);
            let bk = B256::ZERO;
            // Tag dispatch happens OUTSIDE run_vector: an unknown tag must
            // fail the test, not be swallowed as a satisfied revert.
            match v.tag.as_str() {
                "moveType" => run_vector(name, i, v, || {
                    let mut engine = PanicEngine;
                    let _ = MoveSlotLib::moveType(raw, &mut engine, bk);
                }),
                "decodeMeta" => run_vector(name, i, v, || {
                    let mut engine = PanicEngine;
                    let _ = MoveSlotLib::decodeMeta(raw, &mut engine, bk, U256::ZERO, U256::ZERO);
                }),
                other => panic!("{name}[{i}]: unknown revert tag `{other}` — add a dispatch arm"),
            }
            return;
        }
        run_vector(name, i, v, || {
            let raw = as_u256(&v.inputs[0]);
            let bk = B256::ZERO;
            let inline = MoveSlotLib::isInline(raw);
            if v.outputs.len() == 1 {
                // external slot probe: only the flag is asserted (basePower
                // on an external slot reverts by contract)
                assert_eq!(inline, as_bool(&v.outputs[0]), "{name}[{i}] isInline");
                return;
            }
            let mut engine = PanicEngine;
            let base_power = MoveSlotLib::basePower(raw, bk);
            let move_class = MoveSlotLib::moveClass(raw, &mut engine, bk);
            let priority = MoveSlotLib::priority(raw, &mut engine, bk, U256::ZERO);
            let move_type = MoveSlotLib::moveType(raw, &mut engine, bk);
            let stamina = MoveSlotLib::stamina(raw, &mut engine, bk, U256::ZERO, U256::ZERO);
            let meta = MoveSlotLib::decodeMeta(raw, &mut engine, bk, U256::ZERO, U256::ZERO);
            {
                assert_eq!(inline, as_bool(&v.outputs[0]), "{name}[{i}] isInline");
                assert_eq!(base_power, as_u32(&v.outputs[1]), "{name}[{i}] basePower");
                assert_eq!(move_class as u8, as_u8(&v.outputs[2]), "{name}[{i}] moveClass");
                assert_eq!(priority, as_u32(&v.outputs[3]), "{name}[{i}] priority");
                assert_eq!(move_type as u8, as_u8(&v.outputs[4]), "{name}[{i}] moveType");
                assert_eq!(stamina, as_u32(&v.outputs[5]), "{name}[{i}] stamina");
                assert_eq!(meta.moveClass as u8, as_u8(&v.outputs[6]), "{name}[{i}] meta.moveClass");
                assert_eq!(meta.priority, as_u32(&v.outputs[7]), "{name}[{i}] meta.priority");
                assert_eq!(meta.moveType as u8, as_u8(&v.outputs[8]), "{name}[{i}] meta.moveType");
                assert_eq!(meta.stamina, as_u32(&v.outputs[9]), "{name}[{i}] meta.stamina");
                assert_eq!(meta.basePower, as_u32(&v.outputs[10]), "{name}[{i}] meta.basePower");
                assert_eq!(meta.extraDataType as u8, as_u8(&v.outputs[11]), "{name}[{i}] meta.extra");
            }
        });
    });
}

#[test]
fn stamina_pure_predicates() {
    for_each(&["stamina_pure"], |name, i, v| {
        run_vector(name, i, v, || {
            let regen = StaminaRegenLogic::_shouldRegenOnRoundEnd(as_u256(&v.inputs[0]));
            let resting = StaminaRegenLogic::_isRestingMove(as_u8(&v.inputs[1]));
            assert_eq!(regen, as_bool(&v.outputs[0]), "{name}[{i}] regen");
            assert_eq!(resting, as_bool(&v.outputs[1]), "{name}[{i}] resting");
        });
    });
}

#[test]
fn constants_parity() {
    let suite = load_suite("constants_parity");
    let v = &suite.vectors[0];
    assert_eq!(*Constants::MOVE_MISS_EVENT_TYPE, as_b256(&v.outputs[0]), "MOVE_MISS");
    assert_eq!(*Constants::MOVE_CRIT_EVENT_TYPE, as_b256(&v.outputs[1]), "MOVE_CRIT");
    assert_eq!(
        *Constants::MOVE_TYPE_IMMUNITY_EVENT_TYPE,
        as_b256(&v.outputs[2]),
        "MOVE_TYPE_IMMUNITY"
    );
    assert_eq!(Constants::NONE_EVENT_TYPE, as_b256(&v.outputs[3]), "NONE");
    assert_eq!(Constants::PACKED_CLEARED_MON_STATE, as_u256(&v.outputs[4]), "PACKED_CLEARED");
    assert_eq!(
        I256::try_from(Constants::CLEARED_MON_STATE_SENTINEL).unwrap(),
        as_i256(&v.outputs[5]),
        "SENTINEL"
    );
    assert_eq!(Constants::MAX_BATTLE_DURATION, as_u256(&v.outputs[6]), "MAX_BATTLE_DURATION");
    assert_eq!(Constants::STREAK_GRACE_WINDOW, as_u256(&v.outputs[7]), "STREAK_GRACE_WINDOW");
    assert_eq!(U256::from(Constants::MAX_EFFECTS_PER_MON), as_u256(&v.outputs[8]), "MAX_EFFECTS");
}

/// Enum discriminants must match Solidity's sequential numbering exactly.
#[test]
fn enum_discriminants() {
    assert_eq!(Type::Yin as u8, 0);
    assert_eq!(Type::None as u8, 14);
    assert_eq!(MoveClass::Physical as u8, 0);
    assert_eq!(MoveClass::Self_ as u8, 2, "renamed `Self` variant keeps discriminant 2");
    assert_eq!(MoveClass::Other as u8, 3);
    assert_eq!(MonStateIndexName::Hp as u8, 0);
    assert_eq!(MonStateIndexName::Type2 as u8, 10);
    assert_eq!(StatBoostType::Multiply as u8, 0);
    // Out-of-range conversion panics (Solidity Panic 0x21)
    assert!(std::panic::catch_unwind(|| Type::from_u8(15)).is_err());
    assert!(std::panic::catch_unwind(|| MonStateIndexName::from_u8(11)).is_err());
}
