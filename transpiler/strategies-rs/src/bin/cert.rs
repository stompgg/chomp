//! Certification suite (measure.md's bounding instrument) — known-answer checks scored after any
//! pilot / forward-model change; the globalKV class of bug fails it instantly instead of costing
//! half a pass. Exits nonzero on failure (CI-usable). The depth-3 munch referee is a separate
//! bounding instrument (a follow-up port).
//!   cargo run --release -p chomp-strategies --bin cert

use chomp_strategies::analysis::run_mon_analysis;
use chomp_strategies::arena::build_team_mon;
use chomp_strategies::game::{play_game, GameSpec, StrategyKind};
use chomp_strategies::matrix::compute_static_matrix;
use chomp_strategies::roster::{self, load_roster};
use std::path::PathBuf;

fn main() {
    let default_threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    let book = roster::address_book();
    let mut fails = 0;

    // Check 1 — globalKV-class regression: fixed-model pilots draw ~never and never error. The
    // globalKV forward-model bug manifested as stall-loop draws (50–167 per 2000 pre-fix).
    let a = run_mon_analysis(&roster, 4000, 0xbeefcafe, 10_000, default_threads);
    let draw_rate = a.draws as f64 / a.games.max(1) as f64;
    let ok1 = draw_rate < 0.01 && a.errors == 0;
    println!("[1] draw rate {:.3}% (<1%), errors {} (0): {}", draw_rate * 100.0, a.errors, if ok1 { "PASS" } else { "FAIL" });
    if !ok1 {
        fails += 1;
    }

    // Check 2 — OHKO conversion: where the static matrix says the attacker OHKOs and the defender
    // needs ≥3 to KO back (a clear KO-race advantage), the attacker must win the 1v1.
    let m = compute_static_matrix(&roster);
    let (mut checked, mut won) = (0u32, 0u32);
    for i in 0..m.n() {
        for j in 0..m.n() {
            if i == j {
                continue;
            }
            if m.turns_to_ko[i][j] == 1 && m.turns_to_ko[j][i] >= 3 {
                let spec = GameSpec {
                    seed: 12345,
                    max_turns: 50,
                    mons_per_team: 1,
                    p0_team: vec![build_team_mon(&roster.mons[j])],
                    p1_team: vec![build_team_mon(&roster.mons[i])],
                    p0_ids: vec![m.ids[j]],
                    p1_ids: vec![m.ids[i]],
                    p0_strategy: StrategyKind::Greedy,
                    p1_strategy: StrategyKind::Greedy,
                };
                let o = play_game(&spec, &book, false);
                checked += 1;
                if o.winner_seat == Some(1) {
                    won += 1;
                }
            }
        }
    }
    let rate = if checked == 0 { 1.0 } else { won as f64 / checked as f64 };
    let ok2 = rate >= 0.9;
    println!("[2] OHKO conversion: {}/{} clear-advantage 1v1s won by attacker ({:.0}%, ≥90%): {}", won, checked, rate * 100.0, if ok2 { "PASS" } else { "FAIL" });
    if !ok2 {
        fails += 1;
    }

    if fails == 0 {
        println!("\nCERT PASS");
    } else {
        println!("\nCERT FAIL ({fails} check(s))");
        std::process::exit(3);
    }
}
