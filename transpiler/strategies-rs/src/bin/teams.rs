//! Team search + synergy — every 4-mon team vs the random field, plus interaction-beyond-main-effects.
//!   cargo run --release -p chomp-strategies --bin teams -- --games-per-team 300

use chomp_strategies::roster::load_roster;
use chomp_strategies::teams::{run_team_search, synergy};
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
    let gpt = arg_u(&args, "--games-per-team", 300) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 500_000) as u32;
    let default_threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = arg_u(&args, "--threads", default_threads as u64) as usize;

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    let team_str = |t: &[u32]| t.iter().map(|&id| roster.mon_name(id)).collect::<Vec<_>>().join(", ");

    let started = std::time::Instant::now();
    let mut results = run_team_search(&roster, gpt, seed, seed_base, threads);
    let syn = synergy(&results);
    let elapsed = started.elapsed().as_secs_f64();

    eprintln!("teams: {} teams · {} games each vs random field · {:.1}s", results.len(), gpt, elapsed);

    results.sort_by(|a, b| b.win_rate().partial_cmp(&a.win_rate()).unwrap());
    println!("\nTop 12 teams vs the random field:");
    for r in results.iter().take(12) {
        println!("  {:>5.1}%   {}", r.win_rate() * 100.0, team_str(&r.team));
    }
    println!("\nBottom 5 teams:");
    for r in results.iter().rev().take(5) {
        println!("  {:>5.1}%   {}", r.win_rate() * 100.0, team_str(&r.team));
    }

    // Main effects (each mon's average lift over the field).
    let mut mains: Vec<(u32, f64)> = syn.main.iter().map(|(&m, &v)| (m, v)).collect();
    mains.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    println!("\nMain effect (avg team-winrate lift when present, overall {:.1}%):", syn.overall * 100.0);
    for (m, v) in &mains {
        println!("  {:<12} {:+.1} pts", roster.mon_name(*m), v * 100.0);
    }

    // Top synergy pairs (interaction beyond main effects).
    let mut inter: Vec<((u32, u32), f64)> = syn.interaction.iter().map(|(&k, &v)| (k, v)).collect();
    inter.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    println!("\nTop 10 synergy pairs (interaction beyond main effects):");
    for ((a, b), v) in inter.iter().take(10) {
        println!("  {:+.1} pts   {} + {}", v * 100.0, roster.mon_name(*a), roster.mon_name(*b));
    }

    // Validation: Overclock (Volthare) lifting slower attackers — Volthare's interaction with the
    // slow bulky attackers should skew positive.
    if let Some(vid) = roster.mons.iter().find(|m| m.name == "Volthare").map(|m| m.id) {
        println!("\n[validation] Volthare (Overclock) interaction with slower attackers:");
        for slow in ["Aurox", "Gorillax", "Pengym", "Nirvamma"] {
            if let Some(sid) = roster.mons.iter().find(|m| m.name == slow).map(|m| m.id) {
                let key = (vid.min(sid), vid.max(sid));
                if let Some(v) = syn.interaction.get(&key) {
                    println!("  Volthare + {:<9} {:+.1} pts", slow, v * 100.0);
                }
            }
        }
    }
}
