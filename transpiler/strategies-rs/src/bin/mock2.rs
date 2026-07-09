//! T2 mock-move A/B — loop-driven mock moves (conditional power from live state), no engine edits.
//!   cargo run --release -p chomp-strategies --bin mock2 -- --games 10000

use chomp_strategies::game::StrategyKind;
use chomp_strategies::mock2::{batch1, run_mock_ab, run_mock_ab_with};
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
    let games = arg_u(&args, "--games", 10_000) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let default_threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = arg_u(&args, "--threads", default_threads as u64) as usize;

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);

    let mocks: Vec<_> = batch1();
    let only = arg(&args, "--only");
    // --ceiling runs the A/B under the no-peek pilots (which play the reads/setups the greedy basket
    // ignores), surfacing a conditional/yomi move's upside rather than just its floor.
    let ceiling = args.iter().any(|a| a == "--ceiling");
    eprintln!("mock2: {} moves · {} games/side · {}", mocks.len(), games, if ceiling { "no-peek ceiling" } else { "greedy-basket floor" });
    println!("\n{:<16} {:<10} {:>7} {:>8} {:>8} | {:>8} {:>8}", "move", "mon", "lane", "win%", "Δ win", "KOd/g", "ΔKOd/g");

    let started = std::time::Instant::now();
    for m in &mocks {
        if let Some(ref name) = only {
            if m.name != name {
                continue;
            }
        }
        let replaced = roster.move_name(roster.mons.iter().find(|x| x.name == m.mon).unwrap().id, m.lane as u8);
        let (base, mocked) = if ceiling {
            run_mock_ab_with(&roster, m, games, seed, seed_base, threads, &[(StrategyKind::NoPeekExpect, StrategyKind::NoPeekExpect)])
        } else {
            run_mock_ab(&roster, m, games, seed, seed_base, threads)
        };
        let bg = base.games().max(1) as f64;
        let mg = mocked.games().max(1) as f64;
        let bkod = base.kos_dealt() as f64 / bg;
        let mkod = mocked.kos_dealt() as f64 / mg;
        println!(
            "{:<16} {:<10} {:>7} {:>7.1}% {:>+7.1} | {:>8.2} {:>+7.2}   (replaces {})",
            m.name,
            m.mon,
            m.lane,
            mocked.win_rate() * 100.0,
            (mocked.win_rate() - base.win_rate()) * 100.0,
            mkod,
            mkod - bkod,
            replaced,
        );
    }
    eprintln!("\ndone in {:.1}s", started.elapsed().as_secs_f64());
}
