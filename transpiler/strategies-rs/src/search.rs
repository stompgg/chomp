//! Depth-limited simultaneous-move **maximin** search over the forward model.
//!
//! No-peek / production-faithful: at every ply the CPU maximizes and the
//! opponent minimizes the CPU-perspective value (a per-turn matrix game backed
//! up by its security value). Leaves score through the linear evaluator
//! (`score_state`, seat weights). Depth is capped at [`MAX_DEPTH`].
//!
//! Determinism: runs on a scratch rng copy + restored fork counter, disposes
//! every fork depth-first (only O(depth) live at once), and breaks ties by the
//! earliest candidate — so the choice is a pure function of the position.
//!
//! Combos: switches are enumerated at every node and never pruned by a 1-ply
//! score (which would hide a switch→attack line whose payoff is a turn away).

use std::panic::{catch_unwind, AssertUnwindSafe};

use chomp_rt::B256;

use crate::evaluator::{score_state, Weights};
use crate::jsrng::JsRng;
use crate::sim::{HypoMove, Sim};
use crate::view::{apply_hypothetical_from, calculate_valid_moves, capture_view, BattleView, Mv, Seat, NO_OP_INDEX};

/// Hard cap on search depth (ruled 2026-07-12).
pub const MAX_DEPTH: u32 = 3;
/// Branching cap per side per node — moves then switches (both combo-relevant)
/// are kept ahead of rest, so the cap trims trailing switches, never moves.
const MAX_ACTIONS: usize = 8; // 4 moves + 3 switches + rest — singles never truncates
const WIN: f64 = 1e9;
const LOSS: f64 = -1e9;
const SALT: u128 = 0;

/// Candidate enumeration draws payload targets from a NODE-LOCAL fixed-seed rng, so the tree
/// is independent of visit order — that's what makes the row prune truly argmax-invariant
/// (a shared stream would shift every later node's picks when a branch is skipped).
const ENUM_SEED: u32 = 0x5EED;

/// Candidate actions for `seat` at `key`: all moves + all switches + rest,
/// capped at [`MAX_ACTIONS`]. Rest is ALWAYS a candidate — banking stamina is
/// a real line (and the opponent model needs it too: greedy/heuristic rest).
fn candidates(sim: &mut Sim, seat: Seat, key: B256) -> Vec<Mv> {
    let mut local = JsRng::new(ENUM_SEED);
    let v = calculate_valid_moves(sim, seat, key, &mut local);
    let mut out: Vec<Mv> = Vec::with_capacity(v.moves.len() + v.switches.len() + v.no_op.len());
    out.extend(v.moves.iter().copied());
    out.extend(v.switches.iter().copied());
    out.extend(v.no_op.iter().copied());
    out.truncate(MAX_ACTIONS);
    out
}

fn to_hypo(m: Option<Mv>) -> Option<HypoMove> {
    m.map(|m| HypoMove { move_index: m.move_index, salt: SALT, extra_data: m.extra_data })
}

/// Fork one ply from `key`: `my` is the CPU (VCPU) submission, `opp` the
/// opponent (VOPP); either is None on a forced-switch turn.
fn step(sim: &mut Sim, seat: Seat, key: B256, my: Option<Mv>, opp: Option<Mv>) -> B256 {
    apply_hypothetical_from(sim, seat, key, to_hypo(opp), to_hypo(my))
}

/// The two sides' action lists at `key` given the (virtual) switch flag:
/// 0 = opp-only acts, 1 = CPU-only acts, 2 = both. A non-acting side is `[None]`.
fn action_lists(sim: &mut Sim, seat: Seat, key: B256, flag: u8) -> (Vec<Option<Mv>>, Vec<Option<Mv>>) {
    let my = if flag != 0 {
        candidates(sim, seat, key).into_iter().map(Some).collect::<Vec<_>>()
    } else {
        vec![None]
    };
    let opp = if flag != 1 {
        let opp_seat = Seat { cpu: 1 - seat.cpu };
        candidates(sim, opp_seat, key).into_iter().map(Some).collect::<Vec<_>>()
    } else {
        vec![None]
    };
    let my = if my.is_empty() { vec![None] } else { my };
    let opp = if opp.is_empty() { vec![None] } else { opp };
    (my, opp)
}

