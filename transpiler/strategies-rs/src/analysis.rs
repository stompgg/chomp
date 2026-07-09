//! Per-mon attribution aggregation over instrumented 4v4 games — the de-confounded
//! mon-vs-mon read of the measurement doctrine (measure.md, ruled 2026-07-08).
//!
//! Folds `InstrRecord`s into per-mon stats split by whether the mon's team won or
//! lost, plus a mon-vs-mon KO matrix (who KOs whom, by the opponent-active-slot
//! proxy). This replaces teammate-confounded `pairWins` as the effectiveness
//! citation: a KO is credited to the actual mon that landed it, not to all four
//! winners against all four losers.

use std::collections::HashMap;

use crate::arena::build_specs;
use crate::game::{run_games_instrumented, InstrRecord};
use crate::roster::{self, Roster};

/// Per-mon accumulators, split by the mon's own team result that game.
#[derive(Default, Clone)]
pub struct MonStat {
    pub games_won: u32,
    pub games_lost: u32,
    pub games_drawn: u32,
    pub active_turns_won: u64,
    pub active_turns_lost: u64,
    pub kos_dealt_won: u32,
    pub kos_dealt_lost: u32,
    pub kos_taken_won: u32,
    pub kos_taken_lost: u32,
}

impl MonStat {
    pub fn games(&self) -> u32 {
        self.games_won + self.games_lost + self.games_drawn
    }
    /// Win share over decisive games (draws excluded).
    pub fn win_rate(&self) -> f64 {
        let d = self.games_won + self.games_lost;
        if d == 0 { 0.0 } else { self.games_won as f64 / d as f64 }
    }
    pub fn kos_dealt(&self) -> u32 {
        self.kos_dealt_won + self.kos_dealt_lost
    }
    pub fn kos_taken(&self) -> u32 {
        self.kos_taken_won + self.kos_taken_lost
    }
    pub fn active_turns(&self) -> u64 {
        self.active_turns_won + self.active_turns_lost
    }
}

pub struct MonAnalysis {
    pub per_mon: HashMap<u32, MonStat>,
    /// (killer_id, victim_id) -> attributed KO count.
    pub ko_matrix: HashMap<(u32, u32), u32>,
    pub games: u32,
    pub decided: u32,
    pub draws: u32,
    pub errors: u32,
}

/// Draw the same 4v4 field as the plain arena, run it instrumented, fold per-mon.
pub fn run_mon_analysis(roster: &Roster, games: usize, wseed: u32, seed_base: u32, threads: usize) -> MonAnalysis {
    let book = roster::address_book();
    let (specs, _pair_of) = build_specs(roster, games, wseed, seed_base);
    let records = run_games_instrumented(&specs, &book, threads);
    fold(&records)
}

fn fold(records: &[Result<InstrRecord, String>]) -> MonAnalysis {
    let mut per_mon: HashMap<u32, MonStat> = HashMap::new();
    let mut ko_matrix: HashMap<(u32, u32), u32> = HashMap::new();
    let (mut n_games, mut decided, mut draws, mut errors) = (0u32, 0u32, 0u32, 0u32);

    for r in records {
        n_games += 1;
        let rec = match r {
            Ok(rec) => rec,
            Err(_) => {
                errors += 1;
                continue;
            }
        };

        // Per-seat game result: +1 won, -1 lost, 0 draw.
        let (p0_res, p1_res): (i8, i8) = match rec.winner_seat {
            Some(0) => { decided += 1; (1, -1) }
            Some(1) => { decided += 1; (-1, 1) }
            _ => { draws += 1; (0, 0) }
        };

        for (slot, &id) in rec.p0_ids.iter().enumerate() {
            let st = per_mon.entry(id).or_default();
            tally_game(st, p0_res);
            let at = rec.active_turns_p0.get(slot).copied().unwrap_or(0) as u64;
            add_active(st, p0_res, at);
        }
        for (slot, &id) in rec.p1_ids.iter().enumerate() {
            let st = per_mon.entry(id).or_default();
            tally_game(st, p1_res);
            let at = rec.active_turns_p1.get(slot).copied().unwrap_or(0) as u64;
            add_active(st, p1_res, at);
        }

        for ko in &rec.kos {
            *ko_matrix.entry((ko.killer_id, ko.victim_id)).or_insert(0) += 1;
            let killer_res = if ko.killer_seat == 0 { p0_res } else { p1_res };
            {
                let ks = per_mon.entry(ko.killer_id).or_default();
                match killer_res {
                    1 => ks.kos_dealt_won += 1,
                    -1 => ks.kos_dealt_lost += 1,
                    _ => {}
                }
            }
            {
                let vs = per_mon.entry(ko.victim_id).or_default();
                match -killer_res {
                    1 => vs.kos_taken_won += 1,
                    -1 => vs.kos_taken_lost += 1,
                    _ => {}
                }
            }
        }
    }

    MonAnalysis { per_mon, ko_matrix, games: n_games, decided, draws, errors }
}

fn tally_game(st: &mut MonStat, res: i8) {
    match res {
        1 => st.games_won += 1,
        -1 => st.games_lost += 1,
        _ => st.games_drawn += 1,
    }
}

fn add_active(st: &mut MonStat, res: i8, at: u64) {
    match res {
        1 => st.active_turns_won += at,
        -1 => st.active_turns_lost += at,
        _ => {}
    }
}
