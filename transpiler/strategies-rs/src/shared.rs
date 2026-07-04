//! Port of the `HeuristicCPUBase.sol` helpers hard/greedy actually reach
//! (`sims/src/cpu/heuristic-shared.ts`). TS helpers neither strategy calls
//! (mode ladder, fair-info pool analysis, random-option pick, …) are
//! deliberately not ported. Every branch/threshold/formula matches the TS
//! source; integer math stays integral (i64), `Math.floor(int/int)` sites
//! reproduce the JS f64 division + floor (identical results at these
//! magnitudes, and bit-exact by construction).

use chomp_engine::moves::{AttackCalculator, MoveSlotLib};
use chomp_engine::Enums::{MonStateIndexName, MoveClass, Type};
use chomp_engine::Structs::{DamageCalcContext, MoveMeta};
use chomp_rt::{Address, B256, U256};

use crate::sim::Sim;
use crate::view::{
    mon_current_hp, mon_max_hp, mon_state, mon_stats, mon_value, move_slot, slot_external_base_power,
    slot_move_class, slot_move_type, type_effectiveness, Mv, Seat, SWITCH_MOVE_INDEX, VCPU, VOPP,
};

/// JS Number.MAX_SAFE_INTEGER — the TS sentinel for "least-of" scans.
pub const MAX_SAFE_INTEGER: i64 = 9007199254740991;

// HeuristicCPUBase.sol thresholds.
pub const SIMILAR_DAMAGE_THRESHOLD: i64 = 85;
pub const SWITCH_THRESHOLD: i64 = 30;
pub const SEVERE_DAMAGE_PCT_HELL: i64 = 30;

// Per-mon strategy config keys (values stored as moveIndex+1; 0 = unset).
pub const CONFIG_PREFERRED_MOVE: usize = 0;
pub const CONFIG_SWITCH_IN_MOVE: usize = 1;
pub const CONFIG_SETUP_MOVE: usize = 2;

/// `Math.floor(a / b)` for non-negative integers the way the TS source
/// computes it (f64 divide + floor — exact at battle-stat magnitudes).
pub fn floor_div(a: i64, b: i64) -> i64 {
    (a as f64 / b as f64).floor() as i64
}

// ---------------------------------------------------------------------------
// Damage estimation
// ---------------------------------------------------------------------------

/// Port of `_buildDamageCalcContext`: a DamageCalcContext for ANY
/// attacker/defender pair (virtual indices; reads seat-mapped).
pub fn build_damage_calc_context(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    attacker_vp: u8,
    attacker_mon: usize,
    defender_vp: u8,
    defender_mon: usize,
) -> DamageCalcContext {
    let attacker_stats = mon_stats(sim, seat, bk, attacker_vp, attacker_mon);
    let defender_stats = mon_stats(sim, seat, bk, defender_vp, defender_mon);

    let mut ctx = DamageCalcContext::default();
    ctx.attackerMonIndex = attacker_mon as u8;
    ctx.defenderMonIndex = defender_mon as u8;

    ctx.attackerAttack = attacker_stats.attack;
    ctx.attackerAttackDelta =
        mon_state(sim, seat, bk, attacker_vp, attacker_mon, MonStateIndexName::Attack) as i32;
    ctx.attackerSpAtk = attacker_stats.specialAttack;
    ctx.attackerSpAtkDelta =
        mon_state(sim, seat, bk, attacker_vp, attacker_mon, MonStateIndexName::SpecialAttack) as i32;

    ctx.defenderDef = defender_stats.defense;
    ctx.defenderDefDelta =
        mon_state(sim, seat, bk, defender_vp, defender_mon, MonStateIndexName::Defense) as i32;
    ctx.defenderSpDef = defender_stats.specialDefense;
    ctx.defenderSpDefDelta =
        mon_state(sim, seat, bk, defender_vp, defender_mon, MonStateIndexName::SpecialDefense) as i32;

    ctx.defenderType1 = defender_stats.type1;
    ctx.defenderType2 = defender_stats.type2;
    ctx
}

/// The deterministic estimator call both `_estimateDamage` ports share:
/// accuracy=100 (always hits), volatility=0, rng=50, critRate=0, clamped
/// to 0. The zero TYPE_CALCULATOR address is fine — it resolves statically.
fn deterministic_damage(
    ctx: &mut DamageCalcContext,
    base_power: u32,
    move_type: Type,
    move_class: MoveClass,
) -> i64 {
    let (damage, _) = AttackCalculator::_calculateDamageFromContext(
        Address::ZERO,
        ctx,
        base_power,
        100,
        U256::ZERO,
        move_type,
        move_class,
        U256::from(50u64),
        U256::ZERO,
    );
    if damage > 0 {
        damage as i64
    } else {
        0
    }
}

