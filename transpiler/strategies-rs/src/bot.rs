//! The bot interface — what a benchmark entrant implements.
//!
//! A bot is handed the live battle and decides one turn. It may fork the
//! engine through `ctx.sim` and play hypotheticals forward: the forward model
//! is the real transpiled engine, not an approximation of it.
//!
//! Two rules matter for comparable results:
//!
//! - **Draw only from `ctx.rng`.** It is this seat's private stream, so how
//!   much a bot draws cannot shift the battle or its opponent.
//! - **Read the opponent's move only through `ctx.peek`.** It is `None` in
//!   blind mode, so a bot cannot accidentally depend on seeing a reveal.

use crate::evaluator::Weights;
use crate::jsrng::JsRng;
use crate::sim::Sim;
use crate::view::{BattleView, Mv, Seat};

/// How much a seat is told about the opponent's move.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InfoMode {
    /// Genuinely simultaneous: neither seat sees the other's move. Matches
    /// production play, and keeps the seats symmetric.
    Blind,
    /// One seat sees the reveal, alternating per game so that over a batch
    /// each seat peeks equally often.
    RotatePeek,
}

impl InfoMode {
    pub fn parse(name: &str) -> Option<InfoMode> {
        match name {
            "blind" => Some(InfoMode::Blind),
            "rotate" | "peek" => Some(InfoMode::RotatePeek),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            InfoMode::Blind => "blind",
            InfoMode::RotatePeek => "rotate-peek",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BattleMode {
    Singles,
    Doubles,
}

/// One turn's submission: a single move, or one per active slot in doubles.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Single(Mv),
    Slots([Mv; 2]),
}

impl Action {
    /// The singles move, taking slot 0 if a doubles bot answered.
    pub fn single(self) -> Mv {
        match self {
            Action::Single(mv) => mv,
            Action::Slots([mv, _]) => mv,
        }
    }
}

/// Everything a bot may look at when deciding.
pub struct DecisionCtx<'a> {
    /// The live battle. Fork it to evaluate hypotheticals.
    pub sim: &'a mut Sim,
    /// Which physical side this bot pilots.
    pub seat: Seat,
    /// Which mode this game is.
    pub mode: BattleMode,
    /// Singles position snapshot. `None` in doubles, where a single active pair
    /// cannot describe the board — doubles bots read `sim` directly.
    pub view: Option<&'a BattleView>,
    /// The opponent's move this turn — `None` in blind mode.
    pub peek: Option<Mv>,
    /// This seat's private stream.
    pub rng: &'a mut JsRng,
}

impl<'a> DecisionCtx<'a> {
    /// The singles snapshot. Panics in doubles, where it does not exist.
    pub fn singles_view(&self) -> &'a BattleView {
        self.view.expect("singles_view() called in doubles; read ctx.sim instead")
    }
}

/// Tuning a built-in bot reads at construction. Entrants are free to ignore it.
#[derive(Clone, Copy, Debug)]
pub struct BotConfig {
    pub weights: Weights,
    /// Eval weights for the doubles search tier; ignored by every other bot.
    pub doubles_eval: crate::doubles::DoublesEvalW,
    pub search_depth: u32,
    pub search_peek: bool,
    pub search_mixed: bool,
}

impl Default for BotConfig {
    fn default() -> Self {
        BotConfig {
            weights: crate::evaluator::DEFAULT_WEIGHTS,
            doubles_eval: crate::doubles::DoublesEvalW::default(),
            search_depth: 0,
            search_peek: false,
            search_mixed: false,
        }
    }
}

pub trait Bot: Send {
    /// Registry name; also the label in result tables.
    fn name(&self) -> &'static str;

    /// Modes this bot can pilot. Tables skip it for the rest.
    fn modes(&self) -> &'static [BattleMode] {
        &[BattleMode::Singles]
    }

    /// Clear per-game state. Called once before each game.
    fn reset(&mut self) {}

    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action;
}
