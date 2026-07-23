//! Per-mon attribution analysis over instrumented 4v4 games (measure.md's de-confounded
//! mon-vs-mon read: active-turns + KOs by opponent-active-slot proxy, split by win/loss).
//!
//!   cargo run --release -p chomp-strategies --bin analyze -- --games 10000 --seed 0xbeefcafe
//!
//! Data (drool/*.csv, src/mons/*.json) is read relative to CHOMP_ROOT.

use chomp_strategies::analysis::{
    run_doubles_mon_analysis, run_mon_analysis, run_mon_analysis_rotated, run_mon_analysis_with,
};
use chomp_strategies::game::StrategyKind;
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

fn short(name: &str) -> String {
    name.chars().take(6).collect()
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
    eprintln!("analyze: {} mons · {} games · {} threads · seed {:#x}", roster.mons.len(), games, threads, seed);

    // Optional pilot override: --p1 <strat> --p0 <strat> runs that single matched-draft matchup
    // (e.g. --p1 nopeek --p0 greedy for the no-peek-vs-peek split). Default = the full basket.
    let p1 = arg(&args, "--p1");
    let p0 = arg(&args, "--p0");

    // --rotate equips a uniform 4-subset of each mon's catalog per drafted slot (default: lanes 0-3).
    let rotate = args.iter().any(|a| a == "--rotate");
    let mode = arg(&args, "--mode").unwrap_or_else(|| "singles".to_string());
    // Doubles only: 0 = epsilon-greedy pilot (damaging moves only), >=1 = maximin search (also
    // enumerates setup moves), so this toggles whether setup mons can be piloted at all.
    let search_depth = arg_u(&args, "--search-depth", 0) as u32;
    if mode == "doubles" && search_depth >= 1 {
        eprintln!("  pilot: doubles maximin search d{search_depth} (setup moves enumerated)");
    }
    if rotate {
        eprintln!("  loadouts: rotated (uniform 4-subset per drafted slot)");
    }

    let started = std::time::Instant::now();
    let a = if mode == "doubles" {
        run_doubles_mon_analysis(&roster, games, seed, seed_base, threads, rotate, search_depth)
    } else {
        match (&p1, &p0) {
            (Some(p1s), Some(p0s)) => {
                let pair = (
                    StrategyKind::parse(p1s).expect("bad --p1 strategy"),
                    StrategyKind::parse(p0s).expect("bad --p0 strategy"),
                );
                eprintln!("  pilots: p1={p1s} vs p0={p0s}");
                if rotate {
                    run_mon_analysis_rotated(&roster, games, seed, seed_base, threads, Some(&[pair]))
                } else {
                    run_mon_analysis_with(&roster, games, seed, seed_base, threads, &[pair])
                }
            }
            _ if rotate => run_mon_analysis_rotated(&roster, games, seed, seed_base, threads, None),
            _ => run_mon_analysis(&roster, games, seed, seed_base, threads),
        }
    };
    let elapsed = started.elapsed().as_secs_f64();

    // Per-mon table, sorted by win rate. KOd = KOs dealt, KOt = KOs taken; (W)/(L) split by game result.
    let mut ids: Vec<u32> = a.per_mon.keys().copied().collect();
    ids.sort_by(|&x, &y| a.per_mon[&y].win_rate().partial_cmp(&a.per_mon[&x].win_rate()).unwrap());

    let attributed = !a.ko_matrix.is_empty();
    if attributed {
        println!(
            "\n{:<12} {:>6} {:>7} | {:>8} {:>7} {:>7} | {:>8} {:>8}",
            "mon", "win%", "games", "act.t/g", "KOd/g", "KOt/g", "KOd/g·W", "KOd/g·L"
        );
    } else {
        println!("\n{:<12} {:>6} {:>7}", "mon", "win%", "games");
    }
    for id in &ids {
        let s = &a.per_mon[id];
        if !attributed {
            println!("{:<12} {:>5.1}% {:>7}", roster.mon_name(*id), s.win_rate() * 100.0, s.games());
            continue;
        }
        let g = s.games().max(1) as f64;
        let wg = s.games_won.max(1) as f64;
        let lg = s.games_lost.max(1) as f64;
        println!(
            "{:<12} {:>5.1}% {:>7} | {:>8.2} {:>7.2} {:>7.2} | {:>8.2} {:>8.2}",
            roster.mon_name(*id),
            s.win_rate() * 100.0,
            s.games(),
            s.active_turns() as f64 / g,
            s.kos_dealt() as f64 / g,
            s.kos_taken() as f64 / g,
            s.kos_dealt_won as f64 / wg,
            s.kos_dealt_lost as f64 / lg,
        );
    }

    // Mon-vs-mon KO matrix (row KOs col), raw attributed counts.
    if a.ko_matrix.is_empty() {
        println!("\nKO matrix: n/a (no attributed KOs)");
    } else {
        println!("\nKO matrix (row mon KOs column mon — attributed counts):");
        print!("{:<9}", "");
        for id in &ids {
            print!("{:>7}", short(&roster.mon_name(*id)));
        }
        println!();
        for kid in &ids {
            print!("{:<9}", short(&roster.mon_name(*kid)));
            for vid in &ids {
                if kid == vid {
                    print!("{:>7}", "·");
                } else {
                    print!("{:>7}", a.ko_matrix.get(&(*kid, *vid)).copied().unwrap_or(0));
                }
            }
            println!();
        }
    }

    // Doubles credits a KO from the killer side's target nibble, so state the coverage rather than
    // letting the matrix read as the full KO count.
    if a.ko_shared > 0 || a.ko_incidental > 0 {
        let credited: u32 = a.ko_matrix.values().sum();
        let total = credited + a.ko_shared + a.ko_incidental;
        println!(
            "\nKO attribution: {credited} credited ({:.0}%) · {} co-kills (both slots aimed) · {} incidental (status/recoil)",
            100.0 * credited as f64 / total.max(1) as f64,
            a.ko_shared,
            a.ko_incidental
        );
    }

    eprintln!(
        "\n{} games in {:.2}s ({:.0} games/s) · decided {} · draws {} · errors {}",
        a.games, elapsed, a.games as f64 / elapsed, a.decided, a.draws, a.errors
    );
}
