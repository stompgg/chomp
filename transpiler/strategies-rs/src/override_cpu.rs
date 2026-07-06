//! OVERRIDE CPU — port of `sims/src/cpu/strategies/override-cpu.ts`: a
//! scripted-plan pilot wrapping the hard CPU. For the active mon it
//! consults a per-mon script (ordered rules with `when` / max-uses
//! gates); the first rule whose move is affordable this turn and whose
//! gate passes is played, otherwise the whole decision delegates to hard.
//!
//! Mons are keyed by BASE HP (unique per mon, see drool/mons.csv).
//!
//! Parity notes: on a script-mon turn the candidate enumeration runs
//! HERE and — when no rule fires — AGAIN inside the hard fallback,
//! consuming the rng stream twice, exactly like the TS wrapper. The
//! `incomingLethal` fact forks with salt 0 and reads false if the fork
//! panics (the TS try/catch).

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};

use crate::hard::{self, HardState};
use crate::jsrng::JsRng;
use crate::native::{fork_measure_incoming_damage, ForkCache};
use crate::sim::Sim;
use crate::view::{
    calculate_valid_moves, mon_current_hp, mon_current_speed, mon_current_stamina, mon_max_hp,
    BattleView, Mv, Seat, SWITCH_MOVE_INDEX, VCPU, VOPP,
};

/// Read-only position facts a `when` predicate can gate on.
#[derive(Clone, Copy)]
pub struct OverrideCtx {
    /// CPU active mon current HP / max HP, in [0, 1].
    pub hp_frac: f64,
    /// CPU active mon current stamina.
    pub stamina: i64,
    /// CPU active mon outspeeds the opponent's active mon.
    pub outspeeds: bool,
    /// The opponent's revealed move this turn would KO the CPU active mon.
    pub incoming_lethal: bool,
    /// The opponent's revealed move index (SWITCH/NO_OP when not attacking).
    pub opp_move_index: u8,
    /// Turns elapsed this game.
    pub turn: u32,
    /// How many times THIS rule has already fired this game.
    pub uses: u32,
}

pub struct OverrideRule {
    /// Move slot 0-3 to play.
    pub mv: u8,
    /// Optional gate; the rule only fires when this returns true.
    pub when: Option<fn(&OverrideCtx) -> bool>,
    /// Fire at most N times per game (TS `once` == Some(1)).
    pub max_uses: Option<u32>,
    /// Force a specific extraData target; None = the engine-picked target.
    pub extra_data: Option<u16>,
    /// Human label for logs / doc parity with the TS scripts.
    pub label: &'static str,
}

const fn rule(mv: u8, when: Option<fn(&OverrideCtx) -> bool>, max_uses: Option<u32>, label: &'static str) -> OverrideRule {
    OverrideRule { mv, when, max_uses, extra_data: None, label }
}

fn aurox_iron_wall(c: &OverrideCtx) -> bool {
    c.hp_frac > 0.9 && c.stamina >= 3
}
fn under_half_hp(c: &OverrideCtx) -> bool {
    c.hp_frac < 0.5
}
fn stamina_ge_3(c: &OverrideCtx) -> bool {
    c.stamina >= 3
}
fn stamina_lt_3(c: &OverrideCtx) -> bool {
    c.stamina < 3
}

/// Scripts keyed by base HP — kept rule-for-rule identical to
/// `OVERRIDE_SCRIPTS` in the TS registry (same ordering, gates, labels).
fn script_for(base_hp: i64) -> Option<&'static [OverrideRule]> {
    // Aurox: the tank line — Iron Wall on a fresh, stamina-flush entry,
    // then Bull Rush as the default so Up Only ramps behind the regen.
    static AUROX: &[OverrideRule] = &[
        rule(2, Some(aurox_iron_wall), Some(1), "Iron Wall on entry"),
        rule(3, None, None, "Bull Rush"),
    ];
    // Iblivion: the turn-1 Loop line — Loop once on entry, Brightback
    // sustain under half HP, Unbounded Strike as the default.
    static IBLIVION: &[OverrideRule] = &[
        rule(1, None, Some(1), "Loop on entry (+15%)"),
        rule(2, Some(under_half_hp), None, "Brightback sustain"),
        rule(0, None, None, "Unbounded Strike"),
    ];
    // Volthare: prefer Mega Star Blast whenever affordable.
    static VOLTHARE: &[OverrideRule] =
        &[rule(2, Some(stamina_ge_3), None, "Mega Star Blast preference")];
    // Embursa: arm Q5 once on the first action, then fall through to hard.
    static EMBURSA: &[OverrideRule] = &[rule(3, None, Some(1), "Arm Q5")];
    // Pengym: the committed Frostbite combo — tag, Deep Freeze while
    // affordable, re-tag while saving stamina.
    static PENGYM: &[OverrideRule] = &[
        rule(0, None, Some(1), "Chill Out tag"),
        rule(2, Some(stamina_ge_3), Some(2), "Deep Freeze"),
        rule(0, Some(stamina_lt_3), Some(2), "Chill Out while saving"),
    ];
    // Inutia: arm Chain Expansion once, hard for everything else.
    static INUTIA: &[OverrideRule] = &[rule(0, None, Some(1), "Arm Chain Expansion")];

    match base_hp {
        400 => Some(AUROX),
        277 => Some(IBLIVION),
        310 => Some(VOLTHARE),
        420 => Some(EMBURSA),
        371 => Some(PENGYM),
        351 => Some(INUTIA),
        _ => None,
    }
}

