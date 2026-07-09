//! Mock T1 overlay A/B — counterfactual win-rate change from a parameter tweak on matched drafts.
//!   cargo run --release -p chomp-strategies --bin mock -- --mon Xmon --lane 1 --power 80 --games 10000

use chomp_strategies::mock::{lane_is_inline, run_mock_ab, MoveOverride};
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

    let mon = arg(&args, "--mon").expect("--mon <name> required");
    let lane = arg_u(&args, "--lane", 0) as usize;
    let ov = MoveOverride {
        base_power: arg(&args, "--power").map(|v| v.parse().unwrap()),
        stamina: arg(&args, "--stamina").map(|v| v.parse().unwrap()),
        effect_accuracy: arg(&args, "--acc").map(|v| v.parse().unwrap()),
        priority: arg(&args, "--priority").map(|v| v.parse().unwrap()),
    };

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    let target = roster.mons.iter().find(|m| m.name == mon).expect("mon name in roster").id;
    let move_name = roster.move_name(target, lane as u8);

    eprintln!("mock: {} lane {} ({}) · {} games/side · seed {:#x}", mon, lane, move_name, games, seed);
    if !lane_is_inline(&roster, target, lane) {
        eprintln!("  WARNING: {move_name} is a deployed (address-word) move — the overlay is inert; needs a T2 mock.");
    }

    let started = std::time::Instant::now();
    let (base, overlaid) = run_mock_ab(&roster, games, seed, seed_base, threads, target, lane, ov);
    let elapsed = started.elapsed().as_secs_f64();

    println!("\n{} — {} overlay {:?}", mon, move_name, ov);
    println!("  baseline : win {:>5.1}%   KOd/g {:>4.2}   act.t/g {:>5.2}", base.win_rate() * 100.0, base.kos_dealt() as f64 / base.games().max(1) as f64, base.active_turns() as f64 / base.games().max(1) as f64);
    println!("  overlaid : win {:>5.1}%   KOd/g {:>4.2}   act.t/g {:>5.2}", overlaid.win_rate() * 100.0, overlaid.kos_dealt() as f64 / overlaid.games().max(1) as f64, overlaid.active_turns() as f64 / overlaid.games().max(1) as f64);
    println!("  Δ win    : {:+.1} pts", (overlaid.win_rate() - base.win_rate()) * 100.0);

    eprintln!("\n2×{} games in {:.2}s", games, elapsed);
}
