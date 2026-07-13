//! Static position evaluation — port of `sims/src/cpu/evaluator.ts`.
//! The score is a linear function `φ(state)·w`: [`features`] reads the raw
//! feature vector, [`dot`] weights it. [`DEFAULT_WEIGHTS`] reproduces the
//! original hardcoded weights, so the default path is byte-identical.
//! Float ops mirror the TS source order exactly: f64 products summed
//! left-to-right, no reassociation, no FMA.

use crate::shared::{offensive_matchup_score, popcount8};
use crate::sim::Sim;
use crate::view::{
    mon_current_stamina, mon_skip_turn, mon_types, stat_delta_score, BattleView, MonSnap, Seat,
    VCPU, VOPP,
};

/// Feature-vector lanes (indices into [`features`] / [`Weights`]). This is the
/// BASELINE linear evaluator the `heuristic`/`greedy` pilots score with; the
/// learned CPU uses the raw-obs MLP in `mlp.rs` instead.
pub const F_HP: usize = 0;
pub const F_KO: usize = 1;
pub const F_MATCHUP: usize = 2;
pub const F_STAMINA: usize = 3;
pub const F_STAT_DELTA: usize = 4;
pub const F_SKIP: usize = 5;
pub const N_FEATURES: usize = 6;

/// A weight per feature lane.
pub type Weights = [f64; N_FEATURES];

/// The original hardcoded baseline weights — the byte-identical default.
pub const DEFAULT_WEIGHTS: Weights = [
    1.0,   // F_HP
    150.0, // F_KO
    0.5,   // F_MATCHUP
    2.0,   // F_STAMINA
    40.0,  // F_STAT_DELTA
    30.0,  // F_SKIP
];

/// hp% (0..100) for a slot — pure-view.
fn hp_percent(mon: &MonSnap) -> f64 {
    if mon.max_hp <= 0 {
        return 0.0;
    }
    (mon.hp.max(0) * 100) as f64 / mon.max_hp as f64
}

/// Raw feature vector, CPU-perspective. The lanes are the six original
/// terms (see the `F_*` indices); their computation order is unchanged.
pub fn features(sim: &mut Sim, seat: Seat, view: &BattleView) -> [f64; N_FEATURES] {
    // 1. HP swing: Σ cpu hp% − Σ opp hp% over all roster slots.
    let mut cpu_hp_pct = 0.0f64;
    for m in &view.p1 {
        cpu_hp_pct += hp_percent(m);
    }
    let mut opp_hp_pct = 0.0f64;
    for m in &view.p0 {
        opp_hp_pct += hp_percent(m);
    }
    let hp = cpu_hp_pct - opp_hp_pct;

    // 2. KO differential.
    let ko = (popcount8(view.opp_ko) - popcount8(view.cpu_ko)) as f64;

    // 3-6. Active-mon terms.
    let mut matchup = 0.0f64;
    let mut stamina = 0.0f64;
    let mut stat_delta = 0.0f64;
    let mut skip = 0.0f64;
    if view.cpu_active < view.p1.len() && view.opp_active < view.p0.len() {
        let bk = view.bk;
        let (c1, c2) = mon_types(sim, seat, bk, VCPU, view.cpu_active);
        let (o1, o2) = mon_types(sim, seat, bk, VOPP, view.opp_active);
        matchup = (offensive_matchup_score(c1, c2, o1, o2)
            - offensive_matchup_score(o1, o2, c1, c2)) as f64;
        stamina = (mon_current_stamina(sim, seat, bk, VCPU, view.cpu_active)
            - mon_current_stamina(sim, seat, bk, VOPP, view.opp_active)) as f64;
        stat_delta = stat_delta_score(sim, seat, bk, VCPU, view.cpu_active)
            - stat_delta_score(sim, seat, bk, VOPP, view.opp_active);
        let opp_skips = mon_skip_turn(sim, seat, bk, VOPP, view.opp_active);
        let cpu_skips = mon_skip_turn(sim, seat, bk, VCPU, view.cpu_active);
        skip = ((opp_skips as i64) - (cpu_skips as i64)) as f64;
    }

    let mut f = [0.0f64; N_FEATURES];
    f[F_HP] = hp;
    f[F_KO] = ko;
    f[F_MATCHUP] = matchup;
    f[F_STAMINA] = stamina;
    f[F_STAT_DELTA] = stat_delta;
    f[F_SKIP] = skip;
    f
}

/// φ·w, summed left-to-right (accumulator seeded with the first term, not
/// 0.0) so the default weights reproduce the original expression bit-for-bit.
pub fn dot(f: &[f64; N_FEATURES], w: &Weights) -> f64 {
    let mut acc = w[0] * f[0];
    let mut i = 1;
    while i < N_FEATURES {
        acc += w[i] * f[i];
        i += 1;
    }
    acc
}

/// Weighted position score, CPU-perspective (higher = better).
pub fn score_state(sim: &mut Sim, seat: Seat, view: &BattleView, w: &Weights) -> f64 {
    dot(&features(sim, seat, view), w)
}
