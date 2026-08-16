//! The built-in bots and the registry that names them.
//!
//! Each one wraps a decision module; the modules keep the logic, the bots own
//! the per-game state. Adding an entrant means adding a struct here and one
//! line to [`build`].

use crate::bot::{Action, BattleMode, Bot, BotConfig, DecisionCtx};
use crate::evaluator::Weights;
use crate::greedy;
use crate::heuristic::{self, HeuristicState};
use crate::nopeek;
use crate::override_cpu::{self, OverrideState};
use crate::search;
use crate::doubles::{self, Difficulty, DoublesEvalW, SlotMove};
use crate::view::{calculate_valid_moves, pick_uniform, Mv, NO_OP_INDEX};

pub const RANDOM: &str = "random";
pub const GREEDY: &str = "greedy";
pub const HEURISTIC: &str = "heuristic";
pub const OVERRIDE: &str = "override";
pub const NOPEEK: &str = "nopeek";
pub const NOPEEK_WC: &str = "nopeek-wc";
pub const SEARCH: &str = "search";
pub const EXAMPLE: &str = "example";
/// Search bots at a pinned depth. Depth is the single biggest lever a bot has,
/// so the ladder names it rather than hiding it in config.
pub const SEARCH_D1: &str = "search-d1";
pub const SEARCH_D2: &str = "search-d2";
pub const DOUBLES_SEARCH_D1: &str = "doubles-search-d1";
pub const DOUBLES_SEARCH_D2: &str = "doubles-search-d2";
pub const DOUBLES_EASY: &str = "doubles-easy";
pub const DOUBLES_MEDIUM: &str = "doubles-medium";
pub const DOUBLES_HARD: &str = "doubles-hard";
pub const DOUBLES_SEARCH: &str = "doubles-search";
pub const DOUBLES_SPARSE: &str = "doubles-sparse";
pub const DOUBLES_SPARSE_LEAN: &str = "doubles-sparse-lean";

/// Every registered bot, in ladder order (weakest first).
pub const NAMES: &[&str] =
    &[RANDOM, EXAMPLE, GREEDY, HEURISTIC, OVERRIDE, NOPEEK, NOPEEK_WC, SEARCH, SEARCH_D1, SEARCH_D2];

/// Registered doubles bots, weakest first.
pub const DOUBLES_NAMES: &[&str] = &[
    DOUBLES_EASY,
    DOUBLES_MEDIUM,
    DOUBLES_HARD,
    DOUBLES_SEARCH,
    DOUBLES_SEARCH_D1,
    DOUBLES_SEARCH_D2,
    DOUBLES_SPARSE,
    DOUBLES_SPARSE_LEAN,
];

const DOUBLES_ONLY: &[BattleMode] = &[BattleMode::Doubles];

fn slot_to_mv(m: SlotMove) -> Mv {
    Mv { move_index: m.move_index, extra_data: m.extra_data }
}

/// Epsilon-greedy per slot; the difficulty is how often it takes the best option.
pub struct DoublesGreedyBot {
    name: &'static str,
    difficulty: Difficulty,
}

impl Bot for DoublesGreedyBot {
    fn name(&self) -> &'static str {
        self.name
    }
    fn modes(&self) -> &'static [BattleMode] {
        DOUBLES_ONLY
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let bk = ctx.sim.battle_key;
        let (a, b) = doubles::pick_side_moves(ctx.sim, bk, ctx.seat.cpu, self.difficulty, ctx.rng);
        Action::Slots([slot_to_mv(a), slot_to_mv(b)])
    }
}

/// Joint maximin search over both of the side's slots.
pub struct DoublesSearchBot {
    depth: u32,
    eval: DoublesEvalW,
    move_used_bitmap: u32,
}

/// Sparse depth-2: d1 guidance matrix, then a top-K beam deepened to d2.
pub struct DoublesSparseBot {
    lean: bool,
    eval: DoublesEvalW,
    move_used_bitmap: u32,
}

impl Bot for DoublesSparseBot {
    fn name(&self) -> &'static str {
        if self.lean { DOUBLES_SPARSE_LEAN } else { DOUBLES_SPARSE }
    }
    fn modes(&self) -> &'static [BattleMode] {
        DOUBLES_ONLY
    }
    fn reset(&mut self) {
        self.move_used_bitmap = 0;
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let bk = ctx.sim.battle_key;
        let cfg = if self.lean { doubles::SPARSE_LEAN } else { doubles::SPARSE_DEFAULT };
        let (a, b) = doubles::search_side_moves_sparse(
            ctx.sim, bk, ctx.seat.cpu, &self.eval, cfg, &mut self.move_used_bitmap,
        );
        Action::Slots([slot_to_mv(a), slot_to_mv(b)])
    }
}

