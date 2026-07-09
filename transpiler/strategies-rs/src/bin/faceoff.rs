//! Face-off analysis — measure.md's behavioral half (who leaves first per matchup).
//!   cargo run --release -p chomp-strategies --bin faceoff -- --games 10000

use chomp_strategies::faceoff::run_faceoff_analysis;
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
fn short(s: &str) -> String {
    s.chars().take(6).collect()
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
    eprintln!("faceoff: {} mons · {} games · {} threads · seed {:#x}", roster.mons.len(), games, threads, seed);

    let started = std::time::Instant::now();
    let m = run_faceoff_analysis(&roster, games, seed, seed_base, threads);
    let elapsed = started.elapsed().as_secs_f64();

    let ids: Vec<u32> = roster.mons.iter().map(|x| x.id).collect();
    let n = ids.len();
    let name = |k: usize| roster.mon_name(ids[k]);

    // "Leaves first" rate: row mon leaves first vs column mon (higher = column walls/checks row).
    println!("\nFace-off leave-first rate (row mon leaves first vs column mon; blank = never met):");
    print!("{:<9}", "");
    for j in 0..n {
        print!("{:>7}", short(&name(j)));
    }
    println!();
    for i in 0..n {
        print!("{:<9}", short(&name(i)));
        for j in 0..n {
            if i == j {
                print!("{:>7}", "·");
                continue;
            }
            match m.leave_rate(ids[i], ids[j]) {
                Some(r) => print!("{:>6.0}%", r * 100.0),
                None => print!("{:>7}", "-"),
            }
        }
        println!();
    }

    // Calibration: Xmon walls Malalien — Malalien should leave first vs Xmon more than the reverse.
    let idx = |nm: &str| (0..n).find(|&k| name(k) == nm);
    if let (Some(x), Some(mal)) = (idx("Xmon"), idx("Malalien")) {
        let mal_leaves = m.leave_rate(ids[mal], ids[x]);
        let xmon_leaves = m.leave_rate(ids[x], ids[mal]);
        let walls = matches!((mal_leaves, xmon_leaves), (Some(a), Some(b)) if a > b && a > 0.5);
        println!("\n[calibration] Xmon walls Malalien: {}", if walls { "YES ✓" } else { "NO ✗" });
        println!(
            "  Malalien leaves first vs Xmon = {}, Xmon leaves first vs Malalien = {} (wall wants the former higher, >50%)",
            mal_leaves.map(|r| format!("{:.0}%", r * 100.0)).unwrap_or("n/a".into()),
            xmon_leaves.map(|r| format!("{:.0}%", r * 100.0)).unwrap_or("n/a".into()),
        );
    }

    eprintln!(
        "\n{} face-offs from {} games in {:.2}s ({:.0} games/s) · errors {}",
        m.faceoffs, games, elapsed, games as f64 / elapsed, m.errors
    );
}
