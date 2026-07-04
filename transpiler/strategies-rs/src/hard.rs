//! HARD CPU — port of `sims/src/cpu/strategies/hard-cpu.ts`: best-response
//! with foreknowledge (peeks the revealed move), sim-measured damage on
//! both sides, guarded free-turn setup punishment, defensive switching,
//! anti-wall pivot, and the eval-veto wrapper. Every phase, threshold and
//! rng draw mirrors the TS source order.

use chomp_engine::Constants;
use chomp_engine::Enums::MoveClass;
use chomp_engine::Structs::{DamageCalcContext, MoveMeta};
use chomp_rt::{B256, U256};

use crate::jsrng::JsRng;
use crate::native::{
    anti_wall_switch, ev_scale_damages, fork_measure_incoming_damage, fork_measure_move_damages,
    fork_score_action, pick_eval_override, pick_similar_damage_move, ForkPick, MeasuredMoves,
    WALL_DAMAGE_PCT,
};
use crate::shared::{
    build_damage_calc_context, clear_move_used_bits_on_switch_in, compute_move_damages,
    estimate_damage, find_best_damage_move, find_ko_move, floor_div, get_move_base_power,
    has_momentum, select_best_switch, select_lead, try_configured_move, try_preferred_move,
    CONFIG_SETUP_MOVE, CONFIG_SWITCH_IN_MOVE, MAX_SAFE_INTEGER, SEVERE_DAMAGE_PCT_HELL,
    SWITCH_THRESHOLD,
};
use crate::sim::Sim;
use crate::view::{
    calculate_valid_moves, damage_calc_context, mon_current_hp, mon_current_speed,
    mon_current_stamina, mon_max_hp, mon_skip_turn, move_slot, slot_move_class, slot_priority,
    turn_id, BattleView, Mv, Seat, NO_OP_INDEX, SWITCH_MOVE_INDEX, VCPU, VOPP,
};

/// SWITCH priority in the Engine's priority comparison.
const SWITCH_PRIORITY: i64 = Constants::SWITCH_PRIORITY.as_limbs()[0] as i64;

/// Per-mon setup-move config (`BETTER_CPU_MON_CONFIG`): values stored as
/// moveIndex+1, 0 = unset. Only CONFIG_SETUP_MOVE is populated — the
/// switch-in / preferred lanes stay inert, like the TS table.
fn better_cpu_config(mon_index: usize, config_key: usize) -> u16 {
    if config_key != CONFIG_SETUP_MOVE {
        return 0;
    }
    match mon_index {
        1 => 2,  // Inutia   -> Initialize     (slot 1)
        2 => 1,  // Malalien -> Triple Think   (slot 0)
        3 => 2,  // Iblivion -> Loop           (slot 1)
        6 => 2,  // Pengym   -> Deadlift       (slot 1)
        7 => 3,  // Embursa  -> Heat Beacon    (slot 2)
        9 => 3,  // Aurox    -> Iron Wall      (slot 2)
        11 => 3, // Ekineki  -> Nine Nine Nine (slot 2)
        12 => 1, // Nirvamma -> Hard Reset     (slot 0)
        _ => 0,
    }
}

/// Per-battle persistent state: the configured-move lane bitmap (the
/// on-chain cpuMoveUsedBitmap semantics — setup fires once per switch-in).
#[derive(Default)]
pub struct HardState {
    pub move_used_bitmap: u32,
}

/// Decode the active mon's four move-slot metas (buildMetas): empty lanes
/// decode a raw 0 word, exactly like the TS `slot ?? 0n` (which would also
/// fail loudly on a real <4-move mon — arena mons always carry 4).
fn build_metas(sim: &mut Sim, seat: Seat, bk: B256, active_mon_index: usize) -> Vec<MoveMeta> {
    (0..4)
        .map(|i| {
            let slot = move_slot(sim, seat, bk, VCPU, active_mon_index, i).unwrap_or(U256::ZERO);
            crate::view::decode_meta(sim, bk, VCPU, active_mon_index, slot)
        })
        .collect()
}

