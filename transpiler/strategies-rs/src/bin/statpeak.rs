//! Distribution of the largest combat stat any mon reaches — stat boosts are multiplicative and
//! stack per source, and MAX_BOOSTED_STAT lets one reach int32::max.
//!   cargo run --release -p chomp-strategies --bin statpeak -- --games 20000

use chomp_strategies::arena::{build_specs, build_specs_full, STRAT_PAIRS};
use chomp_strategies::game::{run_games_instrumented, StrategyKind};
use chomp_strategies::roster::{self, load_roster};
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
    let games = arg_u(&args, "--games", 20_000) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let rotate = args.iter().any(|a| a == "--rotate");

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    let book = roster::address_book();
    let pairs: Vec<(StrategyKind, StrategyKind)> = STRAT_PAIRS
        .iter()
        .map(|&(p1, p0)| (StrategyKind::parse(p1).unwrap(), StrategyKind::parse(p0).unwrap()))
        .collect();
    let (specs, _) = if rotate {
        build_specs_full(&roster, games, seed, seed_base, &pairs, true)
    } else {
        build_specs(&roster, games, seed, seed_base)
    };
    let recs = run_games_instrumented(&specs, &book, 8);

    let mut peaks: Vec<(i64, u32)> = recs.iter().filter_map(|r| r.as_ref().ok()).map(|r| (r.peak_stat, r.peak_stat_mon)).collect();
    peaks.sort_by_key(|p| p.0);
    let n = peaks.len();
    let pct = |q: f64| peaks[((n as f64 - 1.0) * q) as usize];
    println!("\npeak combat stat per game ({n} games)");
    for (lbl, q) in [("p50", 0.50), ("p90", 0.90), ("p99", 0.99), ("p99.9", 0.999)] {
        println!("  {lbl:>6}  {:>16}", pct(q).0);
    }
    let (mx, mon) = peaks[n - 1];
    println!("  {:>6}  {:>16}   ({})", "max", mx, roster.mon_name(mon));

    const I32MAX: i64 = 2_147_483_647;
    for thresh in [10_000i64, 1_000_000, 100_000_000, I32MAX] {
        let c = peaks.iter().filter(|p| p.0 >= thresh).count();
        println!("  games with a stat >= {thresh:>13}: {c:>6}  ({:.3}%)", 100.0 * c as f64 / n as f64);
    }
    // Which mon holds the peak in the most extreme games.
    let mut worst: Vec<(i64, u32)> = peaks.iter().rev().take(200).copied().collect();
    worst.sort_by_key(|p| p.1);
    let mut counts: std::collections::HashMap<u32, usize> = std::collections::HashMap::new();
    for (_, m) in &worst { *counts.entry(*m).or_default() += 1; }
    let mut cv: Vec<_> = counts.into_iter().collect();
    cv.sort_by_key(|c| std::cmp::Reverse(c.1));
    println!("\n  peak holder in the 200 most extreme games:");
    for (m, c) in cv.iter().take(6) {
        println!("    {:<12} {c:>4}", roster.mon_name(*m));
    }
}
