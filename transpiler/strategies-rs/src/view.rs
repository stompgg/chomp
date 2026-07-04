//! Seat translation + engine-view readers + candidate enumeration.
//!
//! Port of `sims/src/cpu/engine-view.ts` and `sims/src/cpu/battle-view.ts`,
//! with the seat transposition of `sims/src/arena/transpose.ts` folded into
//! a [`Seat`] value instead of a JS Proxy.
//!
//! Convention (inherited from the on-chain CPUs): strategy code sees the
//! CPU as p1 and the opponent as p0 — VIRTUAL indices. `Seat` maps virtual
//! player indices to physical ones on exactly the reads the TS proxy
//! flips; everything else (MoveSlotLib meta/priority calls, globalKV keys
//! computed inside external moves) receives the VIRTUAL index unmapped,
//! reproducing the TS proxy's reach precisely — including its known hole:
//! HeatBeacon-style priority boosts read the KV slot of the VIRTUAL index.

use chomp_engine::moves::MoveSlotLib;
use chomp_engine::types::TypeCalcLib;
use chomp_engine::Engine;
use chomp_engine::Enums::{ExtraDataType, MonStateIndexName, Type};
use chomp_engine::Structs::{DamageCalcContext, MonStats};
use chomp_rt::{B256, U256};

use crate::jsrng::JsRng;
use crate::sim::{HypoMove, Sim};

pub const SWITCH_MOVE_INDEX: u8 = 125;
pub const NO_OP_INDEX: u8 = 126;

/// Virtual player index: the CPU is always 1, the opponent always 0.
pub const VCPU: u8 = 1;
pub const VOPP: u8 = 0;

/// A candidate action (`RevealedMove` in the TS stack).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mv {
    pub move_index: u8,
    pub extra_data: u16,
}

/// Which physical side this strategy instance plays. `cpu == 1` is the
/// identity seat; `cpu == 0` transposes (the TS `transposeEngine` proxy).
#[derive(Clone, Copy, Debug)]
pub struct Seat {
    pub cpu: u8,
}

impl Seat {
    pub fn flipped(self) -> bool {
        self.cpu == 0
    }

    /// Virtual player index (0 = opp, 1 = cpu) -> physical engine index.
    pub fn phys(self, vp: u8) -> U256 {
        let p = if self.flipped() { 1 - vp } else { vp };
        U256::from(p as u64)
    }
}

// ---------------------------------------------------------------------------
// Engine readers (seat-mapped — the proxy-flipped surface)
// ---------------------------------------------------------------------------

pub fn turn_id(sim: &mut Sim, bk: B256) -> u64 {
    u64::try_from(Engine::getTurnIdForBattleState(&mut sim.world, bk)).unwrap()
}

/// playerSwitchForTurnFlag through the seat: 0/1 flip on the transposed
/// seat (2 = both move passes through), like the proxied getBattleContext.
pub fn switch_flag(sim: &mut Sim, seat: Seat, bk: B256) -> u8 {
    let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag;
    if seat.flipped() && flag < 2 {
        1 - flag
    } else {
        flag
    }
}

/// Virtual [opp active, cpu active] (the proxied getActiveMonIndex swap).
pub fn active_mon_indices(sim: &mut Sim, seat: Seat, bk: B256) -> (usize, usize) {
    let r = Engine::getActiveMonIndexForBattleState(&mut sim.world, bk);
    let p0 = u64::try_from(r[0]).unwrap() as usize;
    let p1 = u64::try_from(r[1]).unwrap() as usize;
    if seat.flipped() {
        (p1, p0)
    } else {
        (p0, p1)
    }
}

pub fn team_size(sim: &mut Sim, seat: Seat, bk: B256, vp: u8) -> usize {
    u64::try_from(Engine::getTeamSize(&mut sim.world, bk, seat.phys(vp))).unwrap() as usize
}