/// Recursive maximin value of the position at `key`, CPU-perspective.
fn value(sim: &mut Sim, seat: Seat, key: B256, w: &Weights, depth: u32) -> f64 {
    let view = capture_view(sim, seat, key);
    let cpu_alive = view.p1.len() as i64 - (view.cpu_ko & 0xff).count_ones() as i64;
    let opp_alive = view.p0.len() as i64 - (view.opp_ko & 0xff).count_ones() as i64;
    // Mate-distance discounting: more remaining depth = terminal reached sooner.
    // Faster wins and later losses score strictly better — no dithering at the kill.
    if opp_alive <= 0 {
        return WIN + depth as f64;
    }
    if cpu_alive <= 0 {
        return LOSS - depth as f64;
    }
    if depth == 0 {
        return score_state(sim, seat, &view, w);
    }

    let (my, opp) = action_lists(sim, seat, key, view.switch_flag);
    let mut best = f64::NEG_INFINITY;
    for a in &my {
        let mut worst = f64::INFINITY;
        for o in &opp {
            let child = step(sim, seat, key, *a, *o);
            let v = value(sim, seat, child, w, depth - 1);
            sim.dispose_fork(child);
            if v < worst {
                worst = v;
            }
            if worst <= best {
                break; // row can no longer beat the best row — argmax-invariant prune
            }
        }
        if worst > best {
            best = worst;
        }
    }
    best
}

/// A safe legal move for the fallback path (first move → switch → rest).
fn fallback(sim: &mut Sim, seat: Seat, view: &BattleView, rng: &mut JsRng) -> Mv {
    if view.switch_flag == 0 {
        return Mv { move_index: NO_OP_INDEX, extra_data: 0 };
    }
    let v = calculate_valid_moves(sim, seat, view.bk, rng);
    v.moves
        .first()
        .or_else(|| v.switches.first())
        .or_else(|| v.no_op.first())
        .copied()
        .unwrap_or(Mv { move_index: NO_OP_INDEX, extra_data: 0 })
}

/// Nash mixed strategy of the row player in the zero-sum matrix game `g[i][j]` (row payoff), via
/// simultaneous regret matching for both players; the AVERAGE strategy converges to equilibrium.
/// Pure arithmetic on the already-computed grid — no forks. Dominant actions converge to pure.
fn nash_mix(g: &[Vec<f64>], iters: u32) -> Vec<f64> {
    let (n, m) = (g.len(), g[0].len());
    let positive = |r: &[f64]| -> Vec<f64> {
        let sum: f64 = r.iter().map(|&x| x.max(0.0)).sum();
        if sum > 0.0 {
            r.iter().map(|&x| x.max(0.0) / sum).collect()
        } else {
            vec![1.0 / r.len() as f64; r.len()]
        }
    };
    let (mut row_reg, mut col_reg) = (vec![0.0f64; n], vec![0.0f64; m]);
    let mut row_avg = vec![0.0f64; n];
    for _ in 0..iters {
        let (rs, cs) = (positive(&row_reg), positive(&col_reg));
        // Row action values vs the column mix; column action values vs the row mix (zero-sum).
        let row_u: Vec<f64> = (0..n).map(|i| (0..m).map(|j| cs[j] * g[i][j]).sum()).collect();
        let col_u: Vec<f64> = (0..m).map(|j| (0..n).map(|i| rs[i] * -g[i][j]).sum()).collect();
        let ru: f64 = (0..n).map(|i| rs[i] * row_u[i]).sum();
        let cu: f64 = (0..m).map(|j| cs[j] * col_u[j]).sum();
        for i in 0..n {
            row_reg[i] += row_u[i] - ru;
        }
        for j in 0..m {
            col_reg[j] += col_u[j] - cu;
        }
        for i in 0..n {
            row_avg[i] += rs[i];
        }
    }
    let sum: f64 = row_avg.iter().sum();
    row_avg.iter().map(|&x| x / sum.max(1e-12)).collect()
}