impl Bot for DoublesSearchBot {
    fn name(&self) -> &'static str {
        match self.depth {
            1 => DOUBLES_SEARCH_D1,
            2 => DOUBLES_SEARCH_D2,
            _ => DOUBLES_SEARCH,
        }
    }
    fn modes(&self) -> &'static [BattleMode] {
        DOUBLES_ONLY
    }
    fn reset(&mut self) {
        self.move_used_bitmap = 0;
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let bk = ctx.sim.battle_key;
        let (a, b) = doubles::search_side_moves(
            ctx.sim, bk, ctx.seat.cpu, self.depth, &self.eval, &mut self.move_used_bitmap,
        );
        Action::Slots([slot_to_mv(a), slot_to_mv(b)])
    }
}

/// The move a bot with nothing legal to do submits.
fn no_op() -> Mv {
    Mv { move_index: NO_OP_INDEX, extra_data: 0 }
}

/// Uniform over the legal actions — the floor a real entrant must clear.
pub struct RandomBot;

impl Bot for RandomBot {
    fn name(&self) -> &'static str {
        RANDOM
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let valid = calculate_valid_moves(ctx.sim, ctx.seat, ctx.singles_view().bk, ctx.rng);
        let all: Vec<Mv> = valid
            .moves
            .iter()
            .chain(valid.switches.iter())
            .chain(valid.no_op.iter())
            .copied()
            .collect();
        let pick = pick_uniform(all.len(), ctx.rng).map(|i| all[i]).unwrap_or_else(no_op);
        Action::Single(pick)
    }
}

/// 1-ply best response on the forward model + linear evaluator.
pub struct GreedyBot {
    weights: Weights,
}

impl Bot for GreedyBot {
    fn name(&self) -> &'static str {
        GREEDY
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let pm = ctx.peek.unwrap_or_else(|| Mv { move_index: 0, extra_data: 0 });
        Action::Single(greedy::decide(ctx.sim, ctx.seat, ctx.singles_view(), pm, ctx.rng, &self.weights))
    }
}

/// The on-chain heuristic ladder.
pub struct HeuristicBot {
    weights: Weights,
    state: HeuristicState,
}

impl Bot for HeuristicBot {
    fn name(&self) -> &'static str {
        HEURISTIC
    }
    fn reset(&mut self) {
        self.state = HeuristicState::default();
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let pm = ctx.peek.unwrap_or_else(|| Mv { move_index: 0, extra_data: 0 });
        Action::Single(heuristic::decide(
            ctx.sim,
            ctx.seat,
            ctx.singles_view(),
            pm,
            ctx.rng,
            &mut self.state,
            &self.weights,
        ))
    }
}

/// Scripted per-mon overrides, falling back to the heuristic.
pub struct OverrideBot {
    weights: Weights,
    state: OverrideState,
}

impl Bot for OverrideBot {
    fn name(&self) -> &'static str {
        OVERRIDE
    }
    fn reset(&mut self) {
        self.state = OverrideState::default();
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let pm = ctx.peek.unwrap_or_else(|| Mv { move_index: 0, extra_data: 0 });
        Action::Single(override_cpu::decide(
            ctx.sim,
            ctx.seat,
            ctx.singles_view(),
            pm,
            ctx.rng,
            &mut self.state,
            &self.weights,
        ))
    }
}

/// Greedy that never reads the reveal, aggregating over the opponent's replies.
pub struct NoPeekBot {
    weights: Weights,
    worst_case: bool,
}

impl Bot for NoPeekBot {
    fn name(&self) -> &'static str {
        if self.worst_case {
            NOPEEK_WC
        } else {
            NOPEEK
        }
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let mv = if self.worst_case {
            nopeek::decide_worst(ctx.sim, ctx.seat, ctx.singles_view(), ctx.rng, &self.weights)
        } else {
            nopeek::decide_expect(ctx.sim, ctx.seat, ctx.singles_view(), ctx.rng, &self.weights)
        };
        Action::Single(mv)
    }
}

/// Simultaneous-move maximin search over the evaluator.
pub struct SearchBot {
    weights: Weights,
    depth: u32,
    peek: bool,
    mixed: bool,
    opts: crate::search::SearchOpts,
    window: [Option<Mv>; 6],
    window_at: usize,
}

