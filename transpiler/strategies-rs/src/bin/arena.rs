//! Pure-Rust arena runner — replaces `bun transpiler/scripts/batch_benchmark.ts`.
//!
//!   cargo run --release -p chomp-strategies --bin arena -- --games 600 --seed 0xbeefcafe
//!
//! Data (drool/*.csv, src/mons/*.json) is read relative to CHOMP_ROOT (default: the repo root
//! inferred from the crate location).

use chomp_strategies::arena::{
    doubles_ab_winrate, doubles_search_winrate, eval_weights_winrate, run_arena, run_doubles_arena, DoublesSideCfg,
};
use chomp_strategies::doubles::DoublesEvalW;
use chomp_strategies::evaluator::{Weights, DEFAULT_WEIGHTS, N_FEATURES};
use chomp_strategies::game::StrategyKind;
use chomp_strategies::roster::load_roster;
use std::path::PathBuf;

/// Parse a comma-separated candidate weight vector (exactly `N_FEATURES` floats).
fn parse_weights(s: &str) -> Weights {
    let vals: Vec<f64> = s
        .split(',')
        .map(|x| x.trim().parse::<f64>().expect("--weights: each entry must be a float"))
        .collect();
    assert_eq!(vals.len(), N_FEATURES, "--weights: expected {N_FEATURES} comma-separated values");
    let mut w = [0.0f64; N_FEATURES];
    w.copy_from_slice(&vals);
    w
}

fn arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}
fn arg_u(args: &[String], flag: &str, def: u64) -> u64 {
    match arg(args, flag) {
        Some(v) if v.starts_with("0x") => u64::from_str_radix(&v[2..], 16).unwrap_or(def),
        Some(v) => v.parse().unwrap_or(def),
        None => def,
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let games = arg_u(&args, "--games", 600) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let default_threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = arg_u(&args, "--threads", default_threads as u64) as usize;

    let mode = arg(&args, "--mode").unwrap_or_else(|| "singles".to_string());

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });

    let roster = load_roster(&chomp_root);
    eprintln!("arena[{mode}]: {} mons · {} games · {} threads · seed {:#x}", roster.mons.len(), games, threads, seed);

    // A/B a candidate linear weight vector vs the frozen baseline. `--search-depth N` (≥1) makes p1
    // play no-peek maximin search at depth N over the weights; 0 = 1-ply greedy over them.
    let search_depth = arg_u(&args, "--search-depth", 0) as u32;
    let peek = args.iter().any(|a| a == "--peek"); // peek-at-root best-response for the search seat

    // Doubles eval-weight A/B: candidate (side flags below) vs the default-weight baseline, both
    // searching. Same teams/seats per pair with configs exchanged, so only the config differs.
    //   --mode doubles-ab [--depth N] [--base-depth N] [--wboost F] [--wstatus F] [--wskip F] [--gateko]
    if mode == "doubles-ab" {
        let argf = |flag: &str, def: f64| arg(&args, flag).map(|v| v.parse().expect("float flag")).unwrap_or(def);
        let depth = arg_u(&args, "--depth", 1) as u32;
        let base_depth = arg_u(&args, "--base-depth", depth as u64) as u32;
        let eval = DoublesEvalW {
            w_boost: argf("--wboost", 0.0),
            w_status: argf("--wstatus", 0.0),
            w_skip: argf("--wskip", 0.0),
            gate_ko: args.iter().any(|a| a == "--gateko"),
            ..DoublesEvalW::default()
        };
        let cand = DoublesSideCfg { depth, eval, ..Default::default() };
        let base = DoublesSideCfg { depth: base_depth, ..Default::default() };
        let started = std::time::Instant::now();
        let r = doubles_ab_winrate(&roster, cand, base, games, seed, seed_base, threads);
        let elapsed = started.elapsed().as_secs_f64();
        println!(
            "cand d{depth} boost={} status={} skip={} gateko={}  vs  base d{base_depth} default  ·  {} games  ·  win {:.1}%  ({}-{}-{} draws)",
            eval.w_boost, eval.w_status, eval.w_skip, eval.gate_ko, games, r.share * 100.0, r.cand_wins, r.base_wins, r.draws
        );
        eprintln!("{games} games in {elapsed:.2}s ({:.0} games/s)", games as f64 / elapsed);
        return;
    }

    // Doubles maximin search vs the epsilon-greedy Hard baseline (Phase-3 substrate check).
    if mode == "doubles" && search_depth >= 1 {
        let started = std::time::Instant::now();
        let wr = doubles_search_winrate(&roster, search_depth, games, seed, seed_base, threads);
        let elapsed = started.elapsed().as_secs_f64();
        println!("doubles d{search_depth}-search (side1)  vs  Hard (side0)  ·  {games} games  ·  win {:.1}%", wr * 100.0);
        eprintln!("{games} games in {elapsed:.2}s ({:.0} games/s)", games as f64 / elapsed);
        return;
    }

    let cand: Option<(&str, Weights)> = if let Some(wstr) = arg(&args, "--weights") {
        Some(("weights", parse_weights(&wstr)))
    } else if search_depth >= 1 {
        Some(("default", DEFAULT_WEIGHTS)) // validate the search itself
    } else {
        None
    };
    if let Some((label, cand)) = cand {
        let started = std::time::Instant::now();
        let wr = eval_weights_winrate(
            &roster, &cand, search_depth, peek, StrategyKind::Greedy, StrategyKind::Greedy, games, seed, seed_base, threads,
        );
        let elapsed = started.elapsed().as_secs_f64();
        let m = if search_depth >= 1 { format!("d{search_depth}-search") } else { "1-ply".to_string() };
        println!("{label} ({m}) p1  vs  greedy(default) p0  ·  {games} games  ·  win {:.1}%", wr * 100.0);
        eprintln!("{games} games in {elapsed:.2}s ({:.0} games/s)", games as f64 / elapsed);
        return;
    }

    let started = std::time::Instant::now();
    println!("\n{:>9}  {:>9}  {:>6}  {:>8}  {:>12}", "p1", "p0", "games", "p1 win%", "w-l-draw");
    if mode == "doubles" {
        for s in &run_doubles_arena(&roster, games, seed, seed_base, threads) {
            println!(
                "{:>9}  {:>9}  {:>6}  {:>6.1}%  {:>4}-{:>3}-{:<4}",
                s.p1_diff.label(), s.p0_diff.label(), s.games, s.p1_rate() * 100.0, s.p1_wins, s.p0_wins, s.draws
            );
        }
    } else {
        for s in &run_arena(&roster, games, seed, seed_base, threads) {
            println!(
                "{:>9}  {:>9}  {:>6}  {:>6.1}%  {:>4}-{:>3}-{:<4}",
                s.p1_strat, s.p0_strat, s.games, s.p1_rate() * 100.0, s.p1_wins, s.p0_wins, s.draws
            );
        }
    }
    let elapsed = started.elapsed().as_secs_f64();
    eprintln!("\n{} games in {:.2}s ({:.0} games/s)", games, elapsed, games as f64 / elapsed);
}
