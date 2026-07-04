//! Port of the TS-native shared helpers hard/greedy call
//! (`sims/src/cpu/heuristic-native.ts`): band picks, anti-wall pivot, and
//! the fork-based measurement/scoring kit. Fair-info pool analysis
//! (maxPoolDamage / evaluateDefensiveSwitchFair / …) is not ported — the
//! two shipped strategies never reach it.

use chomp_engine::moves::MoveSlotLib;
use chomp_engine::Structs::MoveMeta;
use chomp_rt::B256;

use crate::evaluator::score_state;
use crate::jsrng::JsRng;
use crate::shared::{
    find_best_damage_move, floor_div, offensive_matchup_score, SIMILAR_DAMAGE_THRESHOLD,
};
use crate::sim::{HypoMove, Sim};
use crate::view::{
    apply_hypothetical, capture_view, mon_current_hp, mon_stats, move_slot, pick_uniform,
    slot_external_accuracy, BattleView, Mv, Seat, NO_OP_INDEX, SWITCH_MOVE_INDEX, VCPU, VOPP,
};

/// A matchup is "walled" if our best move does LESS than this % of the
/// opponent active mon's CURRENT HP.
pub const WALL_DAMAGE_PCT: i64 = 5;

/// The tree's pick must be beaten by at least this much (scoreState units)
/// before the eval-veto overrides it.
pub const EVAL_OVERRIDE_MARGIN: f64 = 200.0;

/// Uniform pick inside the similar-damage band (within 85% of best).
/// Index into `moves`/`damages`, or -1 if no move deals damage.
pub fn pick_similar_damage_move(damages: &[i64], rng: &mut JsRng) -> isize {
    let mut best_damage = 0i64;
    for &d in damages {
        if d > best_damage {
            best_damage = d;
        }
    }
    if best_damage == 0 {
        return -1;
    }
    let threshold = floor_div(best_damage * SIMILAR_DAMAGE_THRESHOLD, 100);
    let band: Vec<usize> = (0..damages.len()).filter(|&i| damages[i] >= threshold).collect();
    band[pick_uniform(band.len(), rng).unwrap()] as isize
}

/// The reveal a fork-scored pivot pick measures against.
#[derive(Clone, Copy)]
pub struct ForkPick {
    pub reveal_idx: u8,
    pub reveal_extra: u16,
    pub salt: u128,
}

/// Anti-wall stalemate-breaker: index into `switches` of a strictly
/// better-matched bench mon when the active mon can't meaningfully damage
/// the opponent, else -1.
pub fn anti_wall_switch(
    sim: &mut Sim,
    seat: Seat,
    view: &BattleView,
    metas: &[MoveMeta],
    moves: &[Mv],
    damages: &[i64],
    switches: &[Mv],
    fork_pick: Option<ForkPick>,
) -> isize {
    if switches.is_empty() {
        return -1;
    }
    let bk = view.bk;
    let opponent_mon_index = view.opp_active;
    let opp_hp = mon_current_hp(sim, seat, bk, VOPP, opponent_mon_index);
    if opp_hp <= 0 {
        return -1;
    }

    // Progress check: best move >= WALL_DAMAGE_PCT% of opp current HP => stay.
    let best_idx = find_best_damage_move(metas, moves, damages);
    let best_dmg = if best_idx >= 0 { damages[best_idx as usize] } else { 0 };
    if best_dmg * 100 >= opp_hp * WALL_DAMAGE_PCT {
        return -1;
    }

    // Walled: only strictly-better offensive matchups qualify.
    let opp_stats = mon_stats(sim, seat, bk, VOPP, opponent_mon_index);
    let our_stats = mon_stats(sim, seat, bk, VCPU, view.cpu_active);
    let current_score = offensive_matchup_score(
        our_stats.type1, our_stats.type2, opp_stats.type1, opp_stats.type2,
    );
    let mut qualified: Vec<(usize, i64)> = Vec::new(); // (idx into switches, matchup)
    for (i, sw) in switches.iter().enumerate() {
        let cand_stats = mon_stats(sim, seat, bk, VCPU, sw.extra_data as usize);
        let score = offensive_matchup_score(
            cand_stats.type1, cand_stats.type2, opp_stats.type1, opp_stats.type2,
        );
        if score > current_score {
            qualified.push((i, score));
        }
    }
    if qualified.is_empty() {
        return -1;
    }

    // Pick the pivot TARGET by fork score when a reveal is available.
    if let Some(fp) = fork_pick {
        if qualified.len() > 1 {
            let mut best = qualified[0].0;
            let mut best_score = f64::NEG_INFINITY;
            for &(idx, _) in &qualified {
                let s = fork_score_action(sim, seat, fp.reveal_idx, fp.reveal_extra, switches[idx], fp.salt);
                if s > best_score {
                    best_score = s;
                    best = idx;
                }
            }
            return best as isize;
        }
    }
    let mut best = qualified[0];
    for &q in &qualified {
        if q.1 > best.1 {
            best = q;
        }
    }
    best.0 as isize
}