/// `weGoFirst` — mirrors Engine.computePriorityPlayerIndex: higher priority
/// first; priority tie → faster mon; speed tie or slower → false.
fn we_go_first(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    metas: &[MoveMeta],
    our_mon_index: usize,
    opponent_mon_index: usize,
    our_move_index: u8,
    opponent_move_index: u8,
) -> bool {
    let our_priority: i64 = if our_move_index >= SWITCH_MOVE_INDEX {
        SWITCH_PRIORITY
    } else {
        metas[our_move_index as usize].priority as i64
    };

    let opp_priority: i64 = if opponent_move_index >= SWITCH_MOVE_INDEX {
        SWITCH_PRIORITY
    } else {
        let raw = move_slot(sim, seat, bk, VOPP, opponent_mon_index, opponent_move_index as usize)
            .expect("opponent move slot");
        slot_priority(sim, bk, VOPP, raw) as i64
    };

    if our_priority > opp_priority {
        return true;
    }
    if our_priority < opp_priority {
        return false;
    }
    mon_current_speed(sim, seat, bk, VCPU, our_mon_index)
        > mon_current_speed(sim, seat, bk, VOPP, opponent_mon_index)
}

/// `canOpponentKOUs`: does the revealed move KO our active mon?
fn can_opponent_ko_us(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    player_mon_index: usize,
    opponent_move_index: u8,
    damage_to_us: i64,
) -> bool {
    if opponent_move_index >= SWITCH_MOVE_INDEX {
        return false;
    }
    damage_to_us > 0 && damage_to_us >= mon_current_hp(sim, seat, bk, VCPU, player_mon_index)
}

/// `checkKOBypass`: best move deals >= 90% of opp current HP AND we
/// outspeed => stay in for the kill.
#[allow(clippy::too_many_arguments)]
fn check_ko_bypass(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    metas: &[MoveMeta],
    active_mon_index: usize,
    opponent_mon_index: usize,
    moves: &[Mv],
    damages: &[i64],
    player_move_index: u8,
) -> bool {
    let best_idx = find_best_damage_move(metas, moves, damages);
    if best_idx < 0 {
        return false;
    }
    let best_dmg = damages[best_idx as usize];
    if best_dmg == 0 {
        return false;
    }
    let opp_current_hp = mon_current_hp(sim, seat, bk, VOPP, opponent_mon_index);
    if opp_current_hp <= 0 {
        return false;
    }
    if best_dmg * 10 < opp_current_hp * 9 {
        return false;
    }
    we_go_first(
        sim, seat, bk, metas, active_mon_index, opponent_mon_index,
        moves[best_idx as usize].move_index, player_move_index,
    )
}

/// `findBestSwitchCandidate`: least damage-% switch-in vs the reveal.
#[allow(clippy::too_many_arguments)]
fn find_best_switch_candidate(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    opponent_mon_index: usize,
    opponent_move_index: u8,
    opponent_extra_data: u16,
    opp_move_slot: Option<U256>,
    opp_move_class: Option<MoveClass>,
    switches: &[Mv],
    salt: u128,
) -> (usize, i64, bool) {
    let mut best_idx = 0usize;
    let mut best_damage_pct = MAX_SAFE_INTEGER;
    let mut best_survives = false;

    for (i, sw) in switches.iter().enumerate() {
        let candidate_mon_index = sw.extra_data as usize;
        let can_estimate = opp_move_slot.is_some()
            && matches!(opp_move_class, Some(MoveClass::Physical) | Some(MoveClass::Special));
        let mut ctx = build_damage_calc_context(
            sim, seat, bk, VOPP, opponent_mon_index, VCPU, candidate_mon_index,
        );
        let static_dmg = if can_estimate {
            estimate_damage(sim, bk, &mut ctx, opp_move_slot.unwrap(), opp_move_class.unwrap())
        } else {
            0
        };
        let dmg = static_dmg.max(fork_measure_incoming_damage(
            sim, seat, opponent_move_index, opponent_extra_data, Some(candidate_mon_index), salt,
        ));

        let max_hp = mon_max_hp(sim, seat, bk, VCPU, candidate_mon_index);
        let cur_hp = mon_current_hp(sim, seat, bk, VCPU, candidate_mon_index);

        let damage_pct = if max_hp > 0 { floor_div(dmg * 100, max_hp) } else { MAX_SAFE_INTEGER };
        let survives = dmg < cur_hp;

        if damage_pct < best_damage_pct {
            best_damage_pct = damage_pct;
            best_idx = i;
            best_survives = survives;
        }
    }
    (best_idx, best_damage_pct, best_survives)
}

