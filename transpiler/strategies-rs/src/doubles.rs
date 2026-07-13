//! Greedy doubles CPU — parameterizable into easy / medium / hard.
//!
//! Doubles differs from singles in three ways this module handles (mirroring munch's
//! `cpu/doubles.ts`): two active mons per side at absolute slots 0-3 (side = absSlot>>1), a move
//! targets a SLOT via extraData's target nibble (bits 12-15), and `playerSwitchForTurnFlag` is a
//! bitmask of which absolute slots must forced-switch (not the singles 0/1/2).
//!
//! Core is greedy: for each acting slot, the affordable damaging move × live-opponent-slot with the
//! highest estimated immediate damage. The difficulty knob is an epsilon over that greedy pick —
//! with probability `opt_prob` it takes the best option, otherwise a random legal one — so easy
//! throws away most of its optimization and hard always plays the max. The stacks are decoupled from
//! TS, so this need not match `pickCpuSlotMoves` decision-for-decision.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};

use chomp_engine::moves::MoveSlotLib;
use chomp_engine::Enums::{MonStateIndexName, MoveClass};
use chomp_engine::Engine;
use chomp_engine::Structs::{Mon, MoveMeta};
use chomp_rt::{Address, B256, U256};

use crate::jsrng::{random_salt, JsRng};
use crate::roster::{input_type_of, target_spec_of, InputType, TargetSpec};
use crate::shared::{build_damage_calc_context, estimate_damage_meta};
use crate::sim::{pack_side, Sim};
use crate::view::{decode_meta, mon_current_stamina, mon_max_hp, mon_state, move_slot, turn_id, Seat};

const SWITCH: u8 = 125;
const NO_OP: u8 = 126;
const EMPTY_LANE: u32 = 0xFF; // Constants::EMPTY_ACTIVE_LANE
const NO_OP_MOVE: SlotMove = SlotMove { move_index: NO_OP, extra_data: 0 };

/// Non-flipped observer seat: the view helpers' `vp` argument then maps directly to the physical
/// side (0 → p0, 1 → p1), which is all doubles needs (no commit-reveal peek/transposition).
const OBS: Seat = Seat { cpu: 1 };

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Difficulty {
    Easy,
    Medium,
    Hard,
}

