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
use crate::view::{
    decode_meta, mon_current_stamina, mon_max_hp, mon_skip_turn, mon_state, move_slot, stat_delta_score, turn_id, Seat,
};

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
            let mv = SlotMove { move_index: *mi, extra_data: target_bits(t_abs) };
            // A hand-written getMeta() may quote 0 for a move that does deal damage, so 0 means
            // "unknown", not "harmless" — dropping it here empties the option set and leaves the slot
            // resting all game. Simulate instead of trusting a declared number: nominal power is not
            // damage-this-turn for delayed (Q5), multi-hit (Bubble Bop), or spent (Sneak Attack) moves.
            let dmg = if meta.basePower != 0 {
                estimate_damage_meta(&mut ctx, meta)
            } else {
                probe_damage(sim, bk, cpu_side, my_mon, mv, opp_side, t_mon)
            };
            options.push((mv, dmg));
        }
    }
    options
}

/// Exact damage for one (move, target), by simulating it: fork a turn where only `my_mon`'s slot
/// acts and read how much HP the target actually lost. Used for moves whose power the static quote
/// can't know; costs one fork, so it runs only on moves whose `getMeta()` quotes no power.
fn probe_damage(
    sim: &mut Sim,
    bk: B256,
    cpu_side: u8,
    my_mon: u32,
    mv: SlotMove,
    opp_side: u8,
    t_mon: usize,
) -> i64 {
    let slots = active_slots(sim, bk);
    let [a0, a1] = side_slots(cpu_side);
    // Place the probed action on whichever of my slots holds the acting mon; everything else rests,
    // so the observed HP change is attributable to this move alone.
    let (m0, m1) = if slots[a0] == my_mon {
        (mv, NO_OP_MOVE)
    } else if slots[a1] == my_mon {
        (NO_OP_MOVE, mv)
    } else {
        return 0; // not an active slot this turn
    };
    let mine = pack_side(m0.move_index, m0.extra_data, m1.move_index, m1.extra_data, 0);
    let theirs = pack_side(NO_OP, 0, NO_OP, 0, 0);
    let (side0, side1) = if cpu_side == 0 { (mine, theirs) } else { (theirs, mine) };

    let before = mon_state(sim, OBS, bk, opp_side, t_mon, MonStateIndexName::Hp);
    let fork = sim.apply_hypothetical_slot(bk, side0, side1);
    let after = mon_state(sim, OBS, fork, opp_side, t_mon, MonStateIndexName::Hp);
    sim.dispose_fork(fork);
    (before - after).max(0) // hp deltas run negative; damage is how much further it fell
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
    let team_size = sim.team_size_phys(U256::from(cpu_side));

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

/// Doubles eval weights. Defaults reproduce the frozen baseline (hp/ko/stamina, corpses counted),
/// so every existing caller is unchanged; the extra terms exist to be A/B'd in the arena.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct DoublesEvalW {
    pub w_hp: f64,
    pub w_ko: f64,
    pub w_stamina: f64,
    /// Per Σ(delta/base) unit over a live active's five combat stats (the TS twin's 0.4-per-% ≡ 40 here).
    pub w_boost: f64,
    /// Per live opposing active carrying a status class, minus ours (statuses hurt their carrier).
    pub w_status: f64,
    /// Per live opposing active flagged ShouldSkipTurn, minus ours.
    pub w_skip: f64,
    /// Exclude KO'd actives from the per-active terms — a corpse holds its lane (and stat deltas)
    /// until the forced switch, but its stamina/boosts/status are worth nothing.
    pub gate_ko: bool,
}

impl Default for DoublesEvalW {
    fn default() -> Self {
        Self {
            w_hp: D_W_HP,
            w_ko: D_W_KO,
            w_stamina: D_W_STAMINA,
            w_boost: 0.0,
            w_status: 0.0,
            w_skip: 0.0,
            gate_ko: false,
        }
    }
}

