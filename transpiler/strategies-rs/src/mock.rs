//! Mock pipeline T1 — a load-time parameter overlay on an existing move (measure.md's evidence bar).
//! Repacks the inline move word to override power / stamina / accuracy / priority, then A/B's the
//! overlaid roster against the baseline on MATCHED drafts (identical seeds), reading the counterfactual
//! win-rate change for the target mon. Deployed (address-word) moves can't be overlaid this way —
//! they need a T2 hand-written mock contract (a follow-up); the overlay leaves them unchanged.
//!
//! Bit layout (packMoves.py): [basePower:8|moveClass:2|priority:2|moveType:4|stamina:4|effectAccuracy:8|_:68|effect:160].

use chomp_engine::moves::MoveSlotLib;
use chomp_engine::Structs::Mon;
use chomp_rt::U256;

use crate::analysis::{fold, MonStat};
use crate::arena::build_specs;
use crate::game::run_games_instrumented;
use crate::roster::{self, Roster};

#[derive(Default, Clone, Copy, Debug)]
pub struct MoveOverride {
    pub base_power: Option<u8>,
    pub stamina: Option<u8>,
    pub effect_accuracy: Option<u8>,
    pub priority: Option<u8>,
}

fn set_field(word: U256, value: u64, width: u32, shift: u32) -> U256 {
    let mask = !((U256::from((1u64 << width) - 1)) << shift);
    (word & mask) | (U256::from(value & ((1u64 << width) - 1)) << shift)
}

/// Apply the overlay to an inline move word. Deployed moves are returned unchanged.
pub fn apply_inline_override(word: U256, ov: &MoveOverride) -> U256 {
    if !MoveSlotLib::isInline(word) {
        return word;
    }
    let mut w = word;
    if let Some(bp) = ov.base_power {
        w = set_field(w, bp as u64, 8, 248);
    }
    if let Some(pr) = ov.priority {
        w = set_field(w, pr as u64, 2, 244);
    }
    if let Some(st) = ov.stamina {
        w = set_field(w, st as u64, 4, 236);
    }
    if let Some(ea) = ov.effect_accuracy {
        w = set_field(w, ea as u64, 8, 228);
    }
    w
}

fn override_lane(mon: &mut Mon, lane: usize, ov: &MoveOverride) {
    if lane < mon.moves.len() {
        mon.moves[lane] = apply_inline_override(mon.moves[lane], ov);
    }
}

/// True if the target mon's lane resolves to an inline (overlay-able) move.
pub fn lane_is_inline(roster: &Roster, target_id: u32, lane: usize) -> bool {
    roster
        .mon_by_id(target_id)
        .and_then(|m| m.catalog.get(lane))
        .map(|c| MoveSlotLib::isInline(c.word))
        .unwrap_or(false)
}

/// Run baseline vs overlaid on the SAME drafts and return (baseline, overlaid) stats for the target.
pub fn run_mock_ab(
    roster: &Roster,
    games: usize,
    wseed: u32,
    seed_base: u32,
    threads: usize,
    target_id: u32,
    lane: usize,
    ov: MoveOverride,
) -> (MonStat, MonStat) {
    let book = roster::address_book();
    let (mut specs, _) = build_specs(roster, games, wseed, seed_base);

    let base = fold(&run_games_instrumented(&specs, &book, threads));

    // Overlay the target mon's lane in every drafted team (both seats), same seeds.
    for spec in &mut specs {
        for slot in 0..spec.p0_ids.len() {
            if spec.p0_ids[slot] == target_id {
                override_lane(&mut spec.p0_team[slot], lane, &ov);
            }
        }
        for slot in 0..spec.p1_ids.len() {
            if spec.p1_ids[slot] == target_id {
                override_lane(&mut spec.p1_team[slot], lane, &ov);
            }
        }
    }
    let overlaid = fold(&run_games_instrumented(&specs, &book, threads));

    let empty = MonStat::default();
    (
        base.per_mon.get(&target_id).cloned().unwrap_or_else(|| empty.clone()),
        overlaid.per_mon.get(&target_id).cloned().unwrap_or(empty),
    )
}