#[derive(Default)]
pub struct OverrideState {
    pub turn: u32,
    /// Fire counts keyed by (active mon slot, rule index) — per game.
    pub uses: HashMap<(usize, usize), u32>,
    pub fallback: HardState,
}

fn build_ctx(
    sim: &mut Sim,
    seat: Seat,
    view: &BattleView,
    active_idx: usize,
    pm: Mv,
    turn: u32,
) -> OverrideCtx {
    let bk = view.bk;
    let cur_hp = mon_current_hp(sim, seat, bk, VCPU, active_idx);
    let max_hp = mon_max_hp(sim, seat, bk, VCPU, active_idx);
    let opp_idx = view.opp_active;

    // Incoming lethal: only meaningful when the opponent actually attacks;
    // a fork that fails on an odd state just reads as non-lethal. (A panic
    // mid-fork can strand that fork's cloned maps until the per-game world
    // drops — bounded, and the TS reference leaks the same way.)
    let mut incoming_lethal = false;
    if pm.move_index < SWITCH_MOVE_INDEX {
        let mut fc = ForkCache::new();
        incoming_lethal = catch_unwind(AssertUnwindSafe(|| {
            fork_measure_incoming_damage(sim, seat, &mut fc, pm.move_index, pm.extra_data, None, 0) >= cur_hp
        }))
        .unwrap_or(false);
        fc.dispose_all(sim);
    }

    OverrideCtx {
        hp_frac: if max_hp > 0 { cur_hp as f64 / max_hp as f64 } else { 0.0 },
        stamina: mon_current_stamina(sim, seat, bk, VCPU, active_idx),
        outspeeds: mon_current_speed(sim, seat, bk, VCPU, active_idx)
            > mon_current_speed(sim, seat, bk, VOPP, opp_idx),
        incoming_lethal,
        opp_move_index: pm.move_index,
        turn,
        uses: 0,
    }
}

pub fn decide(
    sim: &mut Sim,
    seat: Seat,
    view: &BattleView,
    pm: Mv,
    rng: &mut JsRng,
    st: &mut OverrideState,
) -> Mv {
    let bk = view.bk;
    st.turn += 1;

    let active_idx = view.cpu_active;
    if let Some(script) = script_for(mon_max_hp(sim, seat, bk, VCPU, active_idx)) {
        // Affordable slots, each with a valid target (rng draws here AND
        // again in the fallback — the TS double-enumeration).
        let valid = calculate_valid_moves(sim, seat, bk, rng);
        let mut ctx: Option<OverrideCtx> = None;

        for (i, r) in script.iter().enumerate() {
            let key = (active_idx, i);
            let fired = *st.uses.get(&key).unwrap_or(&0);
            if let Some(max) = r.max_uses {
                if fired >= max {
                    continue;
                }
            }
            let Some(affordable) = valid.moves.iter().find(|m| m.move_index == r.mv) else {
                continue; // not castable this turn (stamina / forced-switch / etc.)
            };
            if let Some(pred) = r.when {
                if ctx.is_none() {
                    ctx = Some(build_ctx(sim, seat, view, active_idx, pm, st.turn));
                }
                let mut c = ctx.unwrap();
                c.uses = fired;
                if !pred(&c) {
                    continue;
                }
            }
            st.uses.insert(key, fired + 1);
            return Mv {
                move_index: affordable.move_index,
                extra_data: r.extra_data.unwrap_or(affordable.extra_data),
            };
        }
    }

    hard::decide(sim, seat, view, pm, rng, &mut st.fallback)
}
