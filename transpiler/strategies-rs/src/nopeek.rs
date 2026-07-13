//! No-peek pilot family + the my-action × their-action grid (measure.md, ruled 2026-07-08).
//!
//! Today's greedy/hard (and the p1 seat) see the opponent's revealed move. A *no-peek* pilot
//! decides from public state only: it scores each of its actions against the opponent's *plausible*
//! replies, aggregated by expectation (mean) or worst-case (min). The same grid is the yomi
//! substrate — yomi tension is the value of knowing the reply (EVPI over that grid).

use crate::evaluator::Weights;
use crate::jsrng::JsRng;
use crate::native::ForkCache;
use crate::sim::{HypoMove, Sim};
use crate::view::{calculate_valid_moves, pick_uniform, BattleView, Mv, Seat, NO_OP_INDEX};

const SALT: u128 = 0;

/// My candidates, the opponent's plausible replies (None = opponent doesn't act this turn), and the
/// score grid[my][opp] from MY seat's perspective. Compute-heavy: |my| × |opp| forks.
pub fn action_grid(
    sim: &mut Sim,
    seat: Seat,
    view: &BattleView,
    rng: &mut JsRng,
    fc: &mut ForkCache,
) -> (Vec<Mv>, Vec<Option<Mv>>, Vec<Vec<f64>>) {
    let bk = view.bk;
    let mv = calculate_valid_moves(sim, seat, bk, rng);
    let my: Vec<Mv> = mv.moves.iter().chain(mv.switches.iter()).chain(mv.no_op.iter()).copied().collect();

    // The opponent acts unless I'm on a forced-switch turn (virtual switch_flag == 1 = CPU-only).
    let opp_options: Vec<Option<Mv>> = if view.switch_flag != 1 {
        let opp_seat = Seat { cpu: 1 - seat.cpu };
        let ov = calculate_valid_moves(sim, opp_seat, bk, rng);
        let v: Vec<Mv> = ov.moves.iter().chain(ov.switches.iter()).chain(ov.no_op.iter()).copied().collect();
        if v.is_empty() {
            vec![None]
        } else {
            v.into_iter().map(Some).collect()
        }
    } else {
        vec![None]
    };

    let mut grid = vec![vec![f64::NEG_INFINITY; opp_options.len()]; my.len()];
    for (i, a) in my.iter().enumerate() {
        for (j, o) in opp_options.iter().enumerate() {
            let p0 = o.map(|m| HypoMove { move_index: m.move_index, salt: SALT, extra_data: m.extra_data });
            let child = fc.fork(sim, seat, p0, HypoMove { move_index: a.move_index, salt: SALT, extra_data: a.extra_data });
            grid[i][j] = fc.score(sim, seat, child);
        }
    }
    (my, opp_options, grid)
}

fn decide_agg(sim: &mut Sim, seat: Seat, view: &BattleView, rng: &mut JsRng, w: &Weights, worst_case: bool) -> Mv {
    let mut fc = ForkCache::new(*w);
    let (my, _opp, grid) = action_grid(sim, seat, view, rng, &mut fc);
    fc.dispose_all(sim);
    if my.is_empty() {
        return Mv { move_index: NO_OP_INDEX, extra_data: 0 };
    }
    let mut best: Vec<Mv> = Vec::new();
    let mut best_score = f64::NEG_INFINITY;
    for (i, a) in my.iter().enumerate() {
        let agg = if worst_case {
            grid[i].iter().copied().fold(f64::INFINITY, f64::min)
        } else {
            grid[i].iter().sum::<f64>() / grid[i].len().max(1) as f64
        };
        if agg > best_score {
            best_score = agg;
            best = vec![*a];
        } else if agg == best_score {
            best.push(*a);
        }
    }
    pick_uniform(best.len(), rng).map(|i| best[i]).unwrap_or(best[0])
}

/// No-peek greedy, expectation variant: maximize the mean score over the opponent's replies.
pub fn decide_expect(sim: &mut Sim, seat: Seat, view: &BattleView, rng: &mut JsRng, w: &Weights) -> Mv {
    decide_agg(sim, seat, view, rng, w, false)
}

/// No-peek greedy, worst-case variant: maximin over the opponent's replies (a counter-play pilot).
pub fn decide_worst(sim: &mut Sim, seat: Seat, view: &BattleView, rng: &mut JsRng, w: &Weights) -> Mv {
    decide_agg(sim, seat, view, rng, w, true)
}

/// Yomi tension = EVPI over the grid: mean_o[max_a grid[a][o]] − max_a[mean_o grid[a][o]]. Zero iff
/// one action is best against every reply (a dominant action → no tension). None when there is no
/// genuine two-sided decision (fewer than 2 of my actions or 2 opponent replies).
pub fn yomi_tension(grid: &[Vec<f64>]) -> Option<f64> {
    if grid.len() < 2 || grid[0].len() < 2 {
        return None;
    }
    let n_opp = grid[0].len();
    let mut sum_best = 0.0f64;
    for o in 0..n_opp {
        let mut best = f64::NEG_INFINITY;
        for row in grid {
            best = best.max(row[o]);
        }
        sum_best += best;
    }
    let read_right = sum_best / n_opp as f64;
    let mut commit = f64::NEG_INFINITY;
    for row in grid {
        let m = row.iter().sum::<f64>() / n_opp as f64;
        commit = commit.max(m);
    }
    Some((read_right - commit).max(0.0))
}
