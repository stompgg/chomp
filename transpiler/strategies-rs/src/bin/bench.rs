//! Score a bot against the baseline ladder.
//!
//!   cargo run --release -p chomp-strategies --bin bench -- --bot greedy
//!   cargo run --release -p chomp-strategies --bin bench -- --bot mybot --mode doubles
//!
//! Every row draws independent drafts and alternates which seat the candidate
//! pilots, because the seats are not perfectly symmetric; and every row prints
//! its own draft count and 95% interval, because a deep bot's row is
//! necessarily thinner than a shallow one's.
//!
//! Data (drool/*.csv, src/mons/*.json) is read relative to CHOMP_ROOT.

use chomp_strategies::arena::{bench_doubles, bench_singles, BenchRow};
use chomp_strategies::bot::InfoMode;
use chomp_strategies::bots;
use chomp_strategies::roster::load_roster;
use std::path::PathBuf;

/// The published singles ladder, weakest first.
const SINGLES_LADDER: &[&str] = &[
    bots::RANDOM,
    bots::GREEDY,
    bots::HEURISTIC,
    bots::OVERRIDE,
    bots::NOPEEK,
    bots::SEARCH_D1,
];

/// The published doubles ladder, weakest first.
const DOUBLES_LADDER: &[&str] =
    &[bots::DOUBLES_EASY, bots::DOUBLES_MEDIUM, bots::DOUBLES_HARD, bots::DOUBLES_SEARCH_D1];

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

fn print_rows(bot: &str, rows: &[BenchRow], elapsed: f64) {
    println!("\n{:>18}  {:>7}  {:>8}  {:>13}  {:>12}", "opponent", "drafts", "win%", "95% CI", "w-l-draw");
    for r in rows {
        println!(
            "{:>18}  {:>7}  {:>7.1}%  ±{:>11.1}%  {:>4}-{:>3}-{:<4}",
            r.opponent,
            r.drafts,
            r.win_rate() * 100.0,
            r.ci95() * 100.0,
            r.wins,
            r.losses,
            r.draws
        );
    }
    let beat: Vec<&str> =
        rows.iter().filter(|r| r.win_rate() - r.ci95() > 0.5).map(|r| r.opponent).collect();
    println!();
    if beat.is_empty() {
        println!("{bot} does not clear 50% against any ladder bot (beyond its interval).");
    } else {
        println!("{bot} beats: {}", beat.join(", "));
    }
    eprintln!("\n{elapsed:.2}s");
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bot = arg(&args, "--bot").unwrap_or_else(|| {
        eprintln!("usage: bench --bot <name> [--mode singles|doubles] [--games N] [--info blind|rotate]");
        eprintln!("registered singles bots: {}", bots::NAMES.join(", "));
        eprintln!("registered doubles bots: {}", bots::DOUBLES_NAMES.join(", "));
        std::process::exit(2);
    });
    let bot = bots::parse(&bot).unwrap_or_else(|| {
        eprintln!("unknown bot {bot:?}; registered: {}", bots::NAMES.join(", "));
        std::process::exit(2);
    });

    let mode = arg(&args, "--mode").unwrap_or_else(|| "singles".to_string());
    let games = arg_u(&args, "--games", 2000) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let default_threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = arg_u(&args, "--threads", default_threads as u64) as usize;
    let info = arg(&args, "--info")
        .map(|v| InfoMode::parse(&v).expect("--info: blind | rotate | cand"))
        .unwrap_or(InfoMode::Blind);

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);

    let started = std::time::Instant::now();
    let rows = if mode == "doubles" {
        eprintln!("bench[doubles]: {bot} · {games} games/opponent · seed {seed:#x}");
        bench_doubles(&roster, bot, DOUBLES_LADDER, games, seed, seed_base, threads)
    } else {
        eprintln!("bench[singles/{}]: {bot} · {games} games/opponent · seed {seed:#x}", info.label());
        bench_singles(&roster, bot, SINGLES_LADDER, games, seed, seed_base, threads, info)
    };
    print_rows(bot, &rows, started.elapsed().as_secs_f64());
}