/// Port of `_estimateDamage`: deterministic estimate for a raw slot
/// against a prepared context. 0 for non-damaging / unreadable moves.
pub fn estimate_damage(
    sim: &mut Sim,
    bk: B256,
    ctx: &mut DamageCalcContext,
    raw_move_slot: U256,
    move_class: MoveClass,
) -> i64 {
    let base_power = if MoveSlotLib::isInline(raw_move_slot) {
        MoveSlotLib::basePower(raw_move_slot, bk)
    } else {
        slot_external_base_power(sim, bk, raw_move_slot)
    };
    if base_power == 0 {
        return 0;
    }
    let move_type = slot_move_type(sim, bk, raw_move_slot);
    deterministic_damage(ctx, base_power, move_type, move_class)
}

/// Port of `_estimateDamageMeta`: like estimate_damage off a pre-decoded meta.
pub fn estimate_damage_meta(ctx: &mut DamageCalcContext, meta: &MoveMeta) -> i64 {
    if meta.basePower == 0 {
        return 0;
    }
    deterministic_damage(ctx, meta.basePower, meta.moveType, meta.moveClass)
}

/// Port of `_getMoveBasePower`: basePower of a raw slot, 0 for non-attacks.
pub fn get_move_base_power(sim: &mut Sim, bk: B256, raw_move_slot: U256) -> i64 {
    if MoveSlotLib::isInline(raw_move_slot) {
        MoveSlotLib::basePower(raw_move_slot, bk) as i64
    } else {
        slot_external_base_power(sim, bk, raw_move_slot) as i64
    }
}

// ---------------------------------------------------------------------------
// Move selection
// ---------------------------------------------------------------------------

/// Port of `_computeMoveDamages`: outgoing damage per candidate move
/// (Physical/Special only; parallel to `moves`).
pub fn compute_move_damages(ctx: &mut DamageCalcContext, metas: &[MoveMeta], moves: &[Mv]) -> Vec<i64> {
    let mut damages = vec![0i64; moves.len()];
    for i in 0..moves.len() {
        let meta = &metas[moves[i].move_index as usize];
        if meta.moveClass == MoveClass::Physical || meta.moveClass == MoveClass::Special {
            damages[i] = estimate_damage_meta(ctx, meta);
        }
    }
    damages
}

/// Port of `_findKOMove`: index INTO `moves` of the cheapest-stamina move
/// that KOs the opponent's defender, or -1.
pub fn find_ko_move(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    defender_mon_index: usize,
    metas: &[MoveMeta],
    moves: &[Mv],
    damages: &[i64],
) -> isize {
    let defender_current_hp = mon_current_hp(sim, seat, bk, VOPP, defender_mon_index);
    if defender_current_hp <= 0 {
        return -1;
    }

    let mut best_move_index: isize = -1;
    let mut best_stamina_cost = MAX_SAFE_INTEGER;
    for i in 0..moves.len() {
        if damages[i] >= defender_current_hp {
            let stamina = metas[moves[i].move_index as usize].stamina as i64;
            if stamina < best_stamina_cost {
                best_stamina_cost = stamina;
                best_move_index = i as isize;
            }
        }
    }
    best_move_index
}

/// Port of `_findBestDamageMove`: strictly-greatest damage, then a
/// cheapest-stamina tiebreak within 85% of that best. -1 if nothing damages.
pub fn find_best_damage_move(metas: &[MoveMeta], moves: &[Mv], damages: &[i64]) -> isize {
    let mut best_move_index: isize = -1;
    let mut best_damage = 0i64;
    let mut best_stamina_cost = MAX_SAFE_INTEGER;

    for i in 0..moves.len() {
        if damages[i] > best_damage {
            best_damage = damages[i];
            best_stamina_cost = metas[moves[i].move_index as usize].stamina as i64;
            best_move_index = i as isize;
        }
    }
    if best_damage == 0 {
        return best_move_index;
    }

    let threshold = floor_div(best_damage * SIMILAR_DAMAGE_THRESHOLD, 100);
    for i in 0..moves.len() {
        let stamina = metas[moves[i].move_index as usize].stamina as i64;
        if damages[i] >= threshold && stamina < best_stamina_cost {
            best_stamina_cost = stamina;
            best_move_index = i as isize;
        }
    }
    best_move_index
}

// ---------------------------------------------------------------------------
// Matchup scores + lead/switch selection
// ---------------------------------------------------------------------------