impl Bot for SearchBot {
    fn name(&self) -> &'static str {
        match self.depth {
            1 => SEARCH_D1,
            2 => SEARCH_D2,
            _ => SEARCH,
        }
    }
    fn reset(&mut self) {
        self.window = [None; 6];
        self.window_at = 0;
    }
    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        if let Some(pm) = ctx.peek {
            self.window[self.window_at % 6] = Some(pm);
            self.window_at += 1;
        }
        // Modal count of the revealed move over the last 6 turns — repetition with
        // interruptions (pivot resets, Sneak Attack recycling) still registers.
        let streak = self
            .window
            .iter()
            .flatten()
            .map(|m| self.window.iter().flatten().filter(|x| x == &m).count())
            .max()
            .unwrap_or(0) as u32;
        let pm = ctx.peek.unwrap_or_else(|| Mv { move_index: 0, extra_data: 0 });
        let opts = crate::search::SearchOpts { opp_streak: streak, ..self.opts };
        Action::Single(search::decide_with(
            ctx.sim,
            ctx.seat,
            ctx.singles_view(),
            pm,
            &self.weights,
            self.depth,
            self.peek,
            self.mixed,
            ctx.rng,
            &opts,
        ))
    }
}

/// Build a registered bot, or None if the name is unknown.
///
/// A configured search depth outranks the name: the seat searches over that
/// bot's evaluator instead of playing it. That is the pre-trait behaviour and
/// the arena's weight/depth sweeps depend on it.
pub fn build(name: &str, cfg: BotConfig) -> Option<Box<dyn Bot>> {
    let pinned = matches!(name, SEARCH_D1 | SEARCH_D2 | DOUBLES_SEARCH_D1 | DOUBLES_SEARCH_D2);
    if cfg.search_depth >= 1 && name != RANDOM && !pinned && !DOUBLES_NAMES.contains(&name) {
        return Some(Box::new(SearchBot {
            weights: cfg.weights,
            depth: cfg.search_depth,
            peek: cfg.search_peek,
            mixed: cfg.search_mixed,
            opts: cfg.search_opts,
            window: [None; 6],
            window_at: 0,
        }));
    }
    let w = cfg.weights;
    match name {
        RANDOM => Some(Box::new(RandomBot)),
        EXAMPLE => Some(Box::new(crate::example_bot::ExampleBot::new(w))),
        GREEDY => Some(Box::new(GreedyBot { weights: w })),
        HEURISTIC => Some(Box::new(HeuristicBot { weights: w, state: HeuristicState::default() })),
        OVERRIDE => Some(Box::new(OverrideBot { weights: w, state: OverrideState::default() })),
        NOPEEK => Some(Box::new(NoPeekBot { weights: w, worst_case: false })),
        NOPEEK_WC => Some(Box::new(NoPeekBot { weights: w, worst_case: true })),
        SEARCH_D1 | SEARCH_D2 => Some(Box::new(SearchBot {
            weights: w,
            depth: if name == SEARCH_D1 { 1 } else { 2 },
            peek: cfg.search_peek,
            mixed: cfg.search_mixed,
            opts: cfg.search_opts,
            window: [None; 6],
            window_at: 0,
        })),
        DOUBLES_SEARCH_D1 | DOUBLES_SEARCH_D2 => Some(Box::new(DoublesSearchBot {
            depth: if name == DOUBLES_SEARCH_D1 { 1 } else { 2 },
            eval: cfg.doubles_eval,
            move_used_bitmap: 0,
        })),
        SEARCH => Some(Box::new(SearchBot {
            weights: w,
            depth: cfg.search_depth.max(1),
            peek: cfg.search_peek,
            mixed: cfg.search_mixed,
            opts: cfg.search_opts,
            window: [None; 6],
            window_at: 0,
        })),
        DOUBLES_EASY => Some(Box::new(DoublesGreedyBot { name: DOUBLES_EASY, difficulty: Difficulty::Easy })),
        DOUBLES_MEDIUM => {
            Some(Box::new(DoublesGreedyBot { name: DOUBLES_MEDIUM, difficulty: Difficulty::Medium }))
        }
        DOUBLES_HARD => Some(Box::new(DoublesGreedyBot { name: DOUBLES_HARD, difficulty: Difficulty::Hard })),
        DOUBLES_SEARCH => Some(Box::new(DoublesSearchBot {
            depth: cfg.search_depth.max(1),
            eval: cfg.doubles_eval,
            move_used_bitmap: 0,
        })),
        DOUBLES_SPARSE => {
            Some(Box::new(DoublesSparseBot { lean: false, eval: cfg.doubles_eval, move_used_bitmap: 0 }))
        }
        DOUBLES_SPARSE_LEAN => {
            Some(Box::new(DoublesSparseBot { lean: true, eval: cfg.doubles_eval, move_used_bitmap: 0 }))
        }
        _ => None,
    }
}

