//! Not a benchmark harness — a smoke measurement mirroring the FFI spike:
//! run the damage core over a deterministic sweep and report ns/call.
//! Run with: cargo test -p chomp-differential --release bench_smoke -- --nocapture --ignored
use chomp_engine::Enums::{MoveClass, Type};
use chomp_engine::Structs::DamageCalcContext;
use chomp_engine::moves::AttackCalculator;
use chomp_rt::U256;

#[test]
#[ignore]
fn bench_smoke_damage_core() {
    let mut ctx = DamageCalcContext {
        attackerMonIndex: 0,
        defenderMonIndex: 0,
        attackerAttack: 250,
        attackerAttackDelta: 40,
        attackerSpAtk: 180,
        attackerSpAtkDelta: -20,
        defenderDef: 210,
        defenderDefDelta: 10,
        defenderSpDef: 160,
        defenderSpDefDelta: 0,
        defenderType1: Type::Fire,
        defenderType2: Type::None,
    };
    let n: u64 = 1_000_000;
    let start = std::time::Instant::now();
    let mut acc: i64 = 0;
    for i in 0..n {
        let h = U256::from(i).wrapping_mul(U256::from_limbs([
            0x9e3779b97f4a7c15, 0xdeadbeefcafebabe, 1, 7,
        ]));
        let (dmg, _ev) = AttackCalculator::_calculateDamageCore(
            &mut ctx, 80, MoveClass::Physical, U256::from(10u8), h, U256::from(5u8),
        );
        acc += dmg as i64;
    }
    let elapsed = start.elapsed();
    println!(
        "damage core: {n} iters in {:?} ({:.1} ns/call), checksum {acc}",
        elapsed,
        elapsed.as_nanos() as f64 / n as f64
    );
}