/// `evaluateDefensiveSwitch` — (shouldSwitch, switchIdx).
#[allow(clippy::too_many_arguments)]
fn evaluate_defensive_switch(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    active_mon_index: usize,
    opponent_mon_index: usize,
    opponent_move_index: u8,
    opponent_extra_data: u16,
    switches: &[Mv],
    severe_damage_pct: i64,
    ko_bypass_fires: bool,
    opp_move_slot: Option<U256>,
    opp_move_class: Option<MoveClass>,
    damage_to_us: i64,
    salt: u128,
) -> (bool, usize) {
    if ko_bypass_fires {
        return (false, 0);
    }
    if opponent_move_index >= SWITCH_MOVE_INDEX {
        return (false, 0);
    }
    if damage_to_us <= 0 {
        return (false, 0);
    }

    let our_max_hp = mon_max_hp(sim, seat, bk, VCPU, active_mon_index);
    let our_cur_hp = mon_current_hp(sim, seat, bk, VCPU, active_mon_index);

    let damage_pct_to_us = floor_div(damage_to_us * 100, our_max_hp);
    let lethal_to_us = damage_to_us >= our_cur_hp;

    if damage_pct_to_us < severe_damage_pct && !lethal_to_us {
        return (false, 0);
    }

    let (best_idx, best_damage_pct, best_survives) = find_best_switch_candidate(
        sim, seat, bk, opponent_mon_index, opponent_move_index, opponent_extra_data,
        opp_move_slot, opp_move_class, switches, salt,
    );

    if lethal_to_us && best_survives {
        return (true, best_idx);
    }
    if damage_pct_to_us >= best_damage_pct + SWITCH_THRESHOLD {
        return (true, best_idx);
    }
    (false, 0)
}

/// `isFreeTurnReveal`: a 0-power Self/Other reveal (setup / heal / hazard).
fn is_free_turn_reveal(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    opponent_mon_index: usize,
    player_move_index: u8,
) -> bool {
    if player_move_index >= SWITCH_MOVE_INDEX {
        return false;
    }
    let Some(slot) = move_slot(sim, seat, bk, VOPP, opponent_mon_index, player_move_index as usize)
    else {
        return false; // unreadable slot (TS catch path)
    };
    let opp_class = slot_move_class(sim, bk, slot);
    if opp_class != MoveClass::Other && opp_class != MoveClass::Self_ {
        return false;
    }
    get_move_base_power(sim, bk, slot) == 0
}

/// `freeTurnPick`: configured switch-in -> 2HKO -> momentum-guarded setup.
/// Returns (Some(picked move), bitmap) or (None, bitmap).
fn free_turn_pick(
    sim: &mut Sim,
    seat: Seat,
    view: &BattleView,
    mut move_used_bitmap: u32,
    metas: &[MoveMeta],
    moves: &[Mv],
    damages: &[i64],
) -> (Option<Mv>, u32) {
    let bk = view.bk;
    let active_mon_index = view.cpu_active;
    let opponent_mon_index = view.opp_active;

    // Configured switch-in move on this safe turn.
    let (idx, bm) =
        try_configured_move(better_cpu_config, move_used_bitmap, active_mon_index, moves, CONFIG_SWITCH_IN_MOVE, 0);
    move_used_bitmap = bm;
    if idx >= 0 {
        return (Some(moves[idx as usize]), move_used_bitmap);
    }

    let best_idx = find_best_damage_move(metas, moves, damages);
    let best_dmg = if best_idx >= 0 { damages[best_idx as usize] } else { 0 };
    let opp_current_hp = mon_current_hp(sim, seat, bk, VOPP, opponent_mon_index);
    // 2HKO uses opp CURRENT HP (a damaged opp is easier to finish).
    if best_idx >= 0 && opp_current_hp > 0 && best_dmg * 2 >= opp_current_hp {
        return (Some(moves[best_idx as usize]), move_used_bitmap);
    }

    // Setup only with momentum AND a matchup we can make progress in.
    let productive = opp_current_hp > 0 && best_dmg * 100 >= opp_current_hp * WALL_DAMAGE_PCT;
    if productive {
        let cpu_stamina = mon_current_stamina(sim, seat, bk, VCPU, view.cpu_active);
        if has_momentum(
            sim, seat, bk,
            view.p1.len(), view.cpu_ko, view.p0.len(), view.opp_ko,
            view.opp_active, cpu_stamina,
        ) {
            let (idx, bm) =
                try_configured_move(better_cpu_config, move_used_bitmap, active_mon_index, moves, CONFIG_SETUP_MOVE, 8);
            move_used_bitmap = bm;
            if idx >= 0 {
                return (Some(moves[idx as usize]), move_used_bitmap);
            }
        }
    }

    (None, move_used_bitmap)
}