/// Resolve a name (e.g. from a CLI flag) to its registry entry.
pub fn parse(name: &str) -> Option<&'static str> {
    NAMES.iter().chain(DOUBLES_NAMES.iter()).copied().find(|&n| n == name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::arena::build_team_mon;
    use crate::game::{play_game, GameSpec};
    use crate::roster::{address_book, load_roster};
    use std::path::PathBuf;

    /// Every registered bot can pilot a full game. This is the smoke test an
    /// entrant runs first: if a new bot is in `NAMES`, it plays here.
    #[test]
    fn every_registered_bot_plays() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..");
        let root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or(root);
        let roster = load_roster(&root);
        let book = address_book();
        let ids: Vec<u32> = roster.mons.iter().take(4).map(|m| m.id).collect();
        let team: Vec<_> = roster.mons.iter().take(4).map(build_team_mon).collect();

        for &name in NAMES {
            assert!(parse(name).is_some(), "{name} missing from the registry");
            let spec = GameSpec {
                seed: 7,
                max_turns: 60,
                mons_per_team: 4,
                p0_team: team.clone(),
                p1_team: team.clone(),
                p0_ids: ids.clone(),
                p1_ids: ids.clone(),
                field: crate::sim::Field::None,
                p0_strategy: name,
                p1_strategy: GREEDY,
                peek_seat: None,
                p0_weights: crate::evaluator::DEFAULT_WEIGHTS,
                p1_weights: crate::evaluator::DEFAULT_WEIGHTS,
                p0_search_depth: 0,
                p1_search_depth: 0,
                p0_search_peek: false,
                p1_search_peek: false,
                p0_search_mixed: false,
                p1_search_mixed: false,
                p0_search_opts: Default::default(),
                p1_search_opts: Default::default(),
            };
            let out = play_game(&spec, &book, false);
            assert!(out.turns > 0, "{name} produced no turns");
        }
    }

    /// Every registered doubles bot can pilot a full doubles game.
    #[test]
    fn every_registered_doubles_bot_plays() {
        use crate::doubles::{play_doubles_game, DoublesEvalW, DoublesSpec, Difficulty};
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..");
        let root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or(root);
        let roster = load_roster(&root);
        let book = address_book();
        let ids: Vec<u32> = roster.mons.iter().take(4).map(|m| m.id).collect();
        let team: Vec<_> = roster.mons.iter().take(4).map(build_team_mon).collect();

        for &name in DOUBLES_NAMES {
            assert!(parse(name).is_some(), "{name} missing from the registry");
            let spec = DoublesSpec {
                seed: 11,
                max_turns: 60,
                mons_per_team: 4,
                p0_team: team.clone(),
                p1_team: team.clone(),
                p0_ids: ids.clone(),
                p1_ids: ids.clone(),
                field: crate::sim::Field::None,
                p0_difficulty: Difficulty::Hard,
                p1_difficulty: Difficulty::Hard,
                p0_bot: name,
                p1_bot: DOUBLES_HARD,
                p0_search_depth: 0,
                p1_search_depth: 0,
                p0_eval: DoublesEvalW::default(),
                p1_eval: DoublesEvalW::default(),
            };
            let out = play_doubles_game(&spec, &book);
            assert!(out.turns > 0, "{name} produced no turns");
        }
    }

    /// Salts depend on the seed alone, so swapping one seat's bot cannot change
    /// the battle the other seat faces. This is what makes entrants comparable.
    #[test]
    fn seat_streams_are_independent() {
        use crate::jsrng::{derive, random_salt, STREAM_SALT};
        for seed in [1u32, 42, 0xbeef] {
            let mut a = derive(seed, STREAM_SALT);
            let mut b = derive(seed, STREAM_SALT);
            for _ in 0..8 {
                assert_eq!(random_salt(&mut a), random_salt(&mut b));
            }
        }
    }
}
