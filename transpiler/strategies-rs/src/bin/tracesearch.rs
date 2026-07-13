//! Trace the maximin search (p1) vs a baseline (p0) — surface where the search LOSES, turn by turn,
//! with the `⟂ greedy→` counterfactual, to find tuning opportunities.
//!
//!   cargo run --release -p chomp-strategies --bin tracesearch -- \
//!       --games 300 --search-depth 2 --p0 greedy --narrate 0

use chomp_strategies::arena::{build_team_mon, draw_team, Wrand};
use chomp_strategies::evaluator::{Weights, DEFAULT_WEIGHTS, N_FEATURES};
use chomp_strategies::game::{narrate_game, run_games_traced, GameSpec, StrategyKind};
use chomp_strategies::roster::{self, load_roster};
use chomp_strategies::view::{NO_OP_INDEX, SWITCH_MOVE_INDEX};
use std::path::PathBuf;

/// `--weights "w0,..,w5"` (defaults to `DEFAULT_WEIGHTS`).
fn weights_arg(args: &[String]) -> Weights {
    match arg(args, "--weights") {
        None => DEFAULT_WEIGHTS,
        Some(s) => {
            let v: Vec<f64> = s.split(',').map(|x| x.trim().parse().expect("--weights: float")).collect();
            assert_eq!(v.len(), N_FEATURES, "--weights: expected {N_FEATURES} values");
            let mut w = [0.0; N_FEATURES];
            w.copy_from_slice(&v);
            w
        }
    }
}

/// Per-side move mix over a game (a move is a switch / rest / attack).
#[derive(Default, Clone, Copy)]
struct Mix {
    sw: f64,
    rest: f64,
    atk: f64,
}
fn classify(mv: i16, m: &mut Mix) {
    if mv == SWITCH_MOVE_INDEX as i16 {
        m.sw += 1.0;
    } else if mv == NO_OP_INDEX as i16 {
        m.rest += 1.0;
    } else if mv >= 0 {
        m.atk += 1.0;
    }
}

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
    let games = arg_u(&args, "--games", 300) as usize;
    let depth = arg_u(&args, "--search-depth", 2) as u32;
    let wseed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let narrate_n = arg_u(&args, "--narrate", 0) as usize;
    let p0_name = arg(&args, "--p0").unwrap_or_else(|| "greedy".to_string());
    let p0_strat = StrategyKind::parse(&p0_name).expect("--p0: greedy / heuristic / override / ...");
    let peek = args.iter().any(|a| a == "--peek");
    let mixed = args.iter().any(|a| a == "--mixed");
    let weights = weights_arg(&args);
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    let book = roster::address_book();
    let mon = |id: u32| roster.mons.iter().find(|m| m.id == id).expect("mon id in roster");

    let mut rng = Wrand::new(wseed);
    let mut specs: Vec<GameSpec> = Vec::with_capacity(games);
    for i in 0..games {
        let p0_ids = draw_team(&roster, &mut rng);
        let p1_ids = draw_team(&roster, &mut rng);
        specs.push(GameSpec {
            seed: seed_base.wrapping_add(i as u32),
            max_turns: 300,
            mons_per_team: 4,
            p0_team: p0_ids.iter().map(|&id| build_team_mon(mon(id))).collect(),
            p1_team: p1_ids.iter().map(|&id| build_team_mon(mon(id))).collect(),
            p0_ids,
            p1_ids,
            p0_strategy: p0_strat,
            p1_strategy: StrategyKind::Greedy, // ignored — p1_search_depth overrides to the search
            p0_weights: DEFAULT_WEIGHTS,
            p1_weights: weights,
            p0_search_depth: 0,
            p1_search_depth: depth,
            p0_search_peek: false,
            p1_search_peek: peek,
            p0_search_mixed: false,
            p1_search_mixed: mixed,
        });
    }

    let recs = run_games_traced(&specs, &book, threads);
    let (mut wins, mut decisive) = (0u32, 0u32);
    let mut losses: Vec<usize> = Vec::new();
    // p1(search) mix, split by win/loss; p0(baseline) mix over the same games.
    let (mut p1_won, mut p1_lost, mut p0_ref) = (Mix::default(), Mix::default(), Mix::default());
    let (mut won_n, mut lost_n) = (0.0f64, 0.0f64);
    for (i, r) in recs.iter().enumerate() {
        let Ok(rec) = r else { continue };
        let (mut m1, mut m0) = (Mix::default(), Mix::default());
        for row in &rec.rows {
            classify(row.p1_move, &mut m1);
            classify(row.p0_move, &mut m0);
        }
        match rec.winner_seat {
            Some(1) => {
                wins += 1;
                decisive += 1;
                won_n += 1.0;
                p1_won.sw += m1.sw;
                p1_won.rest += m1.rest;
                p1_won.atk += m1.atk;
            }
            Some(0) => {
                decisive += 1;
                losses.push(i);
                lost_n += 1.0;
                p1_lost.sw += m1.sw;
                p1_lost.rest += m1.rest;
                p1_lost.atk += m1.atk;
            }
            _ => {}
        }
        p0_ref.sw += m0.sw;
        p0_ref.rest += m0.rest;
        p0_ref.atk += m0.atk;
    }
    let wr = if decisive == 0 { 0.0 } else { wins as f64 / decisive as f64 * 100.0 };
    let n = recs.len().max(1) as f64;
    println!("search d{depth} (p1) vs {p0_name} (p0): {games} games · win {wr:.1}% · {} losses", losses.len());
    println!("avg moves/game — switches / rests / attacks:");
    println!("  search WON  games: sw {:.1}  rest {:.1}  atk {:.1}", p1_won.sw / won_n.max(1.0), p1_won.rest / won_n.max(1.0), p1_won.atk / won_n.max(1.0));
    println!("  search LOST games: sw {:.1}  rest {:.1}  atk {:.1}", p1_lost.sw / lost_n.max(1.0), p1_lost.rest / lost_n.max(1.0), p1_lost.atk / lost_n.max(1.0));
    println!("  {p0_name} (all games): sw {:.1}  rest {:.1}  atk {:.1}", p0_ref.sw / n, p0_ref.rest / n, p0_ref.atk / n);

    if let Some(&gi) = losses.get(narrate_n) {
        println!("\n═══ NARRATION: search-loses game #{narrate_n} (spec {gi}) ═══");
        narrate_game(&specs[gi], &book, |id| roster.mon_name(id), |id, lane| roster.move_name(id, lane));
    } else {
        println!("(no loss at index {narrate_n}; {} losses total)", losses.len());
    }
}
