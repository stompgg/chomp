//! Yomi analysis — per-mon decision tension (EVPI over the no-peek grid).
//!   cargo run --release -p chomp-strategies --bin yomi -- --games 2000

use chomp_strategies::roster::load_roster;
use chomp_strategies::yomi::run_yomi_analysis;
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
    let games = arg_u(&args, "--games", 2000) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let default_threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = arg_u(&args, "--threads", default_threads as u64) as usize;
    let threshold = arg_u(&args, "--threshold", 20) as f64; // eval-score units of tension

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    eprintln!("yomi: {} mons · {} games · {} threads · tension≥{}", roster.mons.len(), games, threads, threshold);

    let started = std::time::Instant::now();
    let a = run_yomi_analysis(&roster, games, seed, seed_base, threads, threshold);
    let elapsed = started.elapsed().as_secs_f64();

    let mut ids: Vec<u32> = a.per_mon.keys().copied().collect();
    ids.sort_by(|&x, &y| a.per_mon[&y].mean().partial_cmp(&a.per_mon[&x].mean()).unwrap());

    println!("\nPer-mon yomi tension (mean EVPI over its two-sided decisions; high-rate = share ≥ {}):", a.threshold as i64);
    println!("{:<12} {:>10} {:>10} {:>9}", "mon", "mean EVPI", "high-rate", "samples");
    for id in &ids {
        let s = &a.per_mon[id];
        println!("{:<12} {:>10.1} {:>9.0}% {:>9}", roster.mon_name(*id), s.mean(), s.high_rate() * 100.0, s.samples);
    }

    eprintln!("\n{} yomi samples from {} games in {:.2}s ({:.0} games/s)", a.total_samples, games, elapsed, games as f64 / elapsed);
}