/// Port of `_offensiveMatchupScore`: Σ type-effectiveness (scale 10) over
/// candidate-offense × opponent-defense pairs.
pub fn offensive_matchup_score(cand1: Type, cand2: Type, opp1: Type, opp2: Type) -> i64 {
    let mut score = type_effectiveness(cand1, opp1, 10);
    if opp2 != Type::None {
        score += type_effectiveness(cand1, opp2, 10);
    }
    if cand2 != Type::None {
        score += type_effectiveness(cand2, opp1, 10);
        if opp2 != Type::None {
            score += type_effectiveness(cand2, opp2, 10);
        }
    }
    score
}

/// The inline `defensiveScore` block of `_selectLead` — the same formula
/// as the offensive score with the roles swapped (opponent offense vs
/// candidate defense): identical calls, guards, and summation order.
pub fn defensive_matchup_score(opp1: Type, opp2: Type, cand1: Type, cand2: Type) -> i64 {
    offensive_matchup_score(opp1, opp2, cand1, cand2)
}

/// Port of `_selectLead`: dual-type-scored lead among the turn-0 switches;
/// strict >, ties keep the first.
pub fn select_lead(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    opponent_mon_extra_data: usize,
    switches: &[Mv],
    aggressive: bool,
) -> Mv {
    let opp_stats = mon_stats(sim, seat, bk, VOPP, opponent_mon_extra_data);
    let (opp1, opp2) = (opp_stats.type1, opp_stats.type2);

    let mut best_score = i64::MIN;
    let mut best_index = 0usize;
    for (i, sw) in switches.iter().enumerate() {
        let cand_stats = mon_stats(sim, seat, bk, VCPU, sw.extra_data as usize);
        let (c1, c2) = (cand_stats.type1, cand_stats.type2);
        let defensive = defensive_matchup_score(opp1, opp2, c1, c2);
        let offensive = offensive_matchup_score(c1, c2, opp1, opp2);
        let score = if aggressive { 3 * offensive - defensive } else { offensive - defensive };
        if score > best_score {
            best_score = score;
            best_index = i;
        }
    }
    switches[best_index]
}

/// Port of `_selectBestSwitch`. Non-aggressive: least estimated damage from
/// the opponent's revealed move (switches[0] fallback when unreadable);
/// aggressive: best offensive matchup.
pub fn select_best_switch(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    opponent_mon_index: usize,
    opponent_move_index: u8,
    switches: &[Mv],
    aggressive: bool,
) -> Mv {
    if aggressive {
        let opp_stats = mon_stats(sim, seat, bk, VOPP, opponent_mon_index);
        let (o1, o2) = (opp_stats.type1, opp_stats.type2);
        let mut best_score = i64::MIN;
        let mut best_idx = 0usize;
        for (i, sw) in switches.iter().enumerate() {
            let cand_stats = mon_stats(sim, seat, bk, VCPU, sw.extra_data as usize);
            let score = offensive_matchup_score(cand_stats.type1, cand_stats.type2, o1, o2);
            if score > best_score {
                best_score = score;
                best_idx = i;
            }
        }
        return switches[best_idx];
    }

    // Opponent is switching (no readable attack): default to switches[0].
    if opponent_move_index >= SWITCH_MOVE_INDEX {
        return switches[0];
    }

    // Read the revealed move; only Physical/Special are estimable.
    let slot = move_slot(sim, seat, bk, VOPP, opponent_mon_index, opponent_move_index as usize);
    let (opp_move_slot, opp_move_class, can_estimate) = match slot {
        Some(s) => {
            let mc = slot_move_class(sim, bk, s);
            (s, mc, mc == MoveClass::Physical || mc == MoveClass::Special)
        }
        None => (U256::ZERO, MoveClass::Physical, false),
    };
    if !can_estimate {
        return switches[0];
    }

    // Pick the candidate taking the LEAST damage from that move.
    let mut best_idx = 0usize;
    let mut least_damage = MAX_SAFE_INTEGER;
    for (i, sw) in switches.iter().enumerate() {
        let candidate_mon_index = sw.extra_data as usize;
        let mut ctx = build_damage_calc_context(
            sim, seat, bk, VOPP, opponent_mon_index, VCPU, candidate_mon_index,
        );
        let dmg = estimate_damage(sim, bk, &mut ctx, opp_move_slot, opp_move_class);
        if dmg < least_damage {
            least_damage = dmg;
            best_idx = i;
        }
    }
    switches[best_idx]
}

// ---------------------------------------------------------------------------
// Per-mon strategy config
// ---------------------------------------------------------------------------

/// Per-mon strategy config — the stand-in for `monConfig[monIndex][key]`,
/// passed in by the owning strategy (values are moveIndex+1, 0 = unset).
pub type MonConfig = fn(mon_index: usize, config_key: usize) -> u16;

