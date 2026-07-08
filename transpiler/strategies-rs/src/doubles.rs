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

use chomp_engine::Enums::MoveClass;
use chomp_engine::Engine;
use chomp_engine::Structs::{Mon, MoveMeta};
use chomp_rt::{Address, B256, U256};

use crate::jsrng::{random_salt, JsRng};
use crate::shared::{build_damage_calc_context, estimate_damage_meta};
use crate::sim::{pack_side, Sim};
use crate::view::{decode_meta, mon_current_stamina, move_slot, turn_id, Seat};

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

#[derive(Clone, Copy)]
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
        return None;
    }

    let stamina = mon_current_stamina(sim, OBS, bk, cpu_side, my_mon as usize);
    // Decode my active mon's up-to-4 move metas once.
    let metas: Vec<(u8, MoveMeta)> = (0..4)
        .filter_map(|mi| {
            let slot = move_slot(sim, OBS, bk, cpu_side, my_mon as usize, mi)?;
            Some((mi as u8, decode_meta(sim, bk, cpu_side, my_mon as usize, slot)))
        })
        .collect();

    // Every affordable damaging (move, target) with its estimated damage.
    let mut options: Vec<(SlotMove, i64)> = Vec::new();
    for &(t_abs, t_mon) in &targets {
        let mut ctx = build_damage_calc_context(sim, OBS, bk, cpu_side, my_mon as usize, opp_side, t_mon);
        for (mi, meta) in &metas {
            if meta.stamina as i64 > stamina {
                continue; // unaffordable
            }
            if meta.moveClass != MoveClass::Physical && meta.moveClass != MoveClass::Special {
                continue; // greedy only weighs damaging moves
            }
            let dmg = estimate_damage_meta(&mut ctx, meta);
            if dmg > 0 {
                options.push((SlotMove { move_index: *mi, extra_data: target_bits(t_abs) }, dmg));
            }
        }
    }
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
        let (p0a, p0b) = pick_side_moves(&mut sim, bk, 0, spec.p0_difficulty, &mut rng);
        let (p1a, p1b) = pick_side_moves(&mut sim, bk, 1, spec.p1_difficulty, &mut rng);
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
