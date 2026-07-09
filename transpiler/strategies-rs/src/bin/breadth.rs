//! Breadth + close-call analysis (measure.md's decisions lens: dominance / dead-slot / close calls).
//!   cargo run --release -p chomp-strategies --bin breadth -- --games 4000

use chomp_strategies::breadth::run_breadth_analysis;
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
    let games = arg_u(&args, "--games", 4000) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let default_threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = arg_u(&args, "--threads", default_threads as u64) as usize;

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    eprintln!("breadth: {} mons · {} games · {} threads (greedy driver)", roster.mons.len(), games, threads);

    let started = std::time::Instant::now();
    let a = run_breadth_analysis(&roster, games, seed, seed_base, threads);
    let elapsed = started.elapsed().as_secs_f64();

    // Per-mon: dominance, close-call rate, then each move lane's use% and dead-slot margin.
    let mut ids: Vec<u32> = a.per_mon.keys().copied().collect();
    ids.sort_by(|&x, &y| a.per_mon[&y].dominance().partial_cmp(&a.per_mon[&x].dominance()).unwrap());

    println!("\nPer-mon breadth (dominance = top move's share of all decisions; margin = eval units a lane sits behind):");
    for id in &ids {
        let mb = &a.per_mon[id];
        println!(
            "\n{}  ·  dominance {:.0}%  ·  close-call {:.1}%  ·  {} decisions",
            roster.mon_name(*id),
            mb.dominance() * 100.0,
            mb.close_rate() * 100.0,
            mb.decisions
        );
        for l in 0..4 {
            if mb.lane_offered[l] == 0 {
                continue;
            }
            let mv = roster.move_name(*id, l as u8);
            let dead = mb.lane_use(l) < 0.02;
            println!(
                "    [{}] {:<20} use {:>4.0}%   dead-slot margin {:>6.0}{}",
                l,
                mv,
                mb.lane_use(l) * 100.0,
                mb.lane_margin(l),
                if dead { "   <- dead branch" } else { "" }
            );
        }
    }

    // Calibration: Pistol Squat dominant (Pengym), Modal Bolt a wide-margin dead branch (Nirvamma).
    let find_lane = |mon: &str, mv: &str| -> Option<(u32, usize)> {
        let m = roster.mons.iter().find(|x| x.name == mon)?;
        (0..4).find(|&l| roster.move_name(m.id, l as u8) == mv).map(|l| (m.id, l))
    };
    println!("\n[calibration]");
    if let Some((pid, pl)) = find_lane("Pengym", "Pistol Squat") {
        if let Some(mb) = a.per_mon.get(&pid) {
            let use_pct = mb.lane_use(pl) * 100.0;
            println!("  Pistol Squat dominant: {} (use {:.0}% of Pengym decisions; wants high)", if use_pct >= 40.0 { "YES ✓" } else { "NO ✗" }, use_pct);
        }
    }
    if let Some((nid, nl)) = find_lane("Nirvamma", "Modal Bolt") {
        if let Some(mb) = a.per_mon.get(&nid) {
            let use_pct = mb.lane_use(nl) * 100.0;
            let margin = mb.lane_margin(nl);
            println!("  Modal Bolt dead branch: {} (use {:.0}%, margin {:.0}; wants low use + wide margin)", if use_pct < 10.0 { "YES ✓" } else { "NO ✗" }, use_pct, margin);
        }
    }

    eprintln!("\n{} decisions from {} games in {:.2}s ({:.0} games/s)", a.total, games, elapsed, games as f64 / elapsed);
}