pub fn ko_bitmap(sim: &mut Sim, seat: Seat, bk: B256, vp: u8) -> u32 {
    u64::try_from(Engine::getKOBitmap(&mut sim.world, bk, seat.phys(vp))).unwrap() as u32
}

pub fn mon_stats(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize) -> MonStats {
    Engine::getMonStatsForBattle(&mut sim.world, bk, seat.phys(vp), U256::from(mon as u64))
}

pub fn mon_value(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize, idx: MonStateIndexName) -> i64 {
    Engine::getMonValueForBattle(&mut sim.world, bk, seat.phys(vp), U256::from(mon as u64), idx) as i64
}

/// Delta reads come back sentinel-normalized from the getter (0 for a
/// cleared/switched-out mon), exactly like the TS local engine.
pub fn mon_state(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize, idx: MonStateIndexName) -> i64 {
    Engine::getMonStateForBattle(&mut sim.world, bk, seat.phys(vp), U256::from(mon as u64), idx) as i64
}

pub fn mon_max_hp(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize) -> i64 {
    mon_value(sim, seat, bk, vp, mon, MonStateIndexName::Hp)
}

pub fn mon_current_hp(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize) -> i64 {
    mon_max_hp(sim, seat, bk, vp, mon) + mon_state(sim, seat, bk, vp, mon, MonStateIndexName::Hp)
}

pub fn mon_current_stamina(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize) -> i64 {
    mon_value(sim, seat, bk, vp, mon, MonStateIndexName::Stamina)
        + mon_state(sim, seat, bk, vp, mon, MonStateIndexName::Stamina)
}

pub fn mon_current_speed(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize) -> i64 {
    mon_value(sim, seat, bk, vp, mon, MonStateIndexName::Speed)
        + mon_state(sim, seat, bk, vp, mon, MonStateIndexName::Speed)
}

pub fn mon_types(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize) -> (Type, Type) {
    (
        Type::from_u8(mon_value(sim, seat, bk, vp, mon, MonStateIndexName::Type1) as u8),
        Type::from_u8(mon_value(sim, seat, bk, vp, mon, MonStateIndexName::Type2) as u8),
    )
}

pub fn mon_skip_turn(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize) -> bool {
    mon_state(sim, seat, bk, vp, mon, MonStateIndexName::ShouldSkipTurn) != 0
}

/// Raw move slot, or None for an empty lane (mirrors the TS adapter:
/// arena mons always carry 4 real moves, so a zero word means "no slot").
pub fn move_slot(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize, mi: usize) -> Option<U256> {
    let raw = Engine::getMoveForMonForBattle(
        &mut sim.world,
        bk,
        seat.phys(vp),
        U256::from(mon as u64),
        U256::from(mi as u64),
    );
    if raw == U256::ZERO {
        None
    } else {
        Some(raw)
    }
}

/// Damage context between the two ACTIVE mons (proxied: both player-index
/// args seat-mapped).
pub fn damage_calc_context(sim: &mut Sim, seat: Seat, bk: B256, atk_vp: u8, def_vp: u8) -> DamageCalcContext {
    Engine::getDamageCalcContext(&mut sim.world, bk, seat.phys(atk_vp), seat.phys(def_vp))
}

/// `TYPE_CALC.getTypeEffectiveness` — TypeCalculator delegates straight to
/// TypeCalcLib, so the lib call is the faithful equivalent.
pub fn type_effectiveness(attack: Type, defender: Type, scale: u32) -> i64 {
    TypeCalcLib::getTypeEffectiveness(attack, defender, scale) as i64
}

/// Virtual-side hypothetical turn: fork + silent execute with the seat's
/// p0/p1 mapped to physical sides (the transposed `__runHypotheticalFork`
/// arg swap). Returns the fork key.
pub fn apply_hypothetical(sim: &mut Sim, seat: Seat, vp0: Option<HypoMove>, vp1: Option<HypoMove>) -> B256 {
    if seat.flipped() {
        sim.apply_hypothetical(vp1, vp0)
    } else {
        sim.apply_hypothetical(vp0, vp1)
    }
}