/// Port of `_tryConfiguredMove`: (index into `moves` or -1, new bitmap).
pub fn try_configured_move(
    config: MonConfig,
    used_bitmap: u32,
    active_mon_index: usize,
    moves: &[Mv],
    config_key: usize,
    lane_bit_offset: usize,
) -> (isize, u32) {
    let config_value = config(active_mon_index, config_key);
    if config_value == 0 {
        return (-1, used_bitmap);
    }
    let target_move_index = config_value - 1;

    let lane_bit = 1u32 << (active_mon_index + lane_bit_offset);
    if used_bitmap & lane_bit != 0 {
        return (-1, used_bitmap); // already used this switch-in
    }
    for (i, m) in moves.iter().enumerate() {
        if m.move_index as u16 == target_move_index {
            return (i as isize, used_bitmap | lane_bit);
        }
    }
    (-1, used_bitmap)
}

/// Port of `_clearMoveUsedBitsOnSwitchIn`: switch-in lane clears
/// unconditionally; setup lane (bit monIdx+8) only above 50% HP.
pub fn clear_move_used_bits_on_switch_in(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    used_bitmap: u32,
    mon_idx: usize,
) -> u32 {
    let setup_bit = 1u32 << (mon_idx + 8);
    let mut new_bitmap = used_bitmap & !(1u32 << mon_idx);

    if used_bitmap & setup_bit != 0 {
        let max_hp = mon_max_hp(sim, seat, bk, VCPU, mon_idx);
        let current_hp = max_hp + mon_state(sim, seat, bk, VCPU, mon_idx, MonStateIndexName::Hp);
        if current_hp * 2 > max_hp {
            new_bitmap &= !setup_bit;
        }
    }
    new_bitmap
}

/// Port of `_tryPreferredMove`: the preferred move if within 85% of best
/// damage. Inert for the hard CPU (CONFIG_PREFERRED_MOVE is never set) but
/// kept for structural parity with the TS decision tree.
pub fn try_preferred_move(
    config: MonConfig,
    active_mon_index: usize,
    ctx: &mut DamageCalcContext,
    metas: &[MoveMeta],
    moves: &[Mv],
) -> isize {
    let config_value = config(active_mon_index, CONFIG_PREFERRED_MOVE);
    if config_value == 0 {
        return -1;
    }
    let target_move_index = config_value - 1;

    let mut preferred_idx: isize = -1;
    let mut preferred_damage = 0i64;
    let mut best_damage = 0i64;
    for (i, m) in moves.iter().enumerate() {
        let meta = &metas[m.move_index as usize];
        if meta.moveClass != MoveClass::Physical && meta.moveClass != MoveClass::Special {
            continue;
        }
        let dmg = estimate_damage_meta(ctx, meta);
        if dmg > best_damage {
            best_damage = dmg;
        }
        if m.move_index as u16 == target_move_index {
            preferred_idx = i as isize;
            preferred_damage = dmg;
        }
    }

    if preferred_idx < 0 {
        return -1;
    }
    if best_damage == 0 {
        return preferred_idx;
    }
    if preferred_damage * 100 >= best_damage * SIMILAR_DAMAGE_THRESHOLD {
        return preferred_idx;
    }
    -1
}

// ---------------------------------------------------------------------------
// Utility
// ---------------------------------------------------------------------------

/// Port of `_popcount8` (hardware popcount over the low 8 bits — output
/// identical to the TS/Solidity bit loop for every input).
pub fn popcount8(bitmap: u32) -> i64 {
    (bitmap & 0xff).count_ones() as i64
}

/// Port of `_hasMomentum`: more mons alive, or on a tie at least as much
/// active-mon stamina.
#[allow(clippy::too_many_arguments)]
pub fn has_momentum(
    sim: &mut Sim,
    seat: Seat,
    bk: B256,
    p1_team_size: usize,
    p1_ko_bitmap: u32,
    p0_team_size: usize,
    p0_ko_bitmap: u32,
    p0_active_mon_index: usize,
    cpu_active_current_stamina: i64,
) -> bool {
    let our_alive = p1_team_size as i64 - popcount8(p1_ko_bitmap);
    let their_alive = p0_team_size as i64 - popcount8(p0_ko_bitmap);
    if our_alive > their_alive {
        return true;
    }
    if our_alive < their_alive {
        return false;
    }
    let their_base = mon_value(sim, seat, bk, VOPP, p0_active_mon_index, MonStateIndexName::Stamina);
    let their_delta = mon_state(sim, seat, bk, VOPP, p0_active_mon_index, MonStateIndexName::Stamina);
    cpu_active_current_stamina >= their_base + their_delta
}
