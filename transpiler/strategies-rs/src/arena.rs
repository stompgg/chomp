//! Standalone pure-Rust arena — the FFI-free replacement for the TS batch benchmark. Draws random
//! 4v4 teams (port of workload.ts), runs the strategy-pair matchups through the native engine, and
//! aggregates win rates. No bun, no chomp_run_games.

use chomp_engine::Structs::Mon;
use crate::doubles::{run_doubles_games, Difficulty, DoublesSpec};
use crate::game::{run_games, GameSpec, StrategyKind};
use crate::roster::{self, Roster, RosterMon};

const TEAM_SIZE: usize = 4;
const MAX_TURNS: u32 = 300;

/// [p1_strategy, p0_strategy] — matches workload.ts STRAT_PAIRS. The a-vs-b / b-vs-a entries are the
/// seat swap that cancels the p1 move-peek when aggregated.
pub const STRAT_PAIRS: &[(&str, &str)] = &[
    ("hard", "hard"), ("hard", "greedy"), ("greedy", "hard"),
    ("greedy", "greedy"), ("override", "greedy"), ("override", "hard"),
];

/// xorshift32 in [0,1) — a faithful port of workload.ts:makeWrand (the `>> 17` step is JS's signed
/// ToInt32 shift, hence the i32 cast), so the Rust arena draws the same teams as the TS one per seed.
pub struct Wrand {
    s: u32,
}
impl Wrand {
    pub fn new(seed: u32) -> Self {
        Wrand { s: seed }
    }
    pub fn next(&mut self) -> f64 {
        self.s ^= self.s << 13;
        self.s ^= ((self.s as i32) >> 17) as u32;
        self.s ^= self.s << 5;
        self.s as f64 / 4294967296.0
    }
}

/// Draw TEAM_SIZE distinct mon ids (0..NUM_MONS) — port of workload.ts:drawTeam.
pub fn draw_team(roster: &Roster, rng: &mut Wrand) -> Vec<u32> {
    let mut pool: Vec<u32> = roster.mons.iter().map(|m| m.id).collect();
    (0..TEAM_SIZE)
        .map(|_| pool.remove((rng.next() * pool.len() as f64) as usize))
        .collect()
}

/// Default loadout: the first up-to-4 catalog lanes (level-0 moves), padded to 4 by repeating the
/// last (duplicate lanes are inert). Mirrors buildTeamMon with `equip = undefined`.
pub fn build_team_mon(m: &RosterMon) -> Mon {
    let n = m.catalog.len().min(4);
    let mut moves: Vec<_> = (0..n).map(|i| m.catalog[i].word).collect();
    while moves.len() < 4 {
        moves.push(*moves.last().unwrap());
    }
    Mon { stats: m.stats.clone(), ability: m.ability, moves }
}

#[derive(Clone)]
pub struct PairStats {
    pub p1_strat: &'static str,
    pub p0_strat: &'static str,
    pub games: u32,
    pub p1_wins: u32,
    pub p0_wins: u32,
    pub draws: u32,
}
impl PairStats {
    /// p1's win share over decisive games (draws excluded).
    pub fn p1_rate(&self) -> f64 {
        let decisive = self.p1_wins + self.p0_wins;
        if decisive == 0 { 0.0 } else { self.p1_wins as f64 / decisive as f64 }
    }
}

/// Build every game's spec (STRAT_PAIRS rotation, two random team draws each), returning the specs
/// parallel to their pair index. Exposed so trace tooling can reconstruct the exact same games.
pub fn build_specs(roster: &Roster, games: usize, wseed: u32, seed_base: u32) -> (Vec<GameSpec>, Vec<usize>) {
    let pairs: Vec<(StrategyKind, StrategyKind)> = STRAT_PAIRS
        .iter()
        .map(|&(p1, p0)| (StrategyKind::parse(p1).unwrap(), StrategyKind::parse(p0).unwrap()))
        .collect();
    build_specs_with(roster, games, wseed, seed_base, &pairs)
}

/// Like `build_specs` but with an explicit [p1, p0] strategy rotation (e.g. a single no-peek-vs-peek
/// pair). Team draws stay identical per seed regardless of the pilots — matched drafts.
pub fn build_specs_with(
    roster: &Roster,
    games: usize,
    wseed: u32,
    seed_base: u32,
    pairs: &[(StrategyKind, StrategyKind)],
) -> (Vec<GameSpec>, Vec<usize>) {
    let mon = |id: u32| roster.mons.iter().find(|m| m.id == id).expect("drawn mon id in roster");
    let mut rng = Wrand::new(wseed);
    let mut specs = Vec::with_capacity(games);
    let mut pair_of = Vec::with_capacity(games);
    for i in 0..games {
        let pi = i % pairs.len();
        let (p1s, p0s) = pairs[pi];
        // workload draw order: teams[0] (→ p0) first, teams[1] (→ p1) second.
        let p0_ids = draw_team(roster, &mut rng);
        let p1_ids = draw_team(roster, &mut rng);
        specs.push(GameSpec {
            seed: seed_base.wrapping_add(i as u32),
            max_turns: MAX_TURNS,
            mons_per_team: TEAM_SIZE as u64,
            p0_team: p0_ids.iter().map(|&id| build_team_mon(mon(id))).collect(),
            p1_team: p1_ids.iter().map(|&id| build_team_mon(mon(id))).collect(),
            p0_ids,
            p1_ids,
            p0_strategy: p0s,
            p1_strategy: p1s,
        });
        pair_of.push(pi);
    }
    (specs, pair_of)
}