impl Difficulty {
    /// Probability of taking the greedy-best option instead of a random legal one.
    fn opt_prob(self) -> f64 {
        match self {
            Difficulty::Easy => 0.15,
            Difficulty::Medium => 0.5,
            Difficulty::Hard => 1.0,
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "easy" => Some(Difficulty::Easy),
            "medium" => Some(Difficulty::Medium),
            "hard" => Some(Difficulty::Hard),
            _ => None,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Difficulty::Easy => "easy",
            Difficulty::Medium => "medium",
            Difficulty::Hard => "hard",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct SlotMove {
    pub move_index: u8,
    pub extra_data: u16,
}

/// The two absolute slots owned by a side (0 → [0,1], 1 → [2,3]).
fn side_slots(side: u8) -> [usize; 2] {
    if side == 0 { [0, 1] } else { [2, 3] }
}

/// Encode a target absolute slot as extraData's target nibble — a BITMASK with bit `abs_slot` set
/// (bits 12-15), which the engine decodes via `TargetLib::lowestSlot`. Mirrors munch's `targetBits`.
fn target_bits(abs_slot: usize) -> u16 {
    1u16 << (12 + abs_slot)
}

/// Active mon index per absolute slot (0-3), or EMPTY_LANE for an empty lane.
fn active_slots(sim: &mut Sim, bk: B256) -> [u32; 4] {
    let raw = Engine::getActiveSlots(&mut sim.world, bk);
    core::array::from_fn(|i| u64::try_from(raw[i]).unwrap_or(0xFF) as u32)
}

fn ko_bitmap(sim: &mut Sim, bk: B256, side: u8) -> u32 {
    u64::try_from(Engine::getKOBitmap(&mut sim.world, bk, U256::from(side))).unwrap_or(0) as u32
}

/// First legal switch-in for a slot: lowest non-KO'd roster mon not already held by the ally slot.
fn first_legal_bench(team_size: usize, cpu_ko: u32, slots: &[u32; 4], abs_slot: usize) -> i32 {
    let side = abs_slot >> 1;
    let ally_abs = side * 2 + (1 - (abs_slot & 1));
    let ally_mon = slots[ally_abs];
    for i in 0..team_size as u32 {
        if cpu_ko & (1 << i) != 0 {
            continue; // KO'd
        }
        if i == ally_mon {
            continue; // already active in the ally slot
        }
        return i as i32;
    }
    -1
}

/// Every affordable damaging (move, target-slot) for `my_mon` on `cpu_side`, with estimated
/// damage — shared by the epsilon-greedy pilot and the search's candidate enumeration.
fn damaging_options(sim: &mut Sim, bk: B256, cpu_side: u8, my_mon: u32) -> Vec<(SlotMove, i64)> {
    let opp_side = 1 - cpu_side;
    let opp_abs = side_slots(opp_side);
    let slots = active_slots(sim, bk);
    let opp_ko = ko_bitmap(sim, bk, opp_side);

    // Live opponent slots (non-empty, non-KO): (absolute slot, mon index).
    let targets: Vec<(usize, usize)> = opp_abs
        .iter()
        .filter_map(|&t_abs| {
            let mon = slots[t_abs];
            if mon == EMPTY_LANE || (opp_ko & (1 << mon)) != 0 {
                None
            } else {
                Some((t_abs, mon as usize))
            }
        })
        .collect();
    if targets.is_empty() {
        return Vec::new();
    }

    let stamina = mon_current_stamina(sim, OBS, bk, cpu_side, my_mon as usize);
    // Decode my active mon's up-to-4 move metas once.
    let metas: Vec<(u8, MoveMeta)> = (0..4)
        .filter_map(|mi| {
            let slot = move_slot(sim, OBS, bk, cpu_side, my_mon as usize, mi)?;
            Some((mi as u8, decode_meta(sim, bk, cpu_side, my_mon as usize, slot)))
        })
        .collect();

    let mut options: Vec<(SlotMove, i64)> = Vec::new();
    for &(t_abs, t_mon) in &targets {
        let mut ctx = build_damage_calc_context(sim, OBS, bk, cpu_side, my_mon as usize, opp_side, t_mon);
        for (mi, meta) in &metas {
            if meta.stamina as i64 > stamina {
                continue; // unaffordable
            }
            if meta.moveClass != MoveClass::Physical && meta.moveClass != MoveClass::Special {
                continue; // only weigh damaging moves
            }
            let dmg = estimate_damage_meta(&mut ctx, meta);
            if dmg > 0 {
                options.push((SlotMove { move_index: *mi, extra_data: target_bits(t_abs) }, dmg));
            }
        }
    }
    options
}

/// Greedy attack for one acting mon: the affordable damaging (move, target-slot) with the highest
/// estimated damage, softened by `difficulty` (epsilon-greedy). None when nothing damaging is
/// affordable (caller rests).
fn greedy_attack(
    sim: &mut Sim,
    bk: B256,
    cpu_side: u8,
    my_mon: u32,
    difficulty: Difficulty,
    rng: &mut JsRng,
) -> Option<SlotMove> {
    let options = damaging_options(sim, bk, cpu_side, my_mon);
    if options.is_empty() {
        return None;
    }
    // Epsilon-greedy: the best option, or (with 1 - opt_prob) a random legal one.
    if rng.next() < difficulty.opt_prob() {
        Some(options.iter().max_by_key(|(_, d)| *d).unwrap().0)
    } else {
        let i = ((rng.next() * options.len() as f64) as usize).min(options.len() - 1);
        Some(options[i].0)
    }
}

/// Pick both of `cpu_side`'s active-slot moves for the current doubles turn.
pub fn pick_side_moves(
    sim: &mut Sim,
    bk: B256,
    cpu_side: u8,
    difficulty: Difficulty,
    rng: &mut JsRng,
) -> (SlotMove, SlotMove) {
    let [a0, a1] = side_slots(cpu_side);

    // Turn 0: send in the two leads (slot 0 → mon 0, slot 1 → mon 1).
    if turn_id(sim, bk) == 0 {
        return (
            SlotMove { move_index: SWITCH, extra_data: 0 },
            SlotMove { move_index: SWITCH, extra_data: 1 },
        );
    }

    let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag as u32;
    let is_forced = flag != 2; // 2 == both slots take a normal action
    let mask = flag & 0x0f; // which absolute slots must forced-switch
    let slots = active_slots(sim, bk);
    let team_size = u64::try_from(Engine::getTeamSize(&mut sim.world, bk, U256::from(cpu_side))).unwrap_or(0) as usize;

    let m0 = decide_slot(sim, bk, cpu_side, difficulty, is_forced, mask, &slots, team_size, a0, rng);
    let m1 = decide_slot(sim, bk, cpu_side, difficulty, is_forced, mask, &slots, team_size, a1, rng);
    (m0, m1)
}

#[allow(clippy::too_many_arguments)]
fn decide_slot(
    sim: &mut Sim,
    bk: B256,
    cpu_side: u8,
    difficulty: Difficulty,
    is_forced: bool,
    mask: u32,
    slots: &[u32; 4],
    team_size: usize,
    abs_slot: usize,
    rng: &mut JsRng,
) -> SlotMove {
    if is_forced {
        if mask & (1 << abs_slot) == 0 {
            return NO_OP_MOVE; // this slot isn't being forced this turn
        }
        let cpu_ko = ko_bitmap(sim, bk, cpu_side);
        let bench = first_legal_bench(team_size, cpu_ko, slots, abs_slot);
        return if bench >= 0 {
            SlotMove { move_index: SWITCH, extra_data: bench as u16 }
        } else {
            NO_OP_MOVE
        };
    }
    let my_mon = slots[abs_slot];
    if my_mon == EMPTY_LANE {
        return NO_OP_MOVE;
    }
    greedy_attack(sim, bk, cpu_side, my_mon, difficulty, rng).unwrap_or(NO_OP_MOVE)
}

// ── Doubles maximin search (Phase 3 substrate) ──────────────────────────────
//
// Depth-limited joint-action maximin over the slot-turn forward model, leaves scored by a small
// linear 2-slot evaluator — replaces the myopic epsilon-greedy with forward-model + opponent
// modelling. No-peek, deterministic (fixed salt, earliest-candidate tie-break, forks disposed).

const MAX_DAMAGING: usize = 3; // top damaging (move,target) options per slot, by estimated damage
const MAX_STATUS: usize = 2; // non-damaging (status/setup) move options per slot
const MAX_SLOT_ACTIONS: usize = MAX_DAMAGING + MAX_STATUS + 2; // + pivot switch + rest — never truncated
const MAX_JOINTS: usize = MAX_SLOT_ACTIONS * MAX_SLOT_ACTIONS; // no truncation bias
const WIN: f64 = 1e9;
const LOSS: f64 = -1e9;
const D_W_HP: f64 = 1.0;
const D_W_KO: f64 = 150.0;
const D_W_STAMINA: f64 = 2.0;

fn team_size_of(sim: &mut Sim, bk: B256, side: u8) -> usize {
    u64::try_from(Engine::getTeamSize(&mut sim.world, bk, U256::from(side))).unwrap_or(0) as usize
}

/// Σ hp% over a side's whole roster.
fn side_roster_hp(sim: &mut Sim, bk: B256, side: u8, team_size: usize) -> f64 {
    let mut sum = 0.0f64;
    for i in 0..team_size {
        let mhp = mon_max_hp(sim, OBS, bk, side, i);
        if mhp <= 0 {
            continue;
        }
        let hp = mhp + mon_state(sim, OBS, bk, side, i, MonStateIndexName::Hp);
        sum += (hp.max(0) * 100) as f64 / mhp as f64;
    }
    sum
}

/// Σ current stamina over a side's two active slots.
fn side_active_stamina(sim: &mut Sim, bk: B256, side: u8, slots: &[u32; 4]) -> i64 {
    let mut sum = 0;
    for &abs in &side_slots(side) {
        let mon = slots[abs];
        if mon != EMPTY_LANE {
            sum += mon_current_stamina(sim, OBS, bk, side, mon as usize);
        }
    }
    sum
}

/// Linear 2-slot position value, `cpu_side`-perspective (higher = better).
fn doubles_eval(sim: &mut Sim, bk: B256, cpu_side: u8) -> f64 {
    let opp_side = 1 - cpu_side;
    let cpu_ts = team_size_of(sim, bk, cpu_side);
    let opp_ts = team_size_of(sim, bk, opp_side);
    let hp = side_roster_hp(sim, bk, cpu_side, cpu_ts) - side_roster_hp(sim, bk, opp_side, opp_ts);
    let ko = (ko_bitmap(sim, bk, opp_side).count_ones() as i64 - ko_bitmap(sim, bk, cpu_side).count_ones() as i64) as f64;
    let slots = active_slots(sim, bk);
    let stam = (side_active_stamina(sim, bk, cpu_side, &slots) - side_active_stamina(sim, bk, opp_side, &slots)) as f64;
    D_W_HP * hp + D_W_KO * ko + D_W_STAMINA * stam
}

/// Terminal value if a side is fully KO'd, else None. Mate-distance discounted:
/// more remaining depth = reached sooner, so faster wins / later losses score better.
fn terminal(sim: &mut Sim, bk: B256, cpu_side: u8, depth: u32) -> Option<f64> {
    let opp_side = 1 - cpu_side;
    let cpu_ts = team_size_of(sim, bk, cpu_side) as u32;
    let opp_ts = team_size_of(sim, bk, opp_side) as u32;
    if ko_bitmap(sim, bk, opp_side).count_ones() >= opp_ts {
        return Some(WIN + depth as f64);
    }
    if ko_bitmap(sim, bk, cpu_side).count_ones() >= cpu_ts {
        return Some(LOSS - depth as f64);
    }
    None
}

/// All legal bench targets for a slot: non-KO roster mons not held by either of the side's slots.
fn legal_benches(team_size: usize, ko: u32, slots: &[u32; 4], abs_slot: usize) -> Vec<u16> {
    let side = abs_slot >> 1;
    let ally_abs = side * 2 + (1 - (abs_slot & 1));
    let (ally_mon, own_mon) = (slots[ally_abs], slots[abs_slot]);
    (0..team_size as u32)
        .filter(|&i| ko & (1 << i) == 0 && i != ally_mon && i != own_mon)
        .map(|i| i as u16)
        .collect()
}

/// Candidate actions for one active slot on a normal turn: the TOP-damage (move,target) options
/// (with per-target diversity — the best option against EACH live enemy slot is always included,
/// so focus-fire vs spread are both searchable), non-damaging status/setup moves whose targeting
/// needs no nibble (self-only / none), a pivot switch, and rest. Bench and rest are always kept
/// (never truncated behind damaging options — the singles rest-bug lesson). Empty lane → rest only.
fn slot_candidates(sim: &mut Sim, bk: B256, side: u8, abs_slot: usize, slots: &[u32; 4], team_size: usize) -> Vec<SlotMove> {
    let my_mon = slots[abs_slot];
    if my_mon == EMPTY_LANE {
        return vec![NO_OP_MOVE];
    }
    let mut dmg = damaging_options(sim, bk, side, my_mon);
    dmg.sort_by_key(|&(_, d)| -d); // best damage first
    // Best option per distinct target first (≤2 live slots), then next-best overall.
    let mut out: Vec<SlotMove> = Vec::new();
    let mut seen_targets: Vec<u16> = Vec::new();
    for &(sm, _) in &dmg {
        if !seen_targets.contains(&sm.extra_data) {
            seen_targets.push(sm.extra_data);
            out.push(sm);
        }
    }
    for &(sm, _) in &dmg {
        if out.len() >= MAX_DAMAGING {
            break;
        }
        if !out.contains(&sm) {
            out.push(sm);
        }
    }
    out.truncate(MAX_DAMAGING);

    // Status/setup moves (non-damaging class, affordable, nibble-free targeting): extraData 0.
    let stamina = mon_current_stamina(sim, OBS, bk, side, my_mon as usize);
    let mut n_status = 0usize;
    for mi in 0..4usize {
        if n_status >= MAX_STATUS {
            break;
        }
        let Some(slot_w) = move_slot(sim, OBS, bk, side, my_mon as usize, mi) else { break };
        if MoveSlotLib::isInline(slot_w) {
            continue; // inline words are standard attacks (already in damaging options)
        }
        let meta = decode_meta(sim, bk, side, my_mon as usize, slot_w);
        if meta.moveClass == MoveClass::Physical || meta.moveClass == MoveClass::Special {
            continue;
        }
        if meta.stamina as i64 > stamina {
            continue;
        }
        let addr = MoveSlotLib::toIMoveSet(slot_w);
        let nibble_free = matches!(target_spec_of(addr), TargetSpec::SelfOnly | TargetSpec::NoTarget);
        if nibble_free && input_type_of(addr) == InputType::None {
            out.push(SlotMove { move_index: mi as u8, extra_data: 0 });
            n_status += 1;
        }
    }

    let bench = first_legal_bench(team_size, ko_bitmap(sim, bk, side), slots, abs_slot);
    if bench >= 0 {
        out.push(SlotMove { move_index: SWITCH, extra_data: bench as u16 });
    }
    out.push(NO_OP_MOVE);
    out
}

/// Joint (slot0, slot1) actions for a side on a normal turn, capped at MAX_JOINTS.
fn side_joint(sim: &mut Sim, bk: B256, side: u8) -> Vec<(SlotMove, SlotMove)> {
    let [a0, a1] = side_slots(side);
    let slots = active_slots(sim, bk);
    let ts = team_size_of(sim, bk, side);
    let c0 = slot_candidates(sim, bk, side, a0, &slots, ts);
    let c1 = slot_candidates(sim, bk, side, a1, &slots, ts);
    let mut out = Vec::with_capacity(c0.len() * c1.len());
    for &m0 in &c0 {
        for &m1 in &c1 {
            out.push((m0, m1));
        }
    }
    out.truncate(MAX_JOINTS);
    out
}

/// Fork one slot-turn from `bk`: `mine` = cpu_side's joint, `theirs` = the opponent's.
fn fork_joint(sim: &mut Sim, bk: B256, cpu_side: u8, mine: (SlotMove, SlotMove), theirs: (SlotMove, SlotMove)) -> B256 {
    let my_word = pack_side(mine.0.move_index, mine.0.extra_data, mine.1.move_index, mine.1.extra_data, 0);
    let th_word = pack_side(theirs.0.move_index, theirs.0.extra_data, theirs.1.move_index, theirs.1.extra_data, 0);
    let (side0, side1) = if cpu_side == 0 { (my_word, th_word) } else { (th_word, my_word) };
    sim.apply_hypothetical_slot(bk, side0, side1)
}

/// A side's deterministic forced-switch resolution (first-legal bench per masked slot) — the
/// interior-node opponent/self model for forced half-turns (matches the epsilon-greedy baseline).
fn forced_joint_model(sim: &mut Sim, bk: B256, side: u8, mask: u32, slots: &[u32; 4]) -> (SlotMove, SlotMove) {
    let ts = team_size_of(sim, bk, side);
    let ko = ko_bitmap(sim, bk, side);
    let [a0, a1] = side_slots(side);
    let pick = |abs: usize| -> SlotMove {
        if mask & (1 << abs) == 0 {
            return NO_OP_MOVE;
        }
        let b = first_legal_bench(ts, ko, slots, abs);
        if b >= 0 { SlotMove { move_index: SWITCH, extra_data: b as u16 } } else { NO_OP_MOVE }
    };
    (pick(a0), pick(a1))
}

/// Recursive maximin value at `bk`, cpu_side-perspective. Forced half-turns are resolved
/// deterministically and recursed WITHOUT consuming depth (they don't burn horizon; the chain is
/// bounded by roster size / the terminal check).
fn search_value(sim: &mut Sim, bk: B256, cpu_side: u8, depth: u32) -> f64 {
    if let Some(v) = terminal(sim, bk, cpu_side, depth) {
        return v;
    }
    if depth == 0 {
        return doubles_eval(sim, bk, cpu_side);
    }
    let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag as u32;
    if flag != 2 {
        let mask = flag & 0x0f;
        let slots = active_slots(sim, bk);
        let mine = forced_joint_model(sim, bk, cpu_side, mask, &slots);
        let theirs = forced_joint_model(sim, bk, 1 - cpu_side, mask, &slots);
        if mine == (NO_OP_MOVE, NO_OP_MOVE) && theirs == (NO_OP_MOVE, NO_OP_MOVE) {
            return doubles_eval(sim, bk, cpu_side); // no legal resolution — don't loop
        }
        let child = fork_joint(sim, bk, cpu_side, mine, theirs);
        let v = search_value(sim, child, cpu_side, depth);
        sim.dispose_fork(child);
        return v;
    }
    let opp_side = 1 - cpu_side;
    let my = side_joint(sim, bk, cpu_side);
    let opp = side_joint(sim, bk, opp_side);
    let mut best = f64::NEG_INFINITY;
    for &mine in &my {
        let mut worst = f64::INFINITY;
        for &theirs in &opp {
            let child = fork_joint(sim, bk, cpu_side, mine, theirs);
            let v = search_value(sim, child, cpu_side, depth - 1);
            sim.dispose_fork(child);
            if v < worst {
                worst = v;
            }
            if worst <= best {
                break; // argmax-invariant row prune (doubles enumeration is rng-free)
            }
        }
        if worst > best {
            best = worst;
        }
    }
    best
}

/// Pick `cpu_side`'s two slot moves by depth-`depth` joint maximin (turn 0 → leads; forced-switch →
/// first-legal bench; normal turn → search). A reverting hypothetical mid-search is contained to
/// this decision (fall back to resting both slots) rather than aborting the game.
pub fn search_side_moves(sim: &mut Sim, bk: B256, cpu_side: u8, depth: u32) -> (SlotMove, SlotMove) {
    let saved_fc = sim.fork_counter();
    match catch_unwind(AssertUnwindSafe(|| search_side_moves_inner(sim, bk, cpu_side, depth))) {
        Ok(m) => m,
        Err(_) => {
            sim.set_fork_counter(saved_fc);
            (NO_OP_MOVE, NO_OP_MOVE)
        }
    }
}

fn search_side_moves_inner(sim: &mut Sim, bk: B256, cpu_side: u8, depth: u32) -> (SlotMove, SlotMove) {
    let [a0, a1] = side_slots(cpu_side);
    let sw = |i: u16| SlotMove { move_index: SWITCH, extra_data: i };

    // Turn 0: SEARCH the lead pair (was hardcoded mons 0/1) — maximin over both sides' send-ins.
    if turn_id(sim, bk) == 0 {
        let lead_pairs = |n: usize| -> Vec<(SlotMove, SlotMove)> {
            let mut v = Vec::new();
            for i in 0..n as u16 {
                for j in 0..n as u16 {
                    if i != j {
                        v.push((sw(i), sw(j)));
                    }
                }
            }
            v
        };
        let my = lead_pairs(team_size_of(sim, bk, cpu_side));
        let opp = lead_pairs(team_size_of(sim, bk, 1 - cpu_side));
        let mut best = (sw(0), sw(1));
        let mut best_val = f64::NEG_INFINITY;
        for &mine in &my {
            let mut worst = f64::INFINITY;
            for &theirs in &opp {
                let child = fork_joint(sim, bk, cpu_side, mine, theirs);
                let v = search_value(sim, child, cpu_side, depth.saturating_sub(1));
                sim.dispose_fork(child);
                if v < worst {
                    worst = v;
                }
            }
            if worst > best_val {
                best_val = worst;
                best = mine;
            }
        }
        return best;
    }

    let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag as u32;
    if flag != 2 {
        // Forced-switch turn: ENUMERATE my legal bench combos (was first-legal) and pick the best
        // by search; opponent's forced slots modeled first-legal. Doesn't consume depth.
        let mask = flag & 0x0f;
        let slots = active_slots(sim, bk);
        let ts = team_size_of(sim, bk, cpu_side);
        let cpu_ko = ko_bitmap(sim, bk, cpu_side);
        let (m0, m1) = (mask & (1 << a0) != 0, mask & (1 << a1) != 0);
        if !m0 && !m1 {
            return (NO_OP_MOVE, NO_OP_MOVE); // only the opponent is forced
        }
        let b0 = if m0 { legal_benches(ts, cpu_ko, &slots, a0) } else { vec![] };
        let b1 = if m1 { legal_benches(ts, cpu_ko, &slots, a1) } else { vec![] };
        let mut combos: Vec<(SlotMove, SlotMove)> = Vec::new();
        match (m0, m1) {
            (true, true) => {
                for &x in &b0 {
                    for &y in &b1 {
                        if x != y {
                            combos.push((sw(x), sw(y)));
                        }
                    }
                }
            }
            (true, false) => combos.extend(b0.iter().map(|&x| (sw(x), NO_OP_MOVE))),
            (false, true) => combos.extend(b1.iter().map(|&y| (NO_OP_MOVE, sw(y)))),
            (false, false) => {}
        }
        if combos.is_empty() {
            combos.push((NO_OP_MOVE, NO_OP_MOVE));
        }
        let theirs = forced_joint_model(sim, bk, 1 - cpu_side, mask, &slots);
        let mut best = combos[0];
        let mut best_val = f64::NEG_INFINITY;
        for &mine in &combos {
            let child = fork_joint(sim, bk, cpu_side, mine, theirs);
            let v = search_value(sim, child, cpu_side, depth);
            sim.dispose_fork(child);
            if v > best_val {
                best_val = v;
                best = mine;
            }
        }
        return best;
    }
    // Normal turn: depth-`depth` joint maximin (with the argmax-invariant row prune).
    let depth = depth.max(1);
    let opp_side = 1 - cpu_side;
    let my = side_joint(sim, bk, cpu_side);
    let opp = side_joint(sim, bk, opp_side);
    let mut best = my.first().copied().unwrap_or((NO_OP_MOVE, NO_OP_MOVE));
    let mut best_val = f64::NEG_INFINITY;
    for &mine in &my {
        let mut worst = f64::INFINITY;
        for &theirs in &opp {
            let child = fork_joint(sim, bk, cpu_side, mine, theirs);
            let v = search_value(sim, child, cpu_side, depth - 1);
            sim.dispose_fork(child);
            if v < worst {
                worst = v;
            }
            if worst <= best_val {
                break; // this joint can no longer win the argmax — prune
            }
        }
        if worst > best_val {
            best_val = worst;
            best = mine;
        }
    }
    best
}

// ── Doubles game driver + arena ──────────────────────────────────────────────

pub struct DoublesSpec {
    pub seed: u32,
    pub max_turns: u32,
    pub mons_per_team: u64,
    pub p0_team: Vec<Mon>,
    pub p1_team: Vec<Mon>,
    pub p0_ids: Vec<u32>,
    pub p1_ids: Vec<u32>,
    pub p0_difficulty: Difficulty,
    pub p1_difficulty: Difficulty,
    /// Per-side search depth: 0 = epsilon-greedy at the difficulty; ≥1 = joint maximin search.
    pub p0_search_depth: u32,
    pub p1_search_depth: u32,
}

pub struct DoublesOutcome {
    /// Winning side (0 or 1), or None on a turn-cap stalemate.
    pub winner_side: Option<u8>,
    pub turns: u32,
}

/// Play one doubles game: each turn both sides pick their two slot moves (greedy CPU at the spec's
/// difficulty), the moves are packed per side, and the turn executes via `execute_slot_turn`.
pub fn play_doubles_game(spec: &DoublesSpec, book: &HashMap<String, Address>) -> DoublesOutcome {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new_doubles(
        spec.mons_per_team,
        spec.p0_team.clone(),
        spec.p1_team.clone(),
        spec.p0_ids.clone(),
        spec.p1_ids.clone(),
        book,
    );

    for t in 0..spec.max_turns {
        let w = sim.winner_index();
        if w != 2 {
            return DoublesOutcome { winner_side: Some(w), turns: t };
        }
        let bk = sim.battle_key;
        let (p0a, p0b) = if spec.p0_search_depth > 0 {
            search_side_moves(&mut sim, bk, 0, spec.p0_search_depth)
        } else {
            pick_side_moves(&mut sim, bk, 0, spec.p0_difficulty, &mut rng)
        };
        let (p1a, p1b) = if spec.p1_search_depth > 0 {
            search_side_moves(&mut sim, bk, 1, spec.p1_search_depth)
        } else {
            pick_side_moves(&mut sim, bk, 1, spec.p1_difficulty, &mut rng)
        };
        let salt0 = random_salt(&mut rng);
        let salt1 = random_salt(&mut rng);
        let side0 = pack_side(p0a.move_index, p0a.extra_data, p0b.move_index, p0b.extra_data, salt0);
        let side1 = pack_side(p1a.move_index, p1a.extra_data, p1b.move_index, p1b.extra_data, salt1);
        sim.execute_slot_turn(side0, side1);
    }

    let fw = sim.winner_index();
    DoublesOutcome { winner_side: if fw != 2 { Some(fw) } else { None }, turns: spec.max_turns }
}

fn run_one_doubles(spec: &DoublesSpec, book: &HashMap<String, Address>) -> DoublesOutcome {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| play_doubles_game(spec, book)))
        .unwrap_or(DoublesOutcome { winner_side: None, turns: 0 }) // engine panic → counted as a draw
}

/// Run a batch of independent doubles games, optionally across threads (each game owns its whole
/// world). Results come back in spec order.
pub fn run_doubles_games(
    specs: &[DoublesSpec],
    book: &HashMap<String, Address>,
    threads: usize,
) -> Vec<DoublesOutcome> {
    if threads <= 1 || specs.len() <= 1 {
        return specs.iter().map(|s| run_one_doubles(s, book)).collect();
    }
    let n = threads.min(specs.len());
    let mut slots: Vec<Option<DoublesOutcome>> = Vec::with_capacity(specs.len());
    slots.resize_with(specs.len(), || None);
    let slots = std::sync::Mutex::new(slots);
    let next = std::sync::atomic::AtomicUsize::new(0);
    std::thread::scope(|scope| {
        for _ in 0..n {
            scope.spawn(|| loop {
                let idx = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                if idx >= specs.len() {
                    break;
                }
                let r = run_one_doubles(&specs[idx], book);
                slots.lock().unwrap()[idx] = Some(r);
            });
        }
    });
    slots.into_inner().unwrap().into_iter().map(|r| r.expect("slot filled")).collect()
}
