//! GREEDY (eval) — port of `sims/src/cpu/strategies/greedy-eval.ts` in its
//! registry configuration (salts=1, default weights): 1-ply best response
//! on the forward model + evaluator. The risk-aware multi-salt mode is not
//! ported — the arena's `greedy` never enables it, and with one sample the
//! risk-adjusted score IS the sample (mean of one, exact in f64).

use crate::jsrng::JsRng;
use crate::native::ForkCache;
use crate::sim::{HypoMove, Sim};
use crate::view::{calculate_valid_moves, pick_uniform, BattleView, Mv, Seat, NO_OP_INDEX};

pub fn decide(sim: &mut Sim, seat: Seat, view: &BattleView, pm: Mv, rng: &mut JsRng) -> Mv {
    let bk = view.bk;
    // Candidate CPU actions — rng draws Self/Opponent-index targets in the
    // shared enumeration order.
    let valid = calculate_valid_moves(sim, seat, bk, rng);
    let candidates: Vec<Mv> = valid
        .moves
        .iter()
        .chain(valid.switches.iter())
        .chain(valid.no_op.iter())
        .copied()
        .collect();
    if candidates.is_empty() {
        let mi = valid.no_op.first().map(|m| m.move_index).unwrap_or(NO_OP_INDEX);
        return Mv { move_index: mi, extra_data: 0 };
    }

    // Single-sample default keeps the original fixed salt (0).
    let salt: u128 = 0;

    // On a forced-switch turn (switchFlag === 1) p0 does not act.
    let p0_acts = view.switch_flag != 1;

    let mut fc = ForkCache::new();
    let mut best: Vec<Mv> = Vec::new();
    let mut best_score = f64::NEG_INFINITY;
    for cand in candidates {
        let p0_move = if p0_acts {
            Some(HypoMove { move_index: pm.move_index, salt, extra_data: pm.extra_data })
        } else {
            None
        };
        let child = fc.fork(
            sim, seat,
            p0_move,
            HypoMove { move_index: cand.move_index, salt, extra_data: cand.extra_data },
        );
        let score = fc.score(sim, seat, child);

        if score > best_score {
            best_score = score;
            best = vec![cand];
        } else if score == best_score {
            best.push(cand);
        }
    }
    fc.dispose_all(sim);

    pick_uniform(best.len(), rng).map(|i| best[i]).unwrap_or(best[0])
}
