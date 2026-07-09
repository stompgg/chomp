//! Static damage-to-KO matrix (measure.md's static half of the wall/check matrix).
//!   cargo run --release -p chomp-strategies --bin matrix

use chomp_strategies::matrix::compute_static_matrix;
use chomp_strategies::roster::load_roster;
use std::path::PathBuf;

fn short(s: &str) -> String {
    s.chars().take(6).collect()
}

fn main() {
    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    let m = compute_static_matrix(&roster);
    let n = m.n();
    let name = |k: usize| roster.mon_name(m.ids[k]);

    eprintln!("matrix: {} mons · default loadout · deterministic (no crit/volatility)", n);

    // Best-hit damage as % of defender max HP (rows attack columns).
    println!("\nBest-hit damage as % of defender max HP (row attacks column):");
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
            let pct = 100.0 * m.best_damage[i][j] as f64 / m.max_hp[j].max(1) as f64;
            print!("{:>6.0}%", pct);
        }
        println!();
    }

    // Move-turns to KO (rows attack columns).
    println!("\nMove-turns to KO (row attacks column; ∞ = can't damage):");
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
            let t = m.turns_to_ko[i][j];
            if t == u32::MAX {
                print!("{:>7}", "∞");
            } else {
                print!("{:>7}", t);
            }
        }
        println!();
    }

    // Per-mon check/wall profile.
    println!("\nPer-mon check/wall profile (static, default loadout):");
    for i in 0..n {
        let checks: Vec<String> = m.checks(i).iter().map(|&j| name(j)).collect();
        let walls: Vec<String> = m.walled_by(i).iter().map(|&j| name(j)).collect();
        println!(
            "{:<11} checks: {:<44} walled by: {}",
            name(i),
            if checks.is_empty() { "—".into() } else { checks.join(", ") },
            if walls.is_empty() { "—".into() } else { walls.join(", ") }
        );
    }

    // Calibration: Gorillax walls Ghouliath (none of Ghouliath's moves reach 50% of Gorillax HP,
    // and Gorillax out-damages back).
    let idx = |nm: &str| (0..n).find(|&k| name(k) == nm);
    if let (Some(g), Some(gh)) = (idx("Gorillax"), idx("Ghouliath")) {
        let ttk = m.turns_to_ko[gh][g]; // Ghouliath attacking Gorillax
        let pct = 100.0 * m.best_damage[gh][g] as f64 / m.max_hp[g].max(1) as f64;
        let out = m.best_damage[g][gh] > m.best_damage[gh][g];
        let walls = ttk >= 3 && out;
        println!(
            "\n[calibration] Gorillax walls Ghouliath: {}",
            if walls { "YES ✓" } else { "NO ✗" }
        );
        println!(
            "  Ghouliath best hit vs Gorillax = {:.0}% HP, {} turns-to-KO (wants <50% / ≥3); Gorillax out-damages: {}",
            pct,
            if ttk == u32::MAX { 999 } else { ttk },
            out
        );
    }
}
