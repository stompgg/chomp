//! Per-decision cost of the doubles search variants — wall time + engine forks
//! (the fork count is the TS-port budget proxy: TS pays ~fixed cost per fork).
//!
//!   cargo run --release -p chomp-strategies --bin sparsecost -- --games 30

use std::path::PathBuf;
use std::time::Instant;

use chomp_strategies::arena::{build_team_mon, draw_team, Wrand};
use chomp_strategies::doubles::{
    pick_side_moves, search_side_moves, search_side_moves_sparse, Difficulty, DoublesEvalW,
    SPARSE_DEFAULT, SPARSE_LEAN,
};
use chomp_strategies::jsrng::derive;
use chomp_strategies::roster::{self, load_roster};
use chomp_strategies::sim::{pack_side, Sim};

fn arg_u(args: &[String], flag: &str, def: u64) -> u64 {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(def)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let games = arg_u(&args, "--games", 30) as usize;
    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    let book = roster::address_book();
    let eval = DoublesEvalW::default();

    let variants: &[&str] = &["d1", "d2", "sparse", "sparse-lean"];
    for &variant in variants {
        let mut times_ms: Vec<f64> = Vec::new();
        let mut forks: Vec<u64> = Vec::new();
        let (mut wins, mut losses) = (0u32, 0u32);
        for g in 0..games {
            let mut trng = Wrand::new(0xabcd_0000 + g as u32);
            let ids0 = draw_team(&roster, &mut trng);
            let ids1 = draw_team(&roster, &mut trng);
            let mon = |id: u32| roster.mons.iter().find(|m| m.id == id).expect("mon id");
            let mut sim = Sim::new_doubles(
                4,
                ids0.iter().map(|&id| build_team_mon(mon(id))).collect(),
                ids1.iter().map(|&id| build_team_mon(mon(id))).collect(),
                ids0.clone(),
                ids1.clone(),
                &book,
            );
            let mut orng = derive(0x5eed + g as u32, 0);
            let mut bitmap = 0u32;
            for _ in 0..300 {
                if sim.winner_index() != 2 {
                    break;
                }
                let bk = sim.battle_key;
                let fc0 = sim.fork_counter();
                let t0 = Instant::now();
                let (b0, b1) = match variant {
                    "d1" => search_side_moves(&mut sim, bk, 1, 1, &eval, &mut bitmap),
                    "d2" => search_side_moves(&mut sim, bk, 1, 2, &eval, &mut bitmap),
                    "sparse" => search_side_moves_sparse(&mut sim, bk, 1, &eval, SPARSE_DEFAULT, &mut bitmap),
                    _ => search_side_moves_sparse(&mut sim, bk, 1, &eval, SPARSE_LEAN, &mut bitmap),
                };
                times_ms.push(t0.elapsed().as_secs_f64() * 1e3);
                forks.push(sim.fork_counter() - fc0);
                let (a0, a1) = pick_side_moves(&mut sim, bk, 0, Difficulty::Medium, &mut orng);
                sim.execute_slot_turn(
                    pack_side(a0.move_index, a0.extra_data, a1.move_index, a1.extra_data, 0),
                    pack_side(b0.move_index, b0.extra_data, b1.move_index, b1.extra_data, 0),
                );
            }
            match sim.winner_index() {
                1 => wins += 1,
                0 => losses += 1,
                _ => {}
            }
        }
        times_ms.sort_by(|a, b| a.total_cmp(b));
        forks.sort();
        let n = times_ms.len().max(1);
        let q = |v: &[f64], p: f64| v[((p * v.len() as f64) as usize).min(v.len().saturating_sub(1))];
        let qf = |v: &[u64], p: f64| v[((p * v.len() as f64) as usize).min(v.len().saturating_sub(1))];
        println!(
            "{variant:<12} {n:>5} decisions · ms mean {:>7.2}  p50 {:>6.2}  p95 {:>7.2}  max {:>8.2} · forks p50 {:>5}  p95 {:>6}  max {:>6} · vs medium {wins}-{losses}",
            times_ms.iter().sum::<f64>() / n as f64,
            q(&times_ms, 0.5),
            q(&times_ms, 0.95),
            q(&times_ms, 1.0),
            qf(&forks, 0.5),
            qf(&forks, 0.95),
            qf(&forks, 1.0),
        );
    }
}