// ---------------------------------------------------------------------------
// Fork-based measurement (forward-model differential probes)
// ---------------------------------------------------------------------------

fn reveal_hypo(reveal_idx: u8, reveal_extra: u16, salt: u128) -> HypoMove {
    if reveal_idx == NO_OP_INDEX {
        HypoMove { move_index: NO_OP_INDEX, salt, extra_data: 0 }
    } else {
        HypoMove { move_index: reveal_idx, salt, extra_data: reveal_extra }
    }
}

pub struct MeasuredMoves {
    pub damages: Vec<i64>,
    pub scores: Vec<f64>,
    pub defender_mon_index: usize,
}

/// Measure OUR moves' damage by stepping the sim: (reveal, rest) baseline,
/// then (reveal, move_i) per candidate — the defender's HP gap is the REAL
/// damage; each fork's position score doubles as the eval-veto input.
pub fn fork_measure_move_damages(
    sim: &mut Sim,
    seat: Seat,
    reveal_idx: u8,
    reveal_extra: u16,
    moves: &[Mv],
    salt: u128,
) -> MeasuredMoves {
    let p0 = reveal_hypo(reveal_idx, reveal_extra, salt);

    let base_key = apply_hypothetical(
        sim, seat,
        Some(p0),
        Some(HypoMove { move_index: NO_OP_INDEX, salt, extra_data: 0 }),
    );
    let base = capture_view(sim, seat, base_key);
    let defender_mon_index = base.opp_active;
    let base_hp = base.p0[defender_mon_index].hp;
    sim.dispose_fork(base_key);

    let mut damages = Vec::with_capacity(moves.len());
    let mut scores = Vec::with_capacity(moves.len());
    for m in moves {
        let child_key = apply_hypothetical(
            sim, seat,
            Some(p0),
            Some(HypoMove { move_index: m.move_index, salt, extra_data: m.extra_data }),
        );
        let child = capture_view(sim, seat, child_key);
        let dealt = base_hp - child.p0[defender_mon_index].hp;
        scores.push(score_state(sim, seat, &child));
        sim.dispose_fork(child_key);
        damages.push(if dealt > 0 { dealt } else { 0 });
    }
    MeasuredMoves { damages, scores, defender_mon_index }
}

/// Eval-veto: fork-score every legal alternative against the same reveal;
/// Some(better) only when it beats `chosen` by >= EVAL_OVERRIDE_MARGIN.
#[allow(clippy::too_many_arguments)]
pub fn pick_eval_override(
    sim: &mut Sim,
    seat: Seat,
    reveal_idx: u8,
    reveal_extra: u16,
    chosen: Mv,
    moves: &[Mv],
    move_scores: &[f64],
    switches: &[Mv],
    no_op: &[Mv],
    salt: u128,
) -> Option<Mv> {
    let mut chosen_score: Option<f64> = None;
    let mut best: Option<Mv> = None;
    let mut best_score = f64::NEG_INFINITY;

    let mut consider = |m: Mv, score: f64| {
        if m == chosen {
            chosen_score = Some(score);
            return;
        }
        if score > best_score {
            best_score = score;
            best = Some(m);
        }
    };

    for i in 0..moves.len() {
        consider(moves[i], move_scores[i]);
    }
    for &m in switches.iter().chain(no_op.iter()) {
        let s = fork_score_action(sim, seat, reveal_idx, reveal_extra, m, salt);
        consider(m, s);
    }

    let chosen_score = chosen_score.unwrap_or_else(|| {
        // Chosen wasn't among the enumerated candidates — score it directly.
        fork_score_action(sim, seat, reveal_idx, reveal_extra, chosen, salt)
    });

    match best {
        Some(b) if best_score >= chosen_score + EVAL_OVERRIDE_MARGIN => Some(b),
        _ => None,
    }
}

