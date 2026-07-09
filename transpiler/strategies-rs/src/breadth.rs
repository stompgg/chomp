//! Breadth + close-call analysis (measure.md's "decisions" lens). From greedy's per-action fork
//! scores at each decision: dominance share (how concentrated a mon's picks are on one move),
//! dead-slot margin (how far a rarely-picked move sits behind the best where it loses — near-zero
//! is promotable, wide is dominated), and close-call rate (top two within noise while best-vs-worst
//! is wide). Calibration: Pistol Squat should be dominant, Modal Bolt a wide-margin dead branch.

use std::collections::HashMap;

use crate::arena::build_specs_with;
use crate::game::{run_games_breadth, StrategyKind};
use crate::roster::{self, Roster};

/// Top two within this many eval-score units = "within noise".
const NOISE: f64 = 5.0;
/// Best-vs-worst beyond this = "thinking pays".
const WIDE: f64 = 50.0;

#[derive(Default, Clone)]
pub struct MonBreadth {
    pub decisions: u64,
    pub lane_picks: [u64; 4],
    pub lane_offered: [u64; 4],
    pub lane_margin_sum: [f64; 4],
    pub lane_margin_n: [u64; 4],
    pub close_calls: u64,
}

impl MonBreadth {
    /// Fraction of ALL decisions where the single most-picked move is the pick.
    pub fn dominance(&self) -> f64 {
        if self.decisions == 0 {
            return 0.0;
        }
        *self.lane_picks.iter().max().unwrap() as f64 / self.decisions as f64
    }
    pub fn lane_use(&self, l: usize) -> f64 {
        if self.decisions == 0 { 0.0 } else { self.lane_picks[l] as f64 / self.decisions as f64 }
    }
    /// Mean (best_score − lane_score) at decisions where the lane was offered but not chosen.
    pub fn lane_margin(&self, l: usize) -> f64 {
        if self.lane_margin_n[l] == 0 { 0.0 } else { self.lane_margin_sum[l] / self.lane_margin_n[l] as f64 }
    }
    pub fn close_rate(&self) -> f64 {
        if self.decisions == 0 { 0.0 } else { self.close_calls as f64 / self.decisions as f64 }
    }
}

pub struct BreadthAnalysis {
    pub per_mon: HashMap<u32, MonBreadth>,
    pub total: u64,
}

pub fn run_breadth_analysis(roster: &Roster, games: usize, wseed: u32, seed_base: u32, threads: usize) -> BreadthAnalysis {
    let book = roster::address_book();
    let pairs = [(StrategyKind::Greedy, StrategyKind::Greedy)];
    let (specs, _) = build_specs_with(roster, games, wseed, seed_base, &pairs);
    let results = run_games_breadth(&specs, &book, threads);

    let mut per_mon: HashMap<u32, MonBreadth> = HashMap::new();
    let mut total = 0u64;
    for r in &results {
        let samples = match r {
            Ok(s) => s,
            Err(_) => continue,
        };
        for s in samples {
            total += 1;
            let mb = per_mon.entry(s.mon_id).or_default();
            mb.decisions += 1;
            if (s.top1 - s.top2) < NOISE && (s.top1 - s.worst) > WIDE {
                mb.close_calls += 1;
            }
            let chosen = s.chosen_move;
            if (0..4).contains(&chosen) {
                mb.lane_picks[chosen as usize] += 1;
            }
            for l in 0..4 {
                if s.lane_scores[l].is_finite() {
                    mb.lane_offered[l] += 1;
                    if chosen != l as i16 {
                        mb.lane_margin_sum[l] += (s.top1 - s.lane_scores[l]).max(0.0);
                        mb.lane_margin_n[l] += 1;
                    }
                }
            }
        }
    }
    BreadthAnalysis { per_mon, total }
}
