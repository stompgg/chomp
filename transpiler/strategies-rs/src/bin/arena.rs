//! Pure-Rust arena runner — replaces `bun transpiler/scripts/batch_benchmark.ts`.
//!
//!   cargo run --release -p chomp-strategies --bin arena -- --games 600 --seed 0xbeefcafe
//!
//! Data (drool/*.csv, src/mons/*.json) is read relative to CHOMP_ROOT (default: the repo root
//! inferred from the crate location).

use chomp_strategies::arena::{run_arena, run_doubles_arena};
use chomp_strategies::roster::load_roster;
use std::path::PathBuf;

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