pub fn decide(
    sim: &mut Sim,
    seat: Seat,
    view: &BattleView,
    pm: Mv,
    rng: &mut JsRng,
    st: &mut HardState,
) -> Mv {
    let (mv, bitmap) = decide_inner(sim, seat, view, pm, rng, st.move_used_bitmap);
    st.move_used_bitmap = bitmap; // every TS return path goes through DONE
    mv
}

/// The eval-veto wrapper (`ARB`): the tree's pick stands unless a forked
/// alternative clearly beats it; an override to a switch clears its lane bits.
#[allow(clippy::too_many_arguments)]
fn arb(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    player_move_index: u8,
    player_extra_data: u16,
    m: Mv,
    moves: &[Mv],
    move_scores: &[f64],
    switches: &[Mv],
    no_op: &[Mv],
    salt_seed: u128,
    move_used_bitmap: &mut u32,
) -> Mv {
    let better = pick_eval_override(
        sim, seat, player_move_index, player_extra_data, m, moves, move_scores, switches, no_op,
        salt_seed,
    );
    match better {
        None => m,
        Some(better) => {
            if better.move_index == SWITCH_MOVE_INDEX {
                *move_used_bitmap = clear_move_used_bits_on_switch_in(
                    sim, seat, bk, *move_used_bitmap, better.extra_data as usize,
                );
            }
            better
        }
    }
}

