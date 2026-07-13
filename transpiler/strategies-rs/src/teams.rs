//! Team search + cross-mon synergy (measure.md). At 4v4 with 13 mons the full team space is only
//! C(13,4) = 715, so instead of archetype heuristics we evaluate every team exhaustively against the
//! random-draft field, then read synergy as the INTERACTION beyond main effects — the
//! degenerate-construction guard: a mon that lifts every team is a main effect, not synergy.
//! Validation: Overclock (Volthare) lifting slower attackers should surface as positive interaction.

use std::collections::HashMap;

use crate::arena::{build_team_mon, draw_team, Wrand};
use crate::evaluator::DEFAULT_WEIGHTS;
use crate::game::{run_games, GameSpec, StrategyKind};
use crate::roster::{self, Roster};

/// All k-subsets of 0..n (lexicographic).
pub fn combos(n: usize, k: usize) -> Vec<Vec<usize>> {
    let mut out = Vec::new();
    if k == 0 || k > n {
        return out;
    }
    let mut idx: Vec<usize> = (0..k).collect();
    loop {
        out.push(idx.clone());
        let mut i = k;
        loop {
            if i == 0 {
                return out;
            }
            i -= 1;
            if idx[i] != i + n - k {
                break;
            }
        }
        idx[i] += 1;
        for j in i + 1..k {
            idx[j] = idx[j - 1] + 1;
        }
    }
}

pub struct TeamResult {
    pub team: Vec<u32>,
    pub games: u32,
    pub wins: u32,
    pub losses: u32,
}
impl TeamResult {
    pub fn win_rate(&self) -> f64 {
        let d = self.wins + self.losses;
        if d == 0 { 0.0 } else { self.wins as f64 / d as f64 }
    }
}

/// Every 4-mon team vs `games_per_team` random-field opponents (greedy both sides).
pub fn run_team_search(roster: &Roster, games_per_team: usize, wseed: u32, seed_base: u32, threads: usize) -> Vec<TeamResult> {
    let book = roster::address_book();
    let ids: Vec<u32> = roster.mons.iter().map(|m| m.id).collect();
    let n = ids.len();
    let mon = |id: u32| roster.mons.iter().find(|m| m.id == id).expect("mon id");
    let teams = combos(n, 4);

    let mut specs: Vec<GameSpec> = Vec::with_capacity(teams.len() * games_per_team);
    let mut team_of: Vec<usize> = Vec::with_capacity(teams.len() * games_per_team);
    let mut orng = Wrand::new(wseed);
    let mut counter: u32 = 0;
    for (ti, combo) in teams.iter().enumerate() {
        let team_ids: Vec<u32> = combo.iter().map(|&i| ids[i]).collect();
        for _ in 0..games_per_team {
            let opp = draw_team(roster, &mut orng);
            specs.push(GameSpec {
                seed: seed_base.wrapping_add(counter),
                max_turns: 300,
                mons_per_team: 4,
                p0_team: opp.iter().map(|&id| build_team_mon(mon(id))).collect(),
                p1_team: team_ids.iter().map(|&id| build_team_mon(mon(id))).collect(),
                p0_ids: opp,
                p1_ids: team_ids.clone(),
                p0_strategy: StrategyKind::Greedy,
                p1_strategy: StrategyKind::Greedy,
                p0_weights: DEFAULT_WEIGHTS,
                p1_weights: DEFAULT_WEIGHTS,
                p0_search_depth: 0,
                p1_search_depth: 0,
                p0_search_peek: false,
                p1_search_peek: false,
                p0_search_mixed: false,
                p1_search_mixed: false,
            });
            team_of.push(ti);
            counter = counter.wrapping_add(1);
        }
    }

    let outcomes = run_games(&specs, &book, threads, false);
    let mut results: Vec<TeamResult> = teams
        .iter()
        .map(|c| TeamResult { team: c.iter().map(|&i| ids[i]).collect(), games: 0, wins: 0, losses: 0 })
        .collect();
    for (i, o) in outcomes.iter().enumerate() {
        let r = &mut results[team_of[i]];
        r.games += 1;
        if let Ok(g) = o {
            match g.winner_seat {
                Some(1) => r.wins += 1, // p1 = the searched team
                Some(0) => r.losses += 1,
                _ => {}
            }
        }
    }
    results
}

pub struct Synergy {
    pub overall: f64,
    pub main: HashMap<u32, f64>,
    pub interaction: HashMap<(u32, u32), f64>,
}

/// Main effects (each mon's average lift) and pairwise interaction (lift of teams with BOTH beyond
/// what the two main effects predict). Interaction is the synergy signal, robust to a mon that
/// simply lifts everything (that shows up in the main effect, not the interaction).
pub fn synergy(results: &[TeamResult]) -> Synergy {
    let overall: f64 = results.iter().map(|r| r.win_rate()).sum::<f64>() / results.len().max(1) as f64;

    let mut sum_with: HashMap<u32, f64> = HashMap::new();
    let mut n_with: HashMap<u32, u32> = HashMap::new();
    let mut sum_both: HashMap<(u32, u32), f64> = HashMap::new();
    let mut n_both: HashMap<(u32, u32), u32> = HashMap::new();

    for r in results {
        let wr = r.win_rate();
        for &a in &r.team {
            *sum_with.entry(a).or_insert(0.0) += wr;
            *n_with.entry(a).or_insert(0) += 1;
        }
        for i in 0..r.team.len() {
            for j in i + 1..r.team.len() {
                let (a, b) = (r.team[i].min(r.team[j]), r.team[i].max(r.team[j]));
                *sum_both.entry((a, b)).or_insert(0.0) += wr;
                *n_both.entry((a, b)).or_insert(0) += 1;
            }
        }
    }

    let main: HashMap<u32, f64> = sum_with
        .iter()
        .map(|(&m, &s)| (m, s / n_with[&m] as f64 - overall))
        .collect();

    let interaction: HashMap<(u32, u32), f64> = sum_both
        .iter()
        .map(|(&(a, b), &s)| {
            let mean_both = s / n_both[&(a, b)] as f64;
            let predicted = overall + main.get(&a).copied().unwrap_or(0.0) + main.get(&b).copied().unwrap_or(0.0);
            ((a, b), mean_both - predicted)
        })
        .collect();

    Synergy { overall, main, interaction }
}