/// Play `games` matchups (STRAT_PAIRS rotation, two random team draws each) and tally per pair.
pub fn run_arena(roster: &Roster, games: usize, wseed: u32, seed_base: u32, threads: usize) -> Vec<PairStats> {
    let book = roster::address_book();
    let (specs, pair_of) = build_specs(roster, games, wseed, seed_base);
    let outcomes = run_games(&specs, &book, threads, false);

    let mut stats: Vec<PairStats> = STRAT_PAIRS
        .iter()
        .map(|&(p1, p0)| PairStats { p1_strat: p1, p0_strat: p0, games: 0, p1_wins: 0, p0_wins: 0, draws: 0 })
        .collect();
    for (i, outcome) in outcomes.iter().enumerate() {
        let s = &mut stats[pair_of[i]];
        s.games += 1;
        match outcome {
            Ok(o) => match o.winner_seat {
                Some(0) => s.p0_wins += 1,
                Some(1) => s.p1_wins += 1,
                _ => s.draws += 1, // turn-cap stalemate
            },
            Err(_) => s.draws += 1, // engine error (counted, not silently dropped)
        }
    }
    stats
}

// ── Doubles arena (difficulty matchups) ──────────────────────────────────────

/// [p1_difficulty, p0_difficulty] pairs. Doubles has no commit-reveal peek, so the sides are
/// symmetric — these just separate the tiers (hard should beat medium should beat easy).
pub const DIFF_PAIRS: &[(Difficulty, Difficulty)] = &[
    (Difficulty::Hard, Difficulty::Hard),
    (Difficulty::Hard, Difficulty::Medium),
    (Difficulty::Hard, Difficulty::Easy),
    (Difficulty::Medium, Difficulty::Medium),
    (Difficulty::Medium, Difficulty::Easy),
    (Difficulty::Easy, Difficulty::Easy),
];

#[derive(Clone)]
pub struct DiffPairStats {
    pub p1_diff: Difficulty,
    pub p0_diff: Difficulty,
    pub games: u32,
    pub p1_wins: u32,
    pub p0_wins: u32,
    pub draws: u32,
}
impl DiffPairStats {
    /// p1's win share over decisive games.
    pub fn p1_rate(&self) -> f64 {
        let decisive = self.p1_wins + self.p0_wins;
        if decisive == 0 { 0.0 } else { self.p1_wins as f64 / decisive as f64 }
    }
}

/// Play `games` doubles matchups (DIFF_PAIRS rotation, two random team draws each) and tally per pair.
pub fn run_doubles_arena(roster: &Roster, games: usize, wseed: u32, seed_base: u32, threads: usize) -> Vec<DiffPairStats> {
    let book = roster::address_book();
    let mon = |id: u32| roster.mons.iter().find(|m| m.id == id).expect("drawn mon id in roster");

    let mut rng = Wrand::new(wseed);
    let mut specs = Vec::with_capacity(games);
    let mut pair_of = Vec::with_capacity(games);
    for i in 0..games {
        let pi = i % DIFF_PAIRS.len();
        let (p1d, p0d) = DIFF_PAIRS[pi];
        let p0_ids = draw_team(roster, &mut rng);
        let p1_ids = draw_team(roster, &mut rng);
        specs.push(DoublesSpec {
            seed: seed_base.wrapping_add(i as u32),
            max_turns: MAX_TURNS,
            mons_per_team: TEAM_SIZE as u64,
            p0_team: p0_ids.iter().map(|&id| build_team_mon(mon(id))).collect(),
            p1_team: p1_ids.iter().map(|&id| build_team_mon(mon(id))).collect(),
            p0_ids,
            p1_ids,
            p0_difficulty: p0d,
            p1_difficulty: p1d,
        });
        pair_of.push(pi);
    }

    let outcomes = run_doubles_games(&specs, &book, threads);

    let mut stats: Vec<DiffPairStats> = DIFF_PAIRS
        .iter()
        .map(|&(p1, p0)| DiffPairStats { p1_diff: p1, p0_diff: p0, games: 0, p1_wins: 0, p0_wins: 0, draws: 0 })
        .collect();
    for (i, o) in outcomes.iter().enumerate() {
        let s = &mut stats[pair_of[i]];
        s.games += 1;
        match o.winner_side {
            Some(0) => s.p0_wins += 1,
            Some(1) => s.p1_wins += 1,
            _ => s.draws += 1,
        }
    }
    stats
}
