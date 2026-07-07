//! Static position evaluation — port of `sims/src/cpu/evaluator.ts` with
//! the DEFAULT weights (the arena's `greedy`/`hard` both score with them).
//! Float ops mirror the TS source order exactly: f64 products summed
//! left-to-right, no reassociation, no FMA.

use crate::shared::{offensive_matchup_score, popcount8};
use crate::sim::Sim;
use crate::view::{
    mon_current_stamina, mon_skip_turn, mon_types, stat_delta_score, BattleView, MonSnap, Seat,
    VCPU, VOPP,
};

const W_HP: f64 = 1.0;
const W_KO: f64 = 150.0;
const W_MATCHUP: f64 = 0.5;
const W_STAMINA: f64 = 2.0;
const W_STAT_DELTA: f64 = 40.0;
const W_SKIP: f64 = 30.0;

/// hp% (0..100) for a slot — pure-view.
fn hp_percent(mon: &MonSnap) -> f64 {
    if mon.max_hp <= 0 {
        return 0.0;
    }
    (mon.hp.max(0) * 100) as f64 / mon.max_hp as f64
}

/// Weighted sum of the six terms, CPU-perspective (higher = better).
pub fn score_state(sim: &mut Sim, seat: Seat, view: &BattleView) -> f64 {
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

    W_HP * hp
        + W_KO * ko
        + W_MATCHUP * matchup
        + W_STAMINA * stamina
        + W_STAT_DELTA * stat_delta
        + W_SKIP * skip
}
