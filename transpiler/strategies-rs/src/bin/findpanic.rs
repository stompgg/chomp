//! Locate the game(s) in an arena batch that panic the engine, and print enough to replay one.
//!   cargo run --release -p chomp-strategies --bin findpanic -- --games 20000

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

    eprintln!("findpanic: {games} games · rotate={rotate} · seed {seed:#x}");
    // Single-threaded so the panic message interleaves with the game it came from.
    let results = run_games_instrumented(&specs, &book, 1);

    let mut found = 0;
    for (i, r) in results.iter().enumerate() {
        let Err(e) = r else { continue };
        found += 1;
        let s = &specs[i];
        let names = |ids: &[u32]| ids.iter().map(|&x| roster.mon_name(x)).collect::<Vec<_>>().join(", ");
        println!("\n=== PANIC at spec index {i} ===");
        println!("  error       {e}");
        println!("  game seed   {} (arena seed {seed:#x}, seed_base {seed_base})", s.seed);
        println!("  p0 {:?}  [{}]", s.p0_ids, names(&s.p0_ids));
        println!("  p1 {:?}  [{}]", s.p1_ids, names(&s.p1_ids));
        println!("  pilots      p0={:?} p1={:?}", s.p0_strategy, s.p1_strategy);
        for (side, team) in [("p0", &s.p0_team), ("p1", &s.p1_team)] {
            for (k, mon) in team.iter().enumerate() {
                let id = if side == "p0" { s.p0_ids[k] } else { s.p1_ids[k] };
                let mv: Vec<String> = mon
                    .moves
                    .iter()
                    .map(|w| {
                        roster
                            .mon_by_id(id)
                            .and_then(|m| m.catalog.iter().find(|c| c.word == *w))
                            .map(|c| c.name.clone())
                            .unwrap_or_else(|| "?".into())
                    })
                    .collect();
                println!("    {side}[{k}] {:<11} {}", roster.mon_name(id), mv.join(" / "));
            }
        }
    }
    println!("\n{found} panicking game(s) out of {games}");
}
