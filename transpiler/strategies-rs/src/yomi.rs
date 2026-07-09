//! Yomi analysis — per-mon decision tension (measure.md). Aggregates the per-turn EVPI samples
//! (value of knowing the opponent's reply) from `play_game_yomi`. A high mean/rate means the mon
//! routinely faces turns where no action is best against everything and guessing wrong is costly.

use std::collections::HashMap;

use crate::arena::build_specs_with;
use crate::game::{run_games_yomi, StrategyKind};
use crate::roster::{self, Roster};

#[derive(Default, Clone)]
pub struct YomiStat {
    pub samples: u64,
    pub sum_evpi: f64,
    pub high: u64, // samples with EVPI ≥ threshold
}

impl YomiStat {
    pub fn mean(&self) -> f64 {
        if self.samples == 0 { 0.0 } else { self.sum_evpi / self.samples as f64 }
    }
    pub fn high_rate(&self) -> f64 {
        if self.samples == 0 { 0.0 } else { self.high as f64 / self.samples as f64 }
    }
}

pub struct YomiAnalysis {
    pub per_mon: HashMap<u32, YomiStat>,
    pub total_samples: u64,
    pub threshold: f64,
}

pub fn run_yomi_analysis(
    roster: &Roster,
    games: usize,
    wseed: u32,
    seed_base: u32,
    threads: usize,
    threshold: f64,
) -> YomiAnalysis {
    let book = roster::address_book();
    // Drive with greedy (fast); the grid itself is no-peek by construction, so the driver only
    // decides which positions get sampled, not the tension computed at them.
    let pairs = [(StrategyKind::Greedy, StrategyKind::Greedy)];
    let (specs, _) = build_specs_with(roster, games, wseed, seed_base, &pairs);
    let results = run_games_yomi(&specs, &book, threads);

    let mut per_mon: HashMap<u32, YomiStat> = HashMap::new();
    let mut total = 0u64;
    for r in &results {
        let samples = match r {
            Ok(s) => s,
            Err(_) => continue,
        };
        for s in samples {
            total += 1;
            let e = per_mon.entry(s.mon_id).or_default();
            e.samples += 1;
            e.sum_evpi += s.evpi;
            if s.evpi >= threshold {
                e.high += 1;
            }
        }
    }
    YomiAnalysis { per_mon, total_samples: total, threshold }
}