// ---------------------------------------------------------------------------
// Battle view (battle-view.ts) — read-once snapshot of a position.
// ---------------------------------------------------------------------------

/// Per-slot snapshot: the eager fields every consumer touches. The TS
/// LazyMonView's heavy fields (stamina / types / statDeltaScore / skip)
/// are read on demand from the view's `bk` via the readers above instead
/// of being cached — same values, no cache to keep coherent.
#[derive(Clone, Copy, Debug)]
pub struct MonSnap {
    pub hp: i64,
    pub max_hp: i64,
    pub ko: bool,
}

pub struct BattleView {
    pub bk: B256,
    /// 0 = p0-only, 1 = p1-only (CPU forced switch), 2 = both move —
    /// already seat-flipped (virtual).
    pub switch_flag: u8,
    pub cpu_active: usize,
    pub opp_active: usize,
    pub cpu_ko: u32,
    pub opp_ko: u32,
    /// Virtual p0 (opponent) side, one entry per team slot.
    pub p0: Vec<MonSnap>,
    /// Virtual p1 (CPU) side.
    pub p1: Vec<MonSnap>,
}

fn read_side(sim: &mut Sim, seat: Seat, bk: B256, vp: u8) -> Vec<MonSnap> {
    let size = team_size(sim, seat, bk, vp);
    let ko = ko_bitmap(sim, seat, bk, vp);
    (0..size)
        .map(|i| {
            let max_hp = mon_max_hp(sim, seat, bk, vp, i);
            let hp = max_hp + mon_state(sim, seat, bk, vp, i, MonStateIndexName::Hp);
            MonSnap { hp, max_hp, ko: (ko & (1 << i)) != 0 }
        })
        .collect()
}

/// Read-once snapshot at `bk` (live key or fork key).
pub fn capture_view(sim: &mut Sim, seat: Seat, bk: B256) -> BattleView {
    let (opp_active, cpu_active) = active_mon_indices(sim, seat, bk);
    BattleView {
        bk,
        switch_flag: switch_flag(sim, seat, bk),
        cpu_active,
        opp_active,
        cpu_ko: ko_bitmap(sim, seat, bk, VCPU),
        opp_ko: ko_bitmap(sim, seat, bk, VOPP),
        p0: read_side(sim, seat, bk, VOPP),
        p1: read_side(sim, seat, bk, VCPU),
    }
}

/// Σ delta/base over the five combat stats (battle-view.ts
/// readStatDeltaScore) — f64 accumulation in source order.
pub fn stat_delta_score(sim: &mut Sim, seat: Seat, bk: B256, vp: u8, mon: usize) -> f64 {
    let stats = mon_stats(sim, seat, bk, vp, mon);
    let mut score = 0.0f64;
    for (base, idx) in [
        (stats.attack, MonStateIndexName::Attack),
        (stats.defense, MonStateIndexName::Defense),
        (stats.specialAttack, MonStateIndexName::SpecialAttack),
        (stats.specialDefense, MonStateIndexName::SpecialDefense),
        (stats.speed, MonStateIndexName::Speed),
    ] {
        if base == 0 {
            continue; // TS: base <= 0 contributes nothing
        }
        score += mon_state(sim, seat, bk, vp, mon, idx) as f64 / base as f64;
    }
    score
}

// ---------------------------------------------------------------------------
// calculateValidMoves — port of CPU._calculateValidMoves (engine-view.ts)
// ---------------------------------------------------------------------------

pub struct ValidMoves {
    pub no_op: Vec<Mv>,
    pub moves: Vec<Mv>,
    pub switches: Vec<Mv>,
}

fn validate(sim: &mut Sim, seat: Seat, bk: B256, move_index: u8, extra_data: u16) -> bool {
    Engine::validatePlayerMoveForBattle(
        &mut sim.world,
        bk,
        U256::from(move_index as u64),
        seat.phys(VCPU),
        extra_data,
    )
}