/// EV-scale damages by each move's accuracy. Inline attacks always run
/// DEFAULT_ACCURACY (100); external moves expose `accuracy(battleKey)`
/// (unreadable => unchanged).
pub fn ev_scale_damages(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    mon_index: usize,
    moves: &[Mv],
    damages: &[i64],
) -> Vec<i64> {
    damages
        .iter()
        .enumerate()
        .map(|(i, &d)| {
            if d == 0 {
                return 0;
            }
            let Some(slot) = move_slot(sim, seat, bk, VCPU, mon_index, moves[i].move_index as usize)
            else {
                return d;
            };
            if MoveSlotLib::isInline(slot) {
                return d;
            }
            match slot_external_accuracy(sim, bk, slot) {
                None => d,
                Some(acc) => {
                    let acc = acc as i64;
                    if acc >= 100 || acc <= 0 {
                        d
                    } else {
                        floor_div(d * acc, 100)
                    }
                }
            }
        })
        .collect()
}

/// Measure ONE opponent move's damage to our side by stepping the sim.
/// `switch_target` None measures the current active staying in; Some(i)
/// measures that candidate's entry damage.
pub fn fork_measure_incoming_damage(
    sim: &mut Sim,
    seat: Seat,
    opp_move_index: u8,
    opp_extra_data: u16,
    switch_target: Option<usize>,
    salt: u128,
) -> i64 {
    if opp_move_index >= SWITCH_MOVE_INDEX {
        return 0; // a switch or rest deals nothing
    }

    let our_action = match switch_target {
        None => HypoMove { move_index: NO_OP_INDEX, salt, extra_data: 0 },
        Some(t) => HypoMove { move_index: SWITCH_MOVE_INDEX, salt, extra_data: t as u16 },
    };

    let baseline_key = apply_hypothetical(
        sim, seat,
        Some(HypoMove { move_index: NO_OP_INDEX, salt, extra_data: 0 }),
        Some(our_action),
    );
    let baseline = capture_view(sim, seat, baseline_key);
    let our_mon = switch_target.unwrap_or(baseline.cpu_active);
    let base_hp = baseline.p1[our_mon].hp;
    sim.dispose_fork(baseline_key);

    let child_key = apply_hypothetical(
        sim, seat,
        Some(HypoMove { move_index: opp_move_index, salt, extra_data: opp_extra_data }),
        Some(our_action),
    );
    let child = capture_view(sim, seat, child_key);
    let dealt = base_hp - child.p1[our_mon].hp;
    sim.dispose_fork(child_key);
    if dealt > 0 {
        dealt
    } else {
        0
    }
}

/// Fork one candidate action against the reveal; the resulting position's score.
pub fn fork_score_action(
    sim: &mut Sim,
    seat: Seat,
    reveal_idx: u8,
    reveal_extra: u16,
    action: Mv,
    salt: u128,
) -> f64 {
    let p0 = reveal_hypo(reveal_idx, reveal_extra, salt);
    let child_key = apply_hypothetical(
        sim, seat,
        Some(p0),
        Some(HypoMove { move_index: action.move_index, salt, extra_data: action.extra_data }),
    );
    let child = capture_view(sim, seat, child_key);
    let s = score_state(sim, seat, &child);
    sim.dispose_fork(child_key);
    s
}
