//! Standalone pure-Rust arena — the FFI-free replacement for the TS batch benchmark. Draws random
//! 4v4 teams (port of workload.ts), runs the strategy-pair matchups through the native engine, and
//! aggregates win rates. No bun, no chomp_run_games.

use chomp_engine::Structs::Mon;
use crate::doubles::{run_doubles_games, Difficulty, DoublesEvalW, DoublesSpec};
use crate::evaluator::{Weights, DEFAULT_WEIGHTS};
use crate::game::{run_games, GameSpec, StrategyKind};
use crate::roster::{self, Roster, RosterMon};

const TEAM_SIZE: usize = 4;
const MAX_TURNS: u32 = 300;

/// [p1_strategy, p0_strategy] — matches workload.ts STRAT_PAIRS. The a-vs-b / b-vs-a entries are the
/// seat swap that cancels the p1 move-peek when aggregated.
pub const STRAT_PAIRS: &[(&str, &str)] = &[
    ("heuristic", "heuristic"), ("heuristic", "greedy"), ("greedy", "heuristic"),
    ("greedy", "greedy"), ("override", "greedy"), ("override", "heuristic"),
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

/// Every legal 4-move loadout for a mon: each 4-subset of its catalog, in lane order. Mons with a
/// catalog of 4 or fewer yield exactly one loadout (identical to [`build_team_mon`]), so rotation is
/// a no-op for them.
pub fn loadouts(m: &RosterMon) -> Vec<Mon> {
    if m.catalog.len() <= 4 {
        return vec![build_team_mon(m)];
    }
    crate::teams::combos(m.catalog.len(), 4)
        .into_iter()
        .map(|pick| Mon {
            stats: m.stats.clone(),
            ability: m.ability,
            moves: pick.iter().map(|&i| m.catalog[i].word).collect(),
        })
        .collect()
}

/// Per-mon loadout tables for a rotated draft. Indexed by mon id.
fn loadout_table(roster: &Roster) -> std::collections::HashMap<u32, Vec<Mon>> {
    roster.mons.iter().map(|m| (m.id, loadouts(m))).collect()
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
    build_specs_full(roster, games, wseed, seed_base, pairs, false)
}

/// `build_specs_with` plus a `rotate` switch: when set, each drafted slot draws a uniform loadout
/// from that mon's full 4-subset set instead of always equipping catalog lanes 0-3. The loadout draw
/// runs on its own rng stream so team drafts stay bit-identical to an unrotated run at the same seed.
///
/// Callers that map an equipped lane index back to a move name (trace narration via
/// `Roster::move_name`) must leave this off — with rotation the lane→catalog mapping is per-game.
pub fn build_specs_full(
    roster: &Roster,
    games: usize,
    wseed: u32,
    seed_base: u32,
    pairs: &[(StrategyKind, StrategyKind)],
    rotate: bool,
) -> (Vec<GameSpec>, Vec<usize>) {
    // Build each mon's loadout set once (13 mons), then clone per draft — avoids an O(n) find
    // and a fresh build_team_mon on every drafted slot across tens of thousands of games.
    let table = loadout_table(roster);
    let mut rng = Wrand::new(wseed);
    let mut lrng = Wrand::new(wseed ^ 0x9e37_79b9);
    let equip = |ids: &[u32], lrng: &mut Wrand| -> Vec<Mon> {
        ids.iter()
            .map(|id| {
                let opts = &table[id];
                let k = if rotate && opts.len() > 1 { (lrng.next() * opts.len() as f64) as usize } else { 0 };
                opts[k.min(opts.len() - 1)].clone()
            })
            .collect()
    };
    let mut specs = Vec::with_capacity(games);
    let mut pair_of = Vec::with_capacity(games);
    for i in 0..games {
        let pi = i % pairs.len();
        let (p1s, p0s) = pairs[pi];
        // workload draw order: teams[0] (→ p0) first, teams[1] (→ p1) second.
        let p0_ids = draw_team(roster, &mut rng);
        let p1_ids = draw_team(roster, &mut rng);
        let p0_team = equip(&p0_ids, &mut lrng);
        let p1_team = equip(&p1_ids, &mut lrng);
        specs.push(GameSpec {
            seed: seed_base.wrapping_add(i as u32),
            max_turns: MAX_TURNS,
            mons_per_team: TEAM_SIZE as u64,
            p0_team,
            p1_team,
            p0_ids,
            p1_ids,
            p0_strategy: p0s,
            p1_strategy: p1s,
            p0_weights: DEFAULT_WEIGHTS,
            p1_weights: DEFAULT_WEIGHTS,
            p0_search_depth: 0,
            p1_search_depth: 0,
            p0_search_peek: false,
            p1_search_peek: false,
            p0_search_mixed: false,
            p1_search_mixed: false,
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

/// The win share of a candidate weight vector — played on p1 by `p1_strat` at `p1_search_depth`
/// (0 = 1-ply, ≥1 = maximin search) — against a baseline field (`p0_strat` scoring with the linear
/// [`DEFAULT_WEIGHTS`]) over `games` matched drafts. Draws excluded from the denominator. Passing
/// `DEFAULT_WEIGHTS` at depth 0 reproduces the corresponding STRAT_PAIRS row exactly.
#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
pub fn eval_weights_winrate(
    roster: &Roster,
    cand: &Weights,
    p1_search_depth: u32,
    p1_search_peek: bool,
    p1_strat: StrategyKind,
    p0_strat: StrategyKind,
    games: usize,
    wseed: u32,
    seed_base: u32,
    threads: usize,
) -> f64 {
    let book = roster::address_book();
    let (mut specs, _) = build_specs_with(roster, games, wseed, seed_base, &[(p1_strat, p0_strat)]);
    for s in &mut specs {
        s.p1_weights = *cand; // candidate under test
        s.p1_search_depth = p1_search_depth; // 0 = 1-ply greedy; ≥1 = maximin search
        s.p1_search_peek = p1_search_peek; // peek-at-root best-response
        s.p0_weights = DEFAULT_WEIGHTS; // frozen baseline
    }
    let outcomes = run_games(&specs, &book, threads, false);

    let (mut p1_wins, mut decisive) = (0u32, 0u32);
    for o in &outcomes {
        if let Ok(g) = o {
            match g.winner_seat {
                Some(1) => {
                    p1_wins += 1;
                    decisive += 1;
                }
                Some(0) => decisive += 1,
                _ => {}
            }
        }
    }
    if decisive == 0 { 0.0 } else { p1_wins as f64 / decisive as f64 }
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
/// Win share of the doubles maximin search (side 1, depth `depth`) vs the epsilon-greedy `Hard`
/// pilot (side 0) over `games` matched drafts. The Phase-3 substrate exit check.
pub fn doubles_search_winrate(roster: &Roster, depth: u32, games: usize, wseed: u32, seed_base: u32, threads: usize) -> f64 {
    let book = roster::address_book();
    let mut rng = Wrand::new(wseed);
    let mut specs = Vec::with_capacity(games);
    for i in 0..games {
        let (p0_team, p0_ids) = draw_built_team(roster, &mut rng);
        let (p1_team, p1_ids) = draw_built_team(roster, &mut rng);
        specs.push(doubles_spec(
            seed_base.wrapping_add(i as u32),
            p0_team,
            p0_ids,
            DoublesSideCfg::default(), // side 0 = epsilon-greedy Hard baseline
            p1_team,
            p1_ids,
            DoublesSideCfg { depth, ..Default::default() },
        ));
    }
    let outcomes = run_doubles_games(&specs, &book, threads);
    let (mut p1, mut decisive) = (0u32, 0u32);
    for o in &outcomes {
        match o.winner_side {
            Some(1) => {
                p1 += 1;
                decisive += 1;
            }
            Some(0) => decisive += 1,
            _ => {}
        }
    }
    if decisive == 0 { 0.0 } else { p1 as f64 / decisive as f64 }
}

/// Build the doubles field (DIFF_PAIRS rotation, two random team draws each). `rotate` draws each
/// slot's loadout from that mon's full 4-subset set; see [`build_specs_full`].
pub fn build_doubles_specs(
    roster: &Roster,
    games: usize,
    wseed: u32,
    seed_base: u32,
    rotate: bool,
    search_depth: u32,
) -> (Vec<DoublesSpec>, Vec<usize>) {
    let table = loadout_table(roster);
    let mut rng = Wrand::new(wseed);
    let mut lrng = Wrand::new(wseed ^ 0x9e37_79b9);
    let equip = |ids: &[u32], lrng: &mut Wrand| -> Vec<Mon> {
        ids.iter()
            .map(|id| {
                let opts = &table[id];
                let k = if rotate && opts.len() > 1 { (lrng.next() * opts.len() as f64) as usize } else { 0 };
                opts[k.min(opts.len() - 1)].clone()
            })
            .collect()
    };
    let mut specs = Vec::with_capacity(games);
    let mut pair_of = Vec::with_capacity(games);
    for i in 0..games {
        let pi = i % DIFF_PAIRS.len();
        let (p1d, p0d) = DIFF_PAIRS[pi];
        let p0_ids = draw_team(roster, &mut rng);
        let p1_ids = draw_team(roster, &mut rng);
        let p0_team = equip(&p0_ids, &mut lrng);
        let p1_team = equip(&p1_ids, &mut lrng);
        specs.push(doubles_spec(
            seed_base.wrapping_add(i as u32),
            p0_team,
            p0_ids,
            DoublesSideCfg { difficulty: p0d, depth: search_depth, ..Default::default() },
            p1_team,
            p1_ids,
            DoublesSideCfg { difficulty: p1d, depth: search_depth, ..Default::default() },
        ));
        pair_of.push(pi);
    }
    (specs, pair_of)
}

pub fn run_doubles_arena(roster: &Roster, games: usize, wseed: u32, seed_base: u32, threads: usize) -> Vec<DiffPairStats> {
    let book = roster::address_book();
    let (specs, pair_of) = build_doubles_specs(roster, games, wseed, seed_base, false, 0);
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

/// One side's doubles driver config: pilot difficulty (used at depth 0), search depth, eval weights.
#[derive(Clone, Copy)]
pub struct DoublesSideCfg {
    pub difficulty: Difficulty,
    pub depth: u32,
    pub eval: DoublesEvalW,
}
impl Default for DoublesSideCfg {
    fn default() -> Self {
        Self { difficulty: Difficulty::Hard, depth: 0, eval: DoublesEvalW::default() }
    }
}

/// Draw a team and materialize its default-loadout mons.
fn draw_built_team(roster: &Roster, rng: &mut Wrand) -> (Vec<Mon>, Vec<u32>) {
    let ids = draw_team(roster, rng);
    let team = ids.iter().map(|&id| build_team_mon(roster.mon_by_id(id).expect("drawn mon id in roster"))).collect();
    (team, ids)
}

/// Fill a DoublesSpec from per-side configs — the one place the spec's field mapping lives.
#[allow(clippy::too_many_arguments)]
fn doubles_spec(
    seed: u32,
    p0_team: Vec<Mon>,
    p0_ids: Vec<u32>,
    p0: DoublesSideCfg,
    p1_team: Vec<Mon>,
    p1_ids: Vec<u32>,
    p1: DoublesSideCfg,
) -> DoublesSpec {
    DoublesSpec {
        seed,
        max_turns: MAX_TURNS,
        mons_per_team: TEAM_SIZE as u64,
        p0_team,
        p1_team,
        p0_ids,
        p1_ids,
        p0_difficulty: p0.difficulty,
        p1_difficulty: p1.difficulty,
        p0_search_depth: p0.depth,
        p1_search_depth: p1.depth,
        p0_eval: p0.eval,
        p1_eval: p1.eval,
    }
}

pub struct DoublesAbResult {
    /// Candidate's win share of decisive games.
    pub share: f64,
    pub cand_wins: u32,
    pub base_wins: u32,
    pub draws: u32,
}

/// A/B two search configs: every drawn team pair plays twice with the same teams and seats but the
/// CONFIGS exchanged, so team-matchup luck and any engine side bias cancel per pair. Returns the
/// candidate (`cand`) side's record vs the baseline (`base`).
pub fn doubles_ab_winrate(
    roster: &Roster,
    cand: DoublesSideCfg,
    base: DoublesSideCfg,
    games: usize,
    wseed: u32,
    seed_base: u32,
    threads: usize,
) -> DoublesAbResult {
    let book = roster::address_book();
    let mut rng = Wrand::new(wseed);
    // Both seats search in an A/B (depth 0 would compare the un-evaluated greedy pilot instead).
    let cand = DoublesSideCfg { depth: cand.depth.max(1), ..cand };
    let base = DoublesSideCfg { depth: base.depth.max(1), ..base };
    let pairs = (games / 2).max(1);
    let mut specs = Vec::with_capacity(pairs * 2);
    for i in 0..pairs {
        let (p0_team, p0_ids) = draw_built_team(roster, &mut rng);
        let (p1_team, p1_ids) = draw_built_team(roster, &mut rng);
        // Game A: candidate in the p1 seat; game B: same everything, configs swapped.
        for &(c1, c0) in &[(cand, base), (base, cand)] {
            specs.push(doubles_spec(
                seed_base.wrapping_add(i as u32),
                p0_team.clone(),
                p0_ids.clone(),
                c0,
                p1_team.clone(),
                p1_ids.clone(),
                c1,
            ));
        }
    }
    let outcomes = run_doubles_games(&specs, &book, threads);
    let (mut cand_wins, mut base_wins, mut draws) = (0u32, 0u32, 0u32);
    for (i, o) in outcomes.iter().enumerate() {
        let cand_seat = if i % 2 == 0 { 1 } else { 0 };
        match o.winner_side {
            Some(s) if s == cand_seat => cand_wins += 1,
            Some(_) => base_wins += 1,
            None => draws += 1,
        }
    }
    let decisive = cand_wins + base_wins;
    DoublesAbResult {
        share: if decisive == 0 { 0.0 } else { cand_wins as f64 / decisive as f64 },
        cand_wins,
        base_wins,
        draws,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::roster::load_roster;
    use std::collections::HashSet;

    fn chomp_root() -> std::path::PathBuf {
        std::env::var("CHOMP_ROOT").map(std::path::PathBuf::from).unwrap_or_else(|_| {
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
        })
    }

    /// Each mon's loadout set is exactly C(catalog, 4), and every catalog move reaches some loadout —
    /// the level-6 moves that the default lanes-0-3 loadout can never equip.
    #[test]
    fn loadouts_cover_every_catalog_move() {
        let roster = load_roster(&chomp_root());
        for m in &roster.mons {
            let ls = loadouts(m);
            let expected = if m.catalog.len() <= 4 { 1 } else { combos_len(m.catalog.len(), 4) };
            assert_eq!(ls.len(), expected, "{}: expected {expected} loadouts, got {}", m.name, ls.len());
            for l in &ls {
                assert_eq!(l.moves.len(), 4, "{}: loadout must equip 4 lanes", m.name);
            }
            let seen: HashSet<_> = ls.iter().flat_map(|l| l.moves.iter().copied()).collect();
            for c in &m.catalog {
                assert!(seen.contains(&c.word), "{}: catalog move {} unreachable", m.name, c.name);
            }
        }
    }

    fn combos_len(n: usize, k: usize) -> usize {
        (0..k).fold(1usize, |acc, i| acc * (n - i) / (i + 1))
    }

    /// Rotation leaves the team draft untouched (matched drafts) but does vary the equipped moves.
    #[test]
    fn rotation_preserves_drafts_and_varies_loadouts() {
        let roster = load_roster(&chomp_root());
        let pairs = [(StrategyKind::Greedy, StrategyKind::Greedy)];
        let (plain, _) = build_specs_full(&roster, 300, 0xbeefcafe, 10_000, &pairs, false);
        let (rot, _) = build_specs_full(&roster, 300, 0xbeefcafe, 10_000, &pairs, true);

        for (a, b) in plain.iter().zip(rot.iter()) {
            assert_eq!(a.p0_ids, b.p0_ids, "rotation must not disturb the p0 draft");
            assert_eq!(a.p1_ids, b.p1_ids, "rotation must not disturb the p1 draft");
        }
        // The plain field equips one fixed loadout per mon; the rotated field must show more.
        let variants = |specs: &[GameSpec]| -> usize {
            let mut s: HashSet<(u32, Vec<chomp_rt::U256>)> = HashSet::new();
            for sp in specs {
                for (ids, team) in [(&sp.p0_ids, &sp.p0_team), (&sp.p1_ids, &sp.p1_team)] {
                    for (id, mon) in ids.iter().zip(team.iter()) {
                        s.insert((*id, mon.moves.clone()));
                    }
                }
            }
            s.len()
        };
        assert_eq!(variants(&plain), roster.mons.len(), "unrotated field should equip one loadout per mon");
        assert!(variants(&rot) > variants(&plain), "rotated field should equip more than one loadout per mon");
    }
}