/// The three candidate buckets. `rng` draws extraData targets for
/// Self/Opponent-index moves in the exact TS order (stream parity).
pub fn calculate_valid_moves(sim: &mut Sim, seat: Seat, bk: B256, rng: &mut JsRng) -> ValidMoves {
    let t_id = turn_id(sim, bk);
    let p1_team_size = team_size(sim, seat, bk, VCPU);

    // Turn 0: every team slot is an (unvalidated) switch-in choice.
    if t_id == 0 {
        let switches = (0..p1_team_size)
            .map(|i| Mv { move_index: SWITCH_MOVE_INDEX, extra_data: i as u16 })
            .collect();
        return ValidMoves { no_op: vec![], moves: vec![], switches };
    }

    let (_, active_mon_index) = active_mon_indices(sim, seat, bk);

    // Valid switch targets (i != active, validated).
    let mut valid_switch_indices: Vec<usize> = Vec::new();
    for i in 0..p1_team_size {
        if i != active_mon_index && validate(sim, seat, bk, SWITCH_MOVE_INDEX, i as u16) {
            valid_switch_indices.push(i);
        }
    }
    let switches: Vec<Mv> = valid_switch_indices
        .iter()
        .map(|&i| Mv { move_index: SWITCH_MOVE_INDEX, extra_data: i as u16 })
        .collect();

    // A CPU forced-switch turn returns ONLY valid switches.
    if switch_flag(sim, seat, bk) == 1 {
        return ValidMoves { no_op: vec![], moves: vec![], switches };
    }

    // Enumerate valid moves; pick extraData targets like _calculateValidMoves.
    let mut moves: Vec<Mv> = Vec::new();
    for i in 0..4usize {
        let Some(slot) = move_slot(sim, seat, bk, VCPU, active_mon_index, i) else {
            break; // <4-move mon: stop at the real move count
        };

        let mut extra_data_to_use: u16 = 0;

        if !MoveSlotLib::isInline(slot) {
            // Meta decode takes the VIRTUAL player index (see module docs).
            let edt = MoveSlotLib::decodeMeta(
                &mut sim.world,
                slot,
                sim.engine_addr,
                bk,
                U256::from(VCPU as u64),
                U256::from(active_mon_index as u64),
            )
            .extraDataType;

            if edt == ExtraDataType::SelfTeamIndex {
                if valid_switch_indices.is_empty() {
                    continue;
                }
                let r = (rng.next() * valid_switch_indices.len() as f64).floor() as usize;
                extra_data_to_use = valid_switch_indices[r] as u16;
            } else if edt == ExtraDataType::OpponentNonKOTeamIndex {
                let opponent_team_size = team_size(sim, seat, bk, VOPP);
                let opp_ko = ko_bitmap(sim, seat, bk, VOPP);
                let valid_targets: Vec<usize> =
                    (0..opponent_team_size).filter(|j| (opp_ko & (1 << j)) == 0).collect();
                if valid_targets.is_empty() {
                    continue;
                }
                let r = (rng.next() * valid_targets.len() as f64).floor() as usize;
                extra_data_to_use = valid_targets[r] as u16;
            }
            // None / InclusiveRange fall through with extraData 0.
        }

        if validate(sim, seat, bk, i as u8, extra_data_to_use) {
            moves.push(Mv { move_index: i as u8, extra_data: extra_data_to_use });
        }
    }

    // A single no-op is always offered on a non-forced-switch turn.
    let no_op = vec![Mv { move_index: NO_OP_INDEX, extra_data: 0 }];
    ValidMoves { no_op, moves, switches }
}

/// Uniform pick (`pickUniform`): None for an empty list.
pub fn pick_uniform(len: usize, rng: &mut JsRng) -> Option<usize> {
    if len == 0 {
        return None;
    }
    Some((rng.next() * len as f64).floor() as usize)
}