fn team_size_of(sim: &mut Sim, _bk: B256, side: u8) -> usize {
    sim.team_size_phys(U256::from(side))
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

/// Per-active term sums (stamina, boost, status, skip) over a side's two active slots. Feature
/// reads are skipped while their weight is 0 so the default eval costs what it always did.
fn side_active_terms(sim: &mut Sim, bk: B256, side: u8, slots: &[u32; 4], w: &DoublesEvalW, ko: u32) -> (f64, f64, f64, f64) {
    let (mut stam, mut boost, mut status, mut skip) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
    for &abs in &side_slots(side) {
        let mon = slots[abs];
        if mon == EMPTY_LANE || (w.gate_ko && ko & (1 << mon) != 0) {
            continue;
        }
        stam += mon_current_stamina(sim, OBS, bk, side, mon as usize) as f64;
        if w.w_boost != 0.0 {
            boost += stat_delta_score(sim, OBS, bk, side, mon as usize);
        }
        if w.w_status != 0.0
            && Engine::getMonStatusClass(&mut sim.world, bk, U256::from(side), U256::from(mon)) != U256::from(0u64)
        {
            status += 1.0;
        }
        if w.w_skip != 0.0 && mon_skip_turn(sim, OBS, bk, side, mon as usize) {
            skip += 1.0;
        }
    }
    (stam, boost, status, skip)
}

/// Linear 2-slot position value, `cpu_side`-perspective (higher = better).
fn doubles_eval(sim: &mut Sim, bk: B256, cpu_side: u8, w: &DoublesEvalW) -> f64 {
    let opp_side = 1 - cpu_side;
    let cpu_ts = team_size_of(sim, bk, cpu_side);
    let opp_ts = team_size_of(sim, bk, opp_side);
    let hp = side_roster_hp(sim, bk, cpu_side, cpu_ts) - side_roster_hp(sim, bk, opp_side, opp_ts);
    let my_ko = ko_bitmap(sim, bk, cpu_side);
    let op_ko = ko_bitmap(sim, bk, opp_side);
    let ko = (op_ko.count_ones() as i64 - my_ko.count_ones() as i64) as f64;
    let slots = active_slots(sim, bk);
    let (my_stam, my_boost, my_status, my_skip) = side_active_terms(sim, bk, cpu_side, &slots, w, my_ko);
    let (op_stam, op_boost, op_status, op_skip) = side_active_terms(sim, bk, opp_side, &slots, w, op_ko);
    w.w_hp * hp
        + w.w_ko * ko
        + w.w_stamina * (my_stam - op_stam)
        + w.w_boost * (my_boost - op_boost)
        + w.w_status * (op_status - my_status)
        + w.w_skip * (op_skip - my_skip)
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
fn search_value(sim: &mut Sim, bk: B256, cpu_side: u8, depth: u32, w: &DoublesEvalW) -> f64 {
    if let Some(v) = terminal(sim, bk, cpu_side, depth) {
        return v;
    }
    if depth == 0 {
        return doubles_eval(sim, bk, cpu_side, w);
    }
    let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag as u32;
    if flag != 2 {
        let mask = flag & 0x0f;
        let slots = active_slots(sim, bk);
        let mine = forced_joint_model(sim, bk, cpu_side, mask, &slots);
        let theirs = forced_joint_model(sim, bk, 1 - cpu_side, mask, &slots);
        if mine == (NO_OP_MOVE, NO_OP_MOVE) && theirs == (NO_OP_MOVE, NO_OP_MOVE) {
            return doubles_eval(sim, bk, cpu_side, w); // no legal resolution — don't loop
        }
        let child = fork_joint(sim, bk, cpu_side, mine, theirs);
        let v = search_value(sim, child, cpu_side, depth, w);
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
            let v = search_value(sim, child, cpu_side, depth - 1, w);
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
pub fn search_side_moves(sim: &mut Sim, bk: B256, cpu_side: u8, depth: u32, w: &DoublesEvalW) -> (SlotMove, SlotMove) {
    let saved_fc = sim.fork_counter();
    match catch_unwind(AssertUnwindSafe(|| search_side_moves_inner(sim, bk, cpu_side, depth, w))) {
        Ok(m) => m,
        Err(_) => {
            sim.set_fork_counter(saved_fc);
            (NO_OP_MOVE, NO_OP_MOVE)
        }
    }
}

fn search_side_moves_inner(sim: &mut Sim, bk: B256, cpu_side: u8, depth: u32, w: &DoublesEvalW) -> (SlotMove, SlotMove) {
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
                let v = search_value(sim, child, cpu_side, depth.saturating_sub(1), w);
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
            let v = search_value(sim, child, cpu_side, depth, w);
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
            let v = search_value(sim, child, cpu_side, depth - 1, w);
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
    /// Per-side eval weights for the search tiers (ignored at depth 0).
    pub p0_eval: DoublesEvalW,
    pub p1_eval: DoublesEvalW,
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
            search_side_moves(&mut sim, bk, 0, spec.p0_search_depth, &spec.p0_eval)
        } else {
            pick_side_moves(&mut sim, bk, 0, spec.p0_difficulty, &mut rng)
        };
        let (p1a, p1b) = if spec.p1_search_depth > 0 {
            search_side_moves(&mut sim, bk, 1, spec.p1_search_depth, &spec.p1_eval)
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

// ── Diagnostic: per-turn trace of one mon's doubles game ────────────────────

/// What a tracked mon did / had on one doubles turn.
pub struct MonTurnTrace {
    pub turn: u32,
    pub active: bool,
    pub move_index: u8,
    pub hp_pct: f64,
    pub stamina: i64,
    /// Attack stat delta — non-zero once Loop's boost lands (the setup payoff).
    pub atk_delta: i64,
}

/// A KO credited to one attacker. Doubles can't reuse singles' "opposing active" proxy — there are
/// two of them — so credit comes from the target nibble the killer's side actually aimed.
pub struct DoublesKoEvent {
    pub turn: u32,
    pub killer_seat: u8,
    pub killer_id: u32,
    pub victim_id: u32,
}

pub struct DoublesInstr {
    pub winner_side: Option<u8>,
    pub turns: u32,
    pub p0_ids: Vec<u32>,
    pub p1_ids: Vec<u32>,
    /// Active-turn count per team slot (parallel to p0_ids / p1_ids).
    pub active_turns_p0: Vec<u32>,
    pub active_turns_p1: Vec<u32>,
    pub kos: Vec<DoublesKoEvent>,
    /// KOs both opposing slots aimed at — a genuine co-kill, so no single attacker earns the credit.
    pub kos_shared: u32,
    /// KOs no opposing move aimed at (status, recoil, ally damage).
    pub kos_incidental: u32,
    /// Per-turn rows for the `track`ed mon, if any.
    pub rows: Vec<MonTurnTrace>,
    pub tracked_active_turns: u32,
}

/// Was `mv` a real attack aimed at absolute slot `abs`? Switch / rest carry no target nibble.
fn aimed_at(mv: SlotMove, abs: usize) -> bool {
    mv.move_index != SWITCH && mv.move_index != NO_OP && (mv.extra_data >> 12) & (1u16 << abs) != 0
}

/// Counterfactual: replayed from `snap` with only `mv` on `atk_side`'s slot `atk_i` and everything
/// else resting, does `victim` still go down? Lets a KO both opposing slots aimed at be credited to
/// whichever one was actually lethal — usually only one is, the other being redundant overkill.
///
/// The real turn's salts are reused so accuracy/crit land as close to the observed turn as a
/// one-sided replay can; it is still a counterfactual, not a replay of what happened.
fn would_ko_alone(
    sim: &mut Sim,
    snap: B256,
    atk_side: u8,
    atk_i: usize,
    mv: SlotMove,
    victim_side: u8,
    victim_mon: usize,
    salts: (u128, u128),
) -> bool {
    let (m0, m1) = if atk_i == 0 { (mv, NO_OP_MOVE) } else { (NO_OP_MOVE, mv) };
    let mine = pack_side(m0.move_index, m0.extra_data, m1.move_index, m1.extra_data, if atk_side == 0 { salts.0 } else { salts.1 });
    let theirs = pack_side(NO_OP, 0, NO_OP, 0, if atk_side == 0 { salts.1 } else { salts.0 });
    let (side0, side1) = if atk_side == 0 { (mine, theirs) } else { (theirs, mine) };
    let fork = sim.apply_hypothetical_slot(snap, side0, side1);
    let down = ko_bitmap(sim, fork, victim_side) & (1u32 << victim_mon) != 0;
    sim.dispose_fork(fork);
    down
}

/// Replay `spec` recording per-mon active turns and attributed KOs, plus optional per-turn rows for
/// one tracked `(side, mon)`. Mirrors `play_doubles_game`; the hot path stays uninstrumented.
pub fn play_doubles_game_instrumented(
    spec: &DoublesSpec,
    book: &HashMap<String, Address>,
    track: Option<(u8, usize)>,
) -> DoublesInstr {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new_doubles(
        spec.mons_per_team,
        spec.p0_team.clone(),
        spec.p1_team.clone(),
        spec.p0_ids.clone(),
        spec.p1_ids.clone(),
        book,
    );
    let mut out = DoublesInstr {
        winner_side: None,
        turns: spec.max_turns,
        p0_ids: spec.p0_ids.clone(),
        p1_ids: spec.p1_ids.clone(),
        active_turns_p0: vec![0; spec.p0_ids.len()],
        active_turns_p1: vec![0; spec.p1_ids.len()],
        kos: Vec::new(),
        kos_shared: 0,
        kos_incidental: 0,
        rows: Vec::new(),
        tracked_active_turns: 0,
    };

    for t in 0..spec.max_turns {
        let w = sim.winner_index();
        if w != 2 {
            out.winner_side = Some(w);
            out.turns = t;
            return out;
        }
        let bk = sim.battle_key;
        let (p0a, p0b) = if spec.p0_search_depth > 0 {
            search_side_moves(&mut sim, bk, 0, spec.p0_search_depth, &spec.p0_eval)
        } else {
            pick_side_moves(&mut sim, bk, 0, spec.p0_difficulty, &mut rng)
        };
        let (p1a, p1b) = if spec.p1_search_depth > 0 {
            search_side_moves(&mut sim, bk, 1, spec.p1_search_depth, &spec.p1_eval)
        } else {
            pick_side_moves(&mut sim, bk, 1, spec.p1_difficulty, &mut rng)
        };

        // Slot occupancy + KO state before the turn — the victim's slot must be read pre-execute,
        // since a KO'd slot may already have been vacated by the time we look.
        let slots = active_slots(&mut sim, bk);
        for side in 0u8..2 {
            for abs in side_slots(side) {
                let mon = slots[abs];
                if mon == EMPTY_LANE {
                    continue;
                }
                let counts = if side == 0 { &mut out.active_turns_p0 } else { &mut out.active_turns_p1 };
                if let Some(c) = counts.get_mut(mon as usize) {
                    *c += 1;
                }
            }
        }
        let ko_before = [ko_bitmap(&mut sim, bk, 0), ko_bitmap(&mut sim, bk, 1)];

        if let Some((side, mon)) = track {
            let [s0, s1] = side_slots(side);
            let picked = if side == 0 { (p0a, p0b) } else { (p1a, p1b) };
            let (active, move_index) = if slots[s0] == mon as u32 {
                (true, picked.0.move_index)
            } else if slots[s1] == mon as u32 {
                (true, picked.1.move_index)
            } else {
                (false, NO_OP)
            };
            if active {
                out.tracked_active_turns += 1;
            }
            let mhp = mon_max_hp(&mut sim, OBS, bk, side, mon).max(1);
            let hp = mhp + mon_state(&mut sim, OBS, bk, side, mon, MonStateIndexName::Hp);
            out.rows.push(MonTurnTrace {
                turn: t,
                active,
                move_index,
                hp_pct: (hp.max(0) * 100) as f64 / mhp as f64,
                stamina: mon_current_stamina(&mut sim, OBS, bk, side, mon),
                atk_delta: mon_state(&mut sim, OBS, bk, side, mon, MonStateIndexName::Attack),
            });
        }

        let salt0 = random_salt(&mut rng);
        let salt1 = random_salt(&mut rng);
        let side0 = pack_side(p0a.move_index, p0a.extra_data, p0b.move_index, p0b.extra_data, salt0);
        let side1 = pack_side(p1a.move_index, p1a.extra_data, p1b.move_index, p1b.extra_data, salt1);
        // Rollback point for the co-kill counterfactuals below — the real turn is about to advance
        // the battle past the state they need to be posed from.
        let snap = sim.snapshot(bk);
        sim.execute_slot_turn(side0, side1);

        // Fresh KOs → credit whichever opposing slot aimed at the victim's slot. Exactly one aimer
        // is a clean attribution; two gets resolved by replaying each alone; none means it wasn't a
        // targeted move that did it.
        let bk2 = sim.battle_key;
        for side in 0u8..2 {
            let fresh = ko_bitmap(&mut sim, bk2, side) & !ko_before[side as usize];
            if fresh == 0 {
                continue;
            }
            let opp = 1 - side;
            let opp_moves = if opp == 0 { [p0a, p0b] } else { [p1a, p1b] };
            let (victim_ids, killer_ids) = if side == 0 {
                (&spec.p0_ids, &spec.p1_ids)
            } else {
                (&spec.p1_ids, &spec.p0_ids)
            };
            for v in 0..victim_ids.len() {
                if fresh & (1u32 << v) == 0 {
                    continue;
                }
                let Some(v_abs) = side_slots(side).into_iter().find(|&a| slots[a] == v as u32) else {
                    out.kos_incidental += 1; // victim wasn't an active slot this turn
                    continue;
                };
                let aimers: Vec<usize> = (0..2).filter(|&i| aimed_at(opp_moves[i], v_abs)).collect();
                if aimers.is_empty() {
                    out.kos_incidental += 1; // nothing targeted it — status, recoil, or ally damage
                    continue;
                }
                // Both aimed → replay each alone; the one lethal by itself earns the credit. If
                // neither or both are, the KO is genuinely shared and stays out of the matrix.
                let lethal: Vec<usize> = if aimers.len() == 2 {
                    aimers
                        .iter()
                        .copied()
                        .filter(|&i| {
                            would_ko_alone(&mut sim, snap, opp, i, opp_moves[i], side, v, (salt0, salt1))
                        })
                        .collect()
                } else {
                    aimers
                };
                let [i] = lethal.as_slice() else {
                    out.kos_shared += 1;
                    continue;
                };
                let k_abs = side_slots(opp)[*i];
                match killer_ids.get(slots[k_abs] as usize) {
                    Some(&killer_id) => out.kos.push(DoublesKoEvent {
                        turn: t,
                        killer_seat: opp,
                        killer_id,
                        victim_id: victim_ids[v],
                    }),
                    None => out.kos_incidental += 1,
                }
            }
        }
        sim.dispose_fork(snap);
    }
    let fw = sim.winner_index();
    out.winner_side = if fw != 2 { Some(fw) } else { None };
    out
}

#[cfg(test)]
mod pilot_tests {
    use super::*;
    use crate::arena::build_doubles_specs;
    use crate::roster::{self, load_roster};

    fn chomp_root() -> std::path::PathBuf {
        std::env::var("CHOMP_ROOT").map(std::path::PathBuf::from).unwrap_or_else(|_| {
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
        })
    }

    /// Every mon must be able to take a real action in doubles. A move whose hand-written
    /// `getMeta()` quotes `basePower: 0` used to be dropped from the option set, which left a mon
    /// with an all-custom kit (Iblivion) with nothing to pick and resting every turn of every game.
    #[test]
    fn every_mon_can_act_in_doubles() {
        let roster = load_roster(&chomp_root());
        let book = roster::address_book();
        let (specs, _) = build_doubles_specs(&roster, 240, 0xbeefcafe, 10_000, true, 0);

        for m in &roster.mons {
            let mut appearances = 0;
            let mut acted = false;
            for spec in &specs {
                for side in 0u8..2 {
                    let ids = if side == 0 { &spec.p0_ids } else { &spec.p1_ids };
                    let Some(mon) = ids.iter().position(|&x| x == m.id) else { continue };
                    appearances += 1;
                    let tr = play_doubles_game_instrumented(spec, &book, Some((side, mon)));
                    if tr.rows.iter().any(|r| r.active && r.move_index != NO_OP && r.move_index != SWITCH) {
                        acted = true;
                        break;
                    }
                }
                if acted {
                    break;
                }
            }
            assert!(appearances > 0, "{} never drafted — widen the sample", m.name);
            assert!(acted, "{} never used a move in {appearances} doubles appearances", m.name);
        }
    }

    /// KO attribution must stay conservative and well-covered: every KO lands in exactly one of
    /// credited / co-kill / incidental (no double-counting), and the co-kill replay must recover the
    /// bulk of the turns where both slots aimed at the same victim — without it, coverage sits near
    /// half and focus-fired mons are systematically under-counted as victims.
    #[test]
    fn ko_attribution_is_covered_and_conserved() {
        let roster = load_roster(&chomp_root());
        let book = roster::address_book();
        let (specs, _) = build_doubles_specs(&roster, 300, 0xbeefcafe, 10_000, true, 0);
        let recs = run_doubles_games_instrumented(&specs, &book, 1);

        let credited: usize = recs.iter().map(|r| r.kos.len()).sum();
        let shared: u32 = recs.iter().map(|r| r.kos_shared).sum();
        let incidental: u32 = recs.iter().map(|r| r.kos_incidental).sum();
        let total = credited as u32 + shared + incidental;
        assert!(total > 0, "no KOs observed — widen the sample");

        // A credited KO names a killer on the crediting side and a victim on the other. (killer_id
        // == victim_id is legal: the two teams are drawn independently, so mirrors happen.)
        for r in &recs {
            for ko in &r.kos {
                let (killers, victims) = if ko.killer_seat == 0 {
                    (&r.p0_ids, &r.p1_ids)
                } else {
                    (&r.p1_ids, &r.p0_ids)
                };
                assert!(killers.contains(&ko.killer_id), "killer not on the crediting side");
                assert!(victims.contains(&ko.victim_id), "victim not on the opposing side");
            }
        }

        let coverage = credited as f64 / total as f64;
        assert!(coverage > 0.6, "KO attribution coverage fell to {:.0}% — co-kill replay regressed", coverage * 100.0);
    }

    /// The probe must actually price a zero-quote move. Iblivion's kit is entirely hand-written
    /// `IMoveSet`, so every one of its damage options comes from simulation — if the probe silently
    /// returned 0 the pilot would be picking blind even though it has candidates.
    #[test]
    fn probe_prices_a_zero_quote_kit() {
        let roster = load_roster(&chomp_root());
        let book = roster::address_book();
        let iblivion = roster.mons.iter().find(|m| m.name == "Iblivion").expect("Iblivion in roster");
        let (specs, _) = build_doubles_specs(&roster, 240, 0xbeefcafe, 10_000, true, 0);

        let mut priced = false;
        'outer: for spec in &specs {
            for side in 0u8..2 {
                let ids = if side == 0 { &spec.p0_ids } else { &spec.p1_ids };
                if !ids.contains(&iblivion.id) {
                    continue;
                }
                let mut sim = Sim::new_doubles(
                    spec.mons_per_team,
                    spec.p0_team.clone(),
                    spec.p1_team.clone(),
                    spec.p0_ids.clone(),
                    spec.p1_ids.clone(),
                    &book,
                );
                let bk = sim.battle_key;
                // Turn 0 is the send-in; step once so both sides have live actives to price against.
                sim.execute_slot_turn(
                    pack_side(SWITCH, 0, SWITCH, 1, 0),
                    pack_side(SWITCH, 0, SWITCH, 1, 0),
                );
                let mon = ids.iter().position(|&x| x == iblivion.id).unwrap() as u32;
                let opts = damaging_options(&mut sim, bk, side, mon);
                if opts.iter().any(|&(_, d)| d > 0) {
                    priced = true;
                    break 'outer;
                }
            }
        }
        assert!(priced, "probe never produced a non-zero damage estimate for Iblivion's all-custom kit");
    }
}

/// One instrumented doubles game, with the same engine-panic guard as the plain runner (a panic
/// yields an empty record, counted as a draw, rather than taking down the batch).
fn run_one_doubles_instrumented(spec: &DoublesSpec, book: &HashMap<String, Address>) -> DoublesInstr {
    catch_unwind(AssertUnwindSafe(|| play_doubles_game_instrumented(spec, book, None))).unwrap_or_else(|_| {
        DoublesInstr {
            winner_side: None,
            turns: 0,
            p0_ids: spec.p0_ids.clone(),
            p1_ids: spec.p1_ids.clone(),
            active_turns_p0: vec![0; spec.p0_ids.len()],
            active_turns_p1: vec![0; spec.p1_ids.len()],
            kos: Vec::new(),
            kos_shared: 0,
            kos_incidental: 0,
            rows: Vec::new(),
            tracked_active_turns: 0,
        }
    })
}

/// Instrumented counterpart of [`run_doubles_games`]; results come back in spec order.
pub fn run_doubles_games_instrumented(
    specs: &[DoublesSpec],
    book: &HashMap<String, Address>,
    threads: usize,
) -> Vec<DoublesInstr> {
    if threads <= 1 || specs.len() <= 1 {
        return specs.iter().map(|s| run_one_doubles_instrumented(s, book)).collect();
    }
    let n = threads.min(specs.len());
    let mut slots: Vec<Option<DoublesInstr>> = Vec::with_capacity(specs.len());
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
                let r = run_one_doubles_instrumented(&specs[idx], book);
                slots.lock().unwrap()[idx] = Some(r);
            });
        }
    });
    slots.into_inner().unwrap().into_iter().map(|r| r.expect("slot filled")).collect()
}
