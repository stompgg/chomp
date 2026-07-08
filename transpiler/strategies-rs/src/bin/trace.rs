//! Trace analysis — why does hard underperform greedy?
//!
//!   cargo run --release -p chomp-strategies --bin trace -- --games 6000 [--narrate N]
//!
//! Two views:
//!  1. A per-strategy behavioral profile (switches / rests / attacks / turns per game, split by
//!     win vs loss) for every STRAT_PAIRS matchup — tests the over-switching hypothesis directly.
//!  2. A turn-by-turn narration of the Nth game where hard (p1) LOSES to greedy (p0).

use chomp_strategies::arena::{build_specs, STRAT_PAIRS};
use chomp_strategies::game::{narrate_game, run_games};
use chomp_strategies::roster::{self, load_roster};
use chomp_strategies::view::{NO_OP_INDEX, SWITCH_MOVE_INDEX};
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

/// One side's move mix over a game.
#[derive(Default, Clone)]
struct Mix {
    switches: u32,
    rests: u32,
    attacks: u32,
}

/// Per-side aggregate, split by whether that side won.
#[derive(Default, Clone)]
struct SideAgg {
    won_games: u32,
    lost_games: u32,
    won_switches: f64,
    lost_switches: f64,
    won_rests: f64,
    lost_rests: f64,
    won_turns: f64,
    lost_turns: f64,
}
impl SideAgg {
    fn add(&mut self, won: bool, mix: &Mix, turns: u32) {
        if won {
            self.won_games += 1;
            self.won_switches += mix.switches as f64;
            self.won_rests += mix.rests as f64;
            self.won_turns += turns as f64;
        } else {
            self.lost_games += 1;
            self.lost_switches += mix.switches as f64;
            self.lost_rests += mix.rests as f64;
            self.lost_turns += turns as f64;
        }
    }
    fn won_avg(&self, v: f64) -> f64 { if self.won_games == 0 { 0.0 } else { v / self.won_games as f64 } }
    fn lost_avg(&self, v: f64) -> f64 { if self.lost_games == 0 { 0.0 } else { v / self.lost_games as f64 } }
}

fn classify(mv: Option<chomp_strategies::view::Mv>, mix: &mut Mix) {
    if let Some(m) = mv {
        if m.move_index == SWITCH_MOVE_INDEX {
            mix.switches += 1;
        } else if m.move_index == NO_OP_INDEX {
            mix.rests += 1;
        } else {
            mix.attacks += 1;
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let games = arg_u(&args, "--games", 6000) as usize;
    let wseed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let narrate_n = arg_u(&args, "--narrate", 0) as usize; // narrate the Nth hard-loses-to-greedy game
    let threads = arg_u(&args, "--threads", 8) as u64 as usize;

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });

    let roster = load_roster(&chomp_root);
    let book = roster::address_book();
    let (specs, pair_of) = build_specs(&roster, games, wseed, seed_base);
    let outcomes = run_games(&specs, &book, threads, true);

    // Per-pair, per-side behavioral aggregate.
    let mut p0_agg = vec![SideAgg::default(); STRAT_PAIRS.len()];
    let mut p1_agg = vec![SideAgg::default(); STRAT_PAIRS.len()];
    let mut hard_loses: Vec<usize> = Vec::new(); // game indices: pair 1 (hard p1 vs greedy p0), p0 wins

    for (i, out) in outcomes.iter().enumerate() {
        let Ok(o) = out else { continue };
        let pair = pair_of[i];
        let (mut m0, mut m1) = (Mix::default(), Mix::default());
        for tt in &o.trace {
            classify(tt.p0, &mut m0);
            classify(tt.p1, &mut m1);
        }
        let (p1_won, p0_won) = (o.winner_seat == Some(1), o.winner_seat == Some(0));
        // Only tally decisive games (draws carry no win/loss signal).
        if p1_won || p0_won {
            p0_agg[pair].add(p0_won, &m0, o.turns);
            p1_agg[pair].add(p1_won, &m1, o.turns);
        }
        if pair == 1 && p0_won {
            hard_loses.push(i);
        }
    }

    println!("\nBEHAVIORAL PROFILE — avg per game, won vs lost (switches / rests / turns)\n");
    println!("{:>9} {:>9} │ {:>26} │ {:>26}", "p1", "p0", "p1 side (won | lost)", "p0 side (won | lost)");
    for (pi, &(p1s, p0s)) in STRAT_PAIRS.iter().enumerate() {
        let a1 = &p1_agg[pi];
        let a0 = &p0_agg[pi];
        println!(
            "{p1s:>9} {p0s:>9} │ sw {:>4.1}|{:<4.1} rest {:>3.1}|{:<3.1} │ sw {:>4.1}|{:<4.1} rest {:>3.1}|{:<3.1}  turns {:>4.1}",
            a1.won_avg(a1.won_switches), a1.lost_avg(a1.lost_switches),
            a1.won_avg(a1.won_rests), a1.lost_avg(a1.lost_rests),
            a0.won_avg(a0.won_switches), a0.lost_avg(a0.lost_switches),
            a0.won_avg(a0.won_rests), a0.lost_avg(a0.lost_rests),
            (a1.won_avg(a1.won_turns) + a1.lost_avg(a1.lost_turns)) / 2.0,
        );
    }

    // Narrate a hard-loses-to-greedy game.
    println!("\n{} games where hard(p1) loses to greedy(p0).", hard_loses.len());
    if let Some(&gi) = hard_loses.get(narrate_n) {
        println!("\n═══ NARRATION: hard-loses game #{narrate_n} (spec index {gi}) ═══");
        narrate_game(
            &specs[gi],
            &book,
            |id| roster.mon_name(id),
            |id, lane| roster.move_name(id, lane),
        );
    }
}
