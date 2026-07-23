//! Per-mon doubles diagnostic — what does one mon actually DO in its doubles games?
//! Reports move usage, survival, and whether its setup ever lands.
//!   cargo run --release -p chomp-strategies --bin montrace -- --mon Iblivion --games 400

use chomp_strategies::arena::build_doubles_specs;
use chomp_strategies::doubles::play_doubles_game_instrumented;
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
    let games = arg_u(&args, "--games", 400) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let target = arg(&args, "--mon").unwrap_or_else(|| "Iblivion".to_string());
    let search_depth = arg_u(&args, "--search-depth", 0) as u32;
    let rotate = args.iter().any(|a| a == "--rotate");

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    let book = roster::address_book();
    let tid = roster.mons.iter().find(|m| m.name == target).expect("unknown --mon").id;

    let (specs, _) = build_doubles_specs(&roster, games, seed, seed_base, rotate, search_depth);

    // Move-index usage over the tracked mon's active turns (125 = switch, 126 = no-op/rest).
    let mut usage = [0u64; 128];
    let (mut n, mut wins, mut losses) = (0u64, 0u64, 0u64);
    let (mut sum_active, mut sum_turns) = (0u64, 0u64);
    let mut ever_boosted = 0u64; // games where the mon's Attack delta ever went positive
    let mut sum_min_hp = 0.0f64;

    for spec in &specs {
        for side in 0u8..2 {
            let ids = if side == 0 { &spec.p0_ids } else { &spec.p1_ids };
            let Some(mon) = ids.iter().position(|&x| x == tid) else { continue };
            let tr = play_doubles_game_instrumented(spec, &book, Some((side, mon)));
            n += 1;
            match tr.winner_side {
                Some(w) if w == side => wins += 1,
                Some(_) => losses += 1,
                None => {}
            }
            sum_active += tr.tracked_active_turns as u64;
            sum_turns += tr.turns as u64;
            let mut boosted = false;
            let mut min_hp = 100.0f64;
            for r in &tr.rows {
                if r.active {
                    usage[r.move_index as usize] += 1;
                }
                if r.atk_delta > 0 {
                    boosted = true;
                }
                if r.hp_pct < min_hp {
                    min_hp = r.hp_pct;
                }
            }
            if boosted {
                ever_boosted += 1;
            }
            sum_min_hp += min_hp;
        }
    }

    let nf = n.max(1) as f64;
    println!("\n{target} (id {tid}) · {n} appearances over {games} doubles games · search d{search_depth}");
    println!("  win/loss           {wins}-{losses}  ({:.1}%)", wins as f64 / (wins + losses).max(1) as f64 * 100.0);
    println!("  active turns/game  {:.2}  (game length {:.2})", sum_active as f64 / nf, sum_turns as f64 / nf);
    println!("  min HP reached     {:.1}%  (mean over appearances)", sum_min_hp / nf);
    println!("  setup ever landed  {:.1}% of appearances (Attack delta > 0 at any point)", ever_boosted as f64 / nf * 100.0);

    let total: u64 = usage.iter().sum();
    println!("\n  move usage over {total} acting turns:");
    for (mi, &c) in usage.iter().enumerate() {
        if c == 0 {
            continue;
        }
        let label = match mi {
            125 => "<switch>".to_string(),
            126 => "<rest/no-op>".to_string(),
            _ => roster.move_name(tid, mi as u8),
        };
        println!("    {:<20} {:>7}  {:>5.1}%", label, c, c as f64 / total.max(1) as f64 * 100.0);
    }
}