/// Choose the CPU's action by depth-`depth` search over the root my×opp payoff grid.
/// `mixed=false`: maximin argmax (pure, deterministic). `mixed=true`: solve the root matrix game
/// with regret matching and SAMPLE from the Nash mix (seeded rng — mind-games at yomi points,
/// pure automatically where an action dominates). A reverting hypothetical (checked-arithmetic
/// overflow deep in a fork — an unreachable state) would panic mid-search; we contain it to this
/// one decision and fall back to a legal move. Leaked forks are reclaimed when the world drops.
#[allow(clippy::too_many_arguments)]
pub fn decide(sim: &mut Sim, seat: Seat, view: &BattleView, pm: Mv, w: &Weights, depth: u32, peek: bool, mixed: bool, rng: &mut JsRng) -> Mv {
    let saved_fc = sim.fork_counter();
    match catch_unwind(AssertUnwindSafe(|| decide_inner(sim, seat, view, pm, w, depth, peek, mixed, rng))) {
        Ok(mv) => mv,
        Err(_) => {
            sim.set_fork_counter(saved_fc);
            fallback(sim, seat, view, rng)
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn decide_inner(sim: &mut Sim, seat: Seat, view: &BattleView, pm: Mv, w: &Weights, depth: u32, peek: bool, mixed: bool, rng: &mut JsRng) -> Mv {
    let depth = depth.clamp(1, MAX_DEPTH);
    let saved_fc = sim.fork_counter();
    let key = view.bk;

    // CPU passive (opp forced-switch) — nothing to choose.
    if view.switch_flag == 0 {
        sim.set_fork_counter(saved_fc);
        return Mv { move_index: NO_OP_INDEX, extra_data: 0 };
    }

    let (my, opp_full) = action_lists(sim, seat, key, view.switch_flag);
    // Peek-at-root: the opponent's move IS revealed this turn (`pm`) → best-respond to it (a single
    // opponent action), maximin only deeper. Without peek, the full no-peek grid at the root too.
    let opp = if peek && view.switch_flag != 1 { vec![Some(pm)] } else { opp_full };

    // Mixed play needs the FULL root grid (Nash weighs every cell) — no pruning here.
    if mixed && my.len() > 1 && opp.len() > 1 {
        let mut grid = vec![vec![0.0f64; opp.len()]; my.len()];
        for (i, a) in my.iter().enumerate() {
            for (j, o) in opp.iter().enumerate() {
                let child = step(sim, seat, key, *a, *o);
                grid[i][j] = value(sim, seat, child, w, depth - 1);
                sim.dispose_fork(child);
            }
        }
        sim.set_fork_counter(saved_fc);
        let mix = nash_mix(&grid, 1000);
        let r = rng.next(); // the LIVE stream — a real, seeded decision
        let mut acc = 0.0;
        for (i, &p) in mix.iter().enumerate() {
            acc += p;
            if r < acc {
                return my[i].unwrap_or(Mv { move_index: NO_OP_INDEX, extra_data: 0 });
            }
        }
        return my[my.len() - 1].unwrap_or(Mv { move_index: NO_OP_INDEX, extra_data: 0 });
    }

    // Pure maximin argmax (strict >: ties keep the earliest candidate — deterministic), with the
    // argmax-invariant row prune (a row whose running min can't beat the best row stops early).
    let mut best = my[0].unwrap_or(Mv { move_index: NO_OP_INDEX, extra_data: 0 });
    let mut best_val = f64::NEG_INFINITY;
    for a in &my {
        let mut worst = f64::INFINITY;
        for o in &opp {
            let child = step(sim, seat, key, *a, *o);
            let v = value(sim, seat, child, w, depth - 1);
            sim.dispose_fork(child);
            if v < worst {
                worst = v;
            }
            if worst <= best_val {
                break; // this action can no longer win the argmax — prune
            }
        }
        if worst > best_val {
            best_val = worst;
            if let Some(m) = a {
                best = *m;
            }
        }
    }
    sim.set_fork_counter(saved_fc);
    best
}