fn decide_inner(
    sim: &mut Sim,
    seat: Seat,
    view: &BattleView,
    pm: Mv,
    rng: &mut JsRng,
    mut move_used_bitmap: u32,
) -> (Mv, u32) {
    let bk = view.bk;

    // PEEK at the player's revealed move (we reply after the commit).
    let mut player_move_index = pm.move_index;
    let player_extra_data = pm.extra_data;

    // Single fixed policy: HELL severe-damage threshold, no mode branch.
    let severe_damage_pct = SEVERE_DAMAGE_PCT_HELL;

    // Enumerate valid options + decode the active mon's metas.
    let valid = calculate_valid_moves(sim, seat, bk, rng);
    let (no_op, moves, switches) = (&valid.no_op, &valid.moves, &valid.switches);
    let metas = build_metas(sim, seat, bk, view.cpu_active);

    // ── P0: Turn 0 — Lead Selection ── (a reused battle key resets the bitmap)
    if turn_id(sim, bk) == 0 {
        move_used_bitmap = 0;
        let lead = select_lead(sim, seat, bk, player_extra_data as usize, switches, false);
        move_used_bitmap =
            clear_move_used_bits_on_switch_in(sim, seat, bk, move_used_bitmap, lead.extra_data as usize);
        return (lead, move_used_bitmap);
    }

    let active_mon_index = view.cpu_active;
    let mut opponent_mon_index = view.opp_active;

    // A zapped opponent (ShouldSkipTurn) loses its revealed action entirely
    // — the reveal is VOID; play the free turn against the mon staying in.
    if mon_skip_turn(sim, seat, bk, VOPP, view.opp_active) {
        player_move_index = NO_OP_INDEX;
    }

    // ── P1: KO'd / Swap-Out Effect — Forced Switch ──
    if view.switch_flag == 1 || view.p1[view.cpu_active].ko {
        if switches.is_empty() {
            return (Mv { move_index: NO_OP_INDEX, extra_data: 0 }, move_used_bitmap);
        }
        let sw = select_best_switch(sim, seat, bk, opponent_mon_index, player_move_index, switches, false);
        move_used_bitmap =
            clear_move_used_bits_on_switch_in(sim, seat, bk, move_used_bitmap, sw.extra_data as usize);
        return (sw, move_used_bitmap);
    }

    // If the opponent is switching, target the incoming mon.
    if player_move_index == SWITCH_MOVE_INDEX {
        opponent_mon_index = player_extra_data as usize;
    }

    // Outgoing damage = max(static model, sim-measured), accuracy-EV-scaled.
    let mut attack_ctx: DamageCalcContext = if player_move_index == SWITCH_MOVE_INDEX {
        build_damage_calc_context(sim, seat, bk, VCPU, active_mon_index, VOPP, opponent_mon_index)
    } else {
        damage_calc_context(sim, seat, bk, VCPU, VOPP)
    };
    let static_damages = compute_move_damages(&mut attack_ctx, &metas, moves);
    let salt_seed = (turn_id(sim, bk) + 1) as u128;
    let measured: MeasuredMoves =
        fork_measure_move_damages(sim, seat, player_move_index, player_extra_data, moves, salt_seed);
    let maxed: Vec<i64> = static_damages
        .iter()
        .zip(measured.damages.iter())
        .map(|(&s, &m)| s.max(m))
        .collect();
    let damages = ev_scale_damages(sim, seat, bk, active_mon_index, moves, &maxed);

    // The TS `return ARB(m, phase)` one-liner: eval-veto the tree's pick,
    // then write the bitmap back (DONE). All invariant args are locals in
    // scope at every expansion site.
    macro_rules! arb_ret {
        ($m:expr) => {{
            let r = arb(
                sim, seat, bk, player_move_index, player_extra_data, $m, moves,
                &measured.scores, switches, no_op, salt_seed, &mut move_used_bitmap,
            );
            return (r, move_used_bitmap);
        }};
    }

    // Hoist the opp-threat computation ONCE (P2 + P5 both consume it).
    let mut opp_move_slot: Option<U256> = None;
    let mut opp_move_class: Option<MoveClass> = None;
    let mut damage_to_us: i64 = 0;
    if player_move_index < SWITCH_MOVE_INDEX {
        if let Some(slot) =
            move_slot(sim, seat, bk, VOPP, opponent_mon_index, player_move_index as usize)
        {
            let mc = slot_move_class(sim, bk, slot);
            opp_move_slot = Some(slot);
            opp_move_class = Some(mc);
            if mc == MoveClass::Physical || mc == MoveClass::Special {
                let mut ctx_to_us = damage_calc_context(sim, seat, bk, VOPP, VCPU);
                damage_to_us = estimate_damage(sim, bk, &mut ctx_to_us, slot, mc);
            }
        }
        // True reveal damage from the sim; the static estimate stays as the
        // floor only when the fork measures nothing (fixed-salt miss).
        let measured_to_us =
            fork_measure_incoming_damage(sim, seat, player_move_index, player_extra_data, None, salt_seed);
        if measured_to_us > 0 {
            damage_to_us = measured_to_us;
        }
    }

    // ── P2: Can We KO the Opponent? ──
    let ko_move_idx = find_ko_move(sim, seat, bk, opponent_mon_index, &metas, moves, &damages);
    if ko_move_idx >= 0 {
        let opponent_can_ko_us =
            can_opponent_ko_us(sim, seat, bk, active_mon_index, player_move_index, damage_to_us);
        if !opponent_can_ko_us
            || we_go_first(
                sim, seat, bk, &metas, active_mon_index, opponent_mon_index,
                moves[ko_move_idx as usize].move_index, player_move_index,
            )
        {
            arb_ret!(moves[ko_move_idx as usize]);
        }
        // else: opponent outspeeds us and can KO — fall through to P5.
    }

    // ── P3: Opponent is Switching ── (telegraphed free turn)
    if player_move_index == SWITCH_MOVE_INDEX {
        let (picked, bm) = free_turn_pick(sim, seat, view, move_used_bitmap, &metas, moves, &damages);
        move_used_bitmap = bm;
        if let Some(m) = picked {
            arb_ret!(m);
        }
        if !moves.is_empty() {
            let best_move = pick_similar_damage_move(&damages, rng);
            if best_move >= 0 {
                arb_ret!(moves[best_move as usize]);
            }
        }
        arb_ret!(no_op[0]); // rest on free turn
    }

    // ── P4: Opponent is Resting ── (same free-turn punish as P3)
    if player_move_index == NO_OP_INDEX {
        if moves.is_empty() {
            arb_ret!(no_op[0]); // both rest
        }
        let (picked, bm) = free_turn_pick(sim, seat, view, move_used_bitmap, &metas, moves, &damages);
        move_used_bitmap = bm;
        if let Some(m) = picked {
            arb_ret!(m);
        }
        let best_move = pick_similar_damage_move(&damages, rng);
        if best_move >= 0 {
            arb_ret!(moves[best_move as usize]);
        }
        arb_ret!(no_op[0]);
    }

    // ── P4.5: Free-turn setup-punishment — 0-power Self/Other reveal.
    if is_free_turn_reveal(sim, seat, bk, opponent_mon_index, player_move_index) {
        let (picked, bm) = free_turn_pick(sim, seat, view, move_used_bitmap, &metas, moves, &damages);
        move_used_bitmap = bm;
        if let Some(m) = picked {
            arb_ret!(m);
        }
    }

    // ── P5: Opponent Using a Move — Evaluate Defensive Switch ──
    if !switches.is_empty() {
        let ko_bypass_fires = !moves.is_empty()
            && check_ko_bypass(
                sim, seat, bk, &metas, active_mon_index, opponent_mon_index, moves, &damages,
                player_move_index,
            );
        let (should_switch, switch_idx) = evaluate_defensive_switch(
            sim, seat, bk, active_mon_index, opponent_mon_index, player_move_index,
            player_extra_data, switches, severe_damage_pct, ko_bypass_fires, opp_move_slot,
            opp_move_class, damage_to_us, salt_seed,
        );
        if should_switch {
            // Cross-check: only switch if the fork says it beats staying in.
            let stay_idx = find_best_damage_move(&metas, moves, &damages);
            let sw_score = fork_score_action(
                sim, seat, player_move_index, player_extra_data, switches[switch_idx], salt_seed,
            );
            if stay_idx < 0 || sw_score >= measured.scores[stay_idx as usize] {
                move_used_bitmap = clear_move_used_bits_on_switch_in(
                    sim, seat, bk, move_used_bitmap, switches[switch_idx].extra_data as usize,
                );
                arb_ret!(switches[switch_idx]);
            }
            arb_ret!(moves[stay_idx as usize]);
        }
    }

    // ── P5.5: Anti-wall stalemate-breaker ──
    if !switches.is_empty() {
        let anti_wall_idx = anti_wall_switch(
            sim, seat, view, &metas, moves, &damages, switches,
            Some(ForkPick {
                reveal_idx: player_move_index,
                reveal_extra: player_extra_data,
                salt: salt_seed,
            }),
        );
        if anti_wall_idx >= 0 {
            move_used_bitmap = clear_move_used_bits_on_switch_in(
                sim, seat, bk, move_used_bitmap, switches[anti_wall_idx as usize].extra_data as usize,
            );
            arb_ret!(switches[anti_wall_idx as usize]);
        }
    }

    // ── P6: Default — Best Damaging Move (sampled from the 85% band) ──
    if !moves.is_empty() {
        let (idx, bm) = try_configured_move(
            better_cpu_config, move_used_bitmap, active_mon_index, moves, CONFIG_SWITCH_IN_MOVE, 0,
        );
        move_used_bitmap = bm;
        if idx >= 0 {
            arb_ret!(moves[idx as usize]);
        }

        let preferred_move =
            try_preferred_move(better_cpu_config, active_mon_index, &mut attack_ctx, &metas, moves);
        if preferred_move >= 0 {
            arb_ret!(moves[preferred_move as usize]);
        }

        let best_move = pick_similar_damage_move(&damages, rng);
        if best_move >= 0 {
            arb_ret!(moves[best_move as usize]);
        }
    }

    // Stuck fallback — take the best forked position outright (no ARB).
    let mut fb_best = no_op.first().copied().unwrap_or(Mv { move_index: NO_OP_INDEX, extra_data: 0 });
    let mut fb_score = f64::NEG_INFINITY;
    for i in 0..moves.len() {
        if measured.scores[i] > fb_score {
            fb_score = measured.scores[i];
            fb_best = moves[i];
        }
    }
    for &m in switches.iter().chain(no_op.iter()) {
        let s = fork_score_action(sim, seat, player_move_index, player_extra_data, m, salt_seed);
        if s > fb_score {
            fb_score = s;
            fb_best = m;
        }
    }
    if fb_best.move_index == SWITCH_MOVE_INDEX {
        move_used_bitmap = clear_move_used_bits_on_switch_in(
            sim, seat, bk, move_used_bitmap, fb_best.extra_data as usize,
        );
    }
    (fb_best, move_used_bitmap)
}
