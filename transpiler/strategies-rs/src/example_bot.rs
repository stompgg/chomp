//! A worked example — copy this file to start your own bot.
//!
//! It plays a one-ply search: try every legal action, simulate it on a fork of
//! the real engine, score the resulting position, keep the best. That is the
//! whole shape of a bot, and it is already enough to beat `random` badly and
//! `heuristic` narrowly.
//!
//! To enter your own:
//!   1. copy this file to `src/my_bot.rs` and rename the struct
//!   2. add `pub mod my_bot;` to `src/lib.rs`
//!   3. add a name constant and one `build` arm in `src/bots.rs`
//!   4. `./bench.sh run --bot my-bot`

use crate::bot::{Action, Bot, DecisionCtx};
use crate::evaluator::Weights;
use crate::native::ForkCache;
use crate::sim::HypoMove;
use crate::view::{calculate_valid_moves, Mv, NO_OP_INDEX};

pub struct ExampleBot {
    /// Weights the position evaluator scores with. Yours can score however you
    /// like — this is just what the built-in evaluator needs.
    pub weights: Weights,
}

impl ExampleBot {
    pub fn new(weights: Weights) -> Self {
        ExampleBot { weights }
    }
}

impl Bot for ExampleBot {
    fn name(&self) -> &'static str {
        "example"
    }

    fn decide(&mut self, ctx: &mut DecisionCtx<'_>) -> Action {
        let view = ctx.singles_view();

        // Every legal action this turn: moves, switches, and resting. Draw from
        // ctx.rng and nothing else — that is what keeps your games comparable
        // to everyone else's on the same seed.
        let valid = calculate_valid_moves(ctx.sim, ctx.seat, view.bk, ctx.rng);
        let candidates: Vec<Mv> = valid
            .moves
            .iter()
            .chain(valid.switches.iter())
            .chain(valid.no_op.iter())
            .copied()
            .collect();
        if candidates.is_empty() {
            return Action::Single(Mv { move_index: NO_OP_INDEX, extra_data: 0 });
        }

        // In blind mode ctx.peek is None and this is a guess; in peek mode it is
        // the opponent's real move. Reading it through ctx.peek is the only way
        // to see it, so a blind-mode bot cannot accidentally cheat.
        let assumed_reply = ctx.peek.unwrap_or(Mv { move_index: 0, extra_data: 0 });

        // On a forced-switch turn the opponent does not act at all.
        let opponent_acts = view.switch_flag != 1;

        let mut forks = ForkCache::new(self.weights);
        let mut best = candidates[0];
        let mut best_score = f64::NEG_INFINITY;

        for candidate in &candidates {
            let their_move = opponent_acts.then(|| HypoMove {
                move_index: assumed_reply.move_index,
                salt: 0,
                extra_data: assumed_reply.extra_data,
            });
            // Fork the live battle and play both moves onto the copy. This is
            // the real engine, so anything that would happen in a game happens
            // here: damage rolls, abilities, effects, KOs.
            let child = forks.fork(
                ctx.sim,
                ctx.seat,
                their_move,
                HypoMove {
                    move_index: candidate.move_index,
                    salt: 0,
                    extra_data: candidate.extra_data,
                },
            );
            let score = forks.score(ctx.sim, ctx.seat, child);
            if score > best_score {
                best_score = score;
                best = *candidate;
            }
        }
        // Always release forks — they stay resident in the world until disposed.
        forks.dispose_all(ctx.sim);

        Action::Single(best)
    }
}
