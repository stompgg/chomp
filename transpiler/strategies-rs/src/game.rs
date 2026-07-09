//! Game loop + batch runner — port of `sims/src/arena/game.ts`'s
//! `runGameLoop` seating/peek/salt semantics, driving [`Sim`] natively.
//!
//! RNG stream discipline (must match TS turn-for-turn): the p0 seat
//! decides first (its candidate enumeration + tie-breaks draw from the
//! shared rng), then the p1 seat with the true reveal, then salts are
//! drawn ONLY for acting sides, p0 before p1.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};

use chomp_engine::Engine;
use chomp_engine::Structs::Mon;
use chomp_rt::{Address, B256};

use crate::native::ForkCache;

use crate::greedy;
use crate::hard::{self, HardState};
use crate::jsrng::{random_salt, JsRng};
use crate::nopeek;
use crate::override_cpu::{self, OverrideState};
use crate::sim::Sim;
use crate::view::{
    active_mon_indices, capture_view, ko_bitmap, mon_current_hp, mon_current_stamina, mon_max_hp, Mv,
    Seat, NO_OP_INDEX, SWITCH_MOVE_INDEX, VCPU, VOPP,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StrategyKind {
    Hard,
    Greedy,
    Override,
    /// No-peek greedy, expectation over the opponent's plausible replies.
    NoPeekExpect,
    /// No-peek greedy, worst-case (maximin) over the opponent's plausible replies.
    NoPeekWorst,
}

impl StrategyKind {
    /// Names are a contract with the TS registry (`sims/src/cpu/registry.ts`)
    /// and `workload.ts`'s STRAT_PAIRS — keep them in sync when adding a
    /// strategy.
    pub fn parse(name: &str) -> Option<StrategyKind> {
        match name {
            "hard" => Some(StrategyKind::Hard),
            "greedy" => Some(StrategyKind::Greedy),
            "override" => Some(StrategyKind::Override),
            "nopeek" => Some(StrategyKind::NoPeekExpect),
            "nopeek-wc" => Some(StrategyKind::NoPeekWorst),
            _ => None,
        }
    }
}

#[derive(Clone)]
pub struct GameSpec {
    pub seed: u32,
    pub max_turns: u32,
    pub mons_per_team: u64,
    pub p0_team: Vec<Mon>,
    pub p1_team: Vec<Mon>,
    /// Global mon-ids per team slot (parallel to p0_team/p1_team) — lets the CPU
    /// look up per-mon config by identity. Empty to disable (config stays inert).
    pub p0_ids: Vec<u32>,
    pub p1_ids: Vec<u32>,
    pub p0_strategy: StrategyKind,
    pub p1_strategy: StrategyKind,
}

/// One turn's submitted moves (physical p0/p1; None = side didn't act).
#[derive(Clone, Copy, Debug)]
pub struct TurnTrace {
    pub p0: Option<Mv>,
    pub p1: Option<Mv>,
}

pub struct GameOutcome {
    /// 0 / 1, or None for a turn-cap draw (stalemate).
    pub winner_seat: Option<u8>,
    pub turns: u32,
    /// Per-turn submissions when tracing.
    pub trace: Vec<TurnTrace>,
}

/// Per-seat mutable strategy state (`createState()` in the TS framework).
enum StratState {
    Hard(HardState),
    Greedy,
    Override(OverrideState),
    NoPeekExpect,
    NoPeekWorst,
}

impl StratState {
    fn new(kind: StrategyKind) -> StratState {
        match kind {
            StrategyKind::Hard => StratState::Hard(HardState::default()),
            StrategyKind::Greedy => StratState::Greedy,
            StrategyKind::Override => StratState::Override(OverrideState::default()),
            StrategyKind::NoPeekExpect => StratState::NoPeekExpect,
            StrategyKind::NoPeekWorst => StratState::NoPeekWorst,
        }
    }
}

struct SeatState {
    seat: Seat,
    state: StratState,
    last_own_move: Mv,
}

fn decide_one(sim: &mut Sim, s: &mut SeatState, pm: Mv, rng: &mut JsRng) -> Mv {
    let view = capture_view(sim, s.seat, sim.battle_key);
    match &mut s.state {
        StratState::Hard(st) => hard::decide(sim, s.seat, &view, pm, rng, st),
        StratState::Greedy => greedy::decide(sim, s.seat, &view, pm, rng),
        StratState::Override(st) => override_cpu::decide(sim, s.seat, &view, pm, rng, st),
        StratState::NoPeekExpect => nopeek::decide_expect(sim, s.seat, &view, rng),
        StratState::NoPeekWorst => nopeek::decide_worst(sim, s.seat, &view, rng),
    }
}

pub fn play_game(spec: &GameSpec, book: &HashMap<String, Address>, trace: bool) -> GameOutcome {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new(
        spec.mons_per_team,
        spec.p0_team.clone(),
        spec.p1_team.clone(),
        spec.p0_ids.clone(),
        spec.p1_ids.clone(),
        book,
    );

    let mut seats = [
        SeatState {
            seat: Seat { cpu: 0 },
            state: StratState::new(spec.p0_strategy),
            last_own_move: Mv { move_index: 0, extra_data: 0 },
        },
        SeatState {
            seat: Seat { cpu: 1 },
            state: StratState::new(spec.p1_strategy),
            last_own_move: Mv { move_index: 0, extra_data: 0 },
        },
    ];

    let mut traces: Vec<TurnTrace> = Vec::new();

    for t in 0..spec.max_turns {
        let winner = sim.winner_index();
        if winner != 2 {
            return GameOutcome { winner_seat: Some(winner), turns: t, trace: traces };
        }

        let bk: B256 = sim.battle_key;
        let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag;
        let p0_acts = flag != 1;
        let p1_acts = flag != 0;

        // p0 seat decides first, peeking only the opponent's previous move.
        let mut p0_move: Option<Mv> = None;
        if p0_acts {
            let peek = seats[1].last_own_move;
            let mv = decide_one(&mut sim, &mut seats[0], peek, &mut rng);
            seats[0].last_own_move = mv;
            p0_move = Some(mv);
        }
        // p1 seat replies with the true reveal (production semantics).
        let mut p1_move: Option<Mv> = None;
        if p1_acts {
            let peek = p0_move.unwrap_or(Mv { move_index: 0, extra_data: 0 });
            let mv = decide_one(&mut sim, &mut seats[1], peek, &mut rng);
            seats[1].last_own_move = mv;
            p1_move = Some(mv);
        }

        if trace {
            traces.push(TurnTrace { p0: p0_move, p1: p1_move });
        }

        // Salt only for an acting side, p0 before p1.
        let p0_salt = if p0_move.is_some() { random_salt(&mut rng) } else { 0 };
        let p1_salt = if p1_move.is_some() { random_salt(&mut rng) } else { 0 };
        sim.execute_turn(
            p0_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX),
            p0_salt,
            p0_move.map(|m| m.extra_data).unwrap_or(0),
            p1_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX),
            p1_salt,
            p1_move.map(|m| m.extra_data).unwrap_or(0),
        );
    }

    let final_winner = sim.winner_index();
    if final_winner != 2 {
        GameOutcome { winner_seat: Some(final_winner), turns: spec.max_turns, trace: traces }
    } else {
        GameOutcome { winner_seat: None, turns: spec.max_turns, trace: traces }
    }
}

/// Re-run one game printing the turn-by-turn story (each side's active mon, HP, chosen move) — the
/// qualitative counterpart to the trace. `name_mon`/`name_move` resolve a global mon-id (+ move lane)
/// to a display string; the caller wires them from the roster. Same result as play_game.
pub fn narrate_game(
    spec: &GameSpec,
    book: &HashMap<String, Address>,
    name_mon: impl Fn(u32) -> String,
    name_move: impl Fn(u32, u8) -> String,
) -> GameOutcome {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new(
        spec.mons_per_team,
        spec.p0_team.clone(),
        spec.p1_team.clone(),
        spec.p0_ids.clone(),
        spec.p1_ids.clone(),
        book,
    );
    // Non-flipped observer seat: VOPP reads physical p0, VCPU reads physical p1.
    let obs = Seat { cpu: 1 };

    let mut seats = [
        SeatState { seat: Seat { cpu: 0 }, state: StratState::new(spec.p0_strategy), last_own_move: Mv { move_index: 0, extra_data: 0 } },
        SeatState { seat: Seat { cpu: 1 }, state: StratState::new(spec.p1_strategy), last_own_move: Mv { move_index: 0, extra_data: 0 } },
    ];

    let team_str = |ids: &[u32]| ids.iter().map(|&id| name_mon(id)).collect::<Vec<_>>().join(", ");
    println!(
        "seed {:#x}  p0({:?})=[{}]  vs  p1({:?})=[{}]",
        spec.seed, spec.p0_strategy, team_str(&spec.p0_ids), spec.p1_strategy, team_str(&spec.p1_ids)
    );

    // Resolve a chosen move to a display label for the acting side.
    let label = |mv: Mv, ids: &[u32], active: usize| -> String {
        if mv.move_index == SWITCH_MOVE_INDEX {
            format!("switch→{}", name_mon(ids[mv.extra_data as usize]))
        } else if mv.move_index == NO_OP_INDEX {
            "rest".to_string()
        } else {
            let base = name_move(ids[active], mv.move_index);
            if mv.extra_data != 0 { format!("{base}(tgt {})", mv.extra_data) } else { base }
        }
    };

    let mut deviations = 0u32; // p1(hard) turns where it diverged from the greedy baseline
    for t in 0..spec.max_turns {
        let winner = sim.winner_index();
        if winner != 2 {
            println!(
                "== {} wins after {t} turns · p1 diverged from greedy on {deviations} turns ==",
                if winner == 1 { "p1" } else { "p0" }
            );
            return GameOutcome { winner_seat: Some(winner), turns: t, trace: vec![] };
        }

        let bk: B256 = sim.battle_key;
        let (p0_active, p1_active) = active_mon_indices(&mut sim, obs, bk);
        let p0_hp = mon_current_hp(&mut sim, obs, bk, VOPP, p0_active);
        let p1_hp = mon_current_hp(&mut sim, obs, bk, VCPU, p1_active);
        let p0_mhp = mon_max_hp(&mut sim, obs, bk, VOPP, p0_active);
        let p1_mhp = mon_max_hp(&mut sim, obs, bk, VCPU, p1_active);

        let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag;
        let (p0_acts, p1_acts) = (flag != 1, flag != 0);

        let mut p0_move: Option<Mv> = None;
        if p0_acts {
            let peek = seats[1].last_own_move;
            let mv = decide_one(&mut sim, &mut seats[0], peek, &mut rng);
            seats[0].last_own_move = mv;
            p0_move = Some(mv);
        }
        let mut p1_move: Option<Mv> = None;
        let mut p1_greedy_cf: Option<Mv> = None;
        if p1_acts {
            let peek = p0_move.unwrap_or(Mv { move_index: 0, extra_data: 0 });
            // Counterfactual: what would greedy pick in this exact state? A copied rng + restored
            // fork counter + greedy's own dispose_all leave the live decision fully unperturbed.
            if !matches!(seats[1].state, StratState::Greedy) {
                let cf_view = capture_view(&mut sim, seats[1].seat, bk);
                let mut cf_rng = rng; // JsRng: Copy — a throwaway snapshot of the live stream
                let saved_fc = sim.fork_counter();
                p1_greedy_cf = Some(greedy::decide(&mut sim, seats[1].seat, &cf_view, peek, &mut cf_rng));
                sim.set_fork_counter(saved_fc);
            }
            let mv = decide_one(&mut sim, &mut seats[1], peek, &mut rng);
            seats[1].last_own_move = mv;
            p1_move = Some(mv);
        }

        let p0_lbl = p0_move.map(|m| label(m, &spec.p0_ids, p0_active)).unwrap_or_else(|| "—".into());
        let p1_lbl = p1_move.map(|m| label(m, &spec.p1_ids, p1_active)).unwrap_or_else(|| "—".into());
        // Flag where hard diverges from the greedy baseline.
        let cf_note = match (p1_move, p1_greedy_cf) {
            (Some(h), Some(g)) if (h.move_index, h.extra_data) != (g.move_index, g.extra_data) => {
                deviations += 1;
                format!("  ⟂ greedy→{}", label(g, &spec.p1_ids, p1_active))
            }
            _ => String::new(),
        };
        println!(
            "T{t:<3} p0 {:>10}({p0_hp:>4}/{p0_mhp:<4}) {p0_lbl:<26}| p1 {:>10}({p1_hp:>4}/{p1_mhp:<4}) {p1_lbl:<26}{cf_note}",
            name_mon(spec.p0_ids[p0_active]), name_mon(spec.p1_ids[p1_active]),
        );

        let p0_salt = if p0_move.is_some() { random_salt(&mut rng) } else { 0 };
        let p1_salt = if p1_move.is_some() { random_salt(&mut rng) } else { 0 };
        sim.execute_turn(
            p0_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p0_salt, p0_move.map(|m| m.extra_data).unwrap_or(0),
            p1_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p1_salt, p1_move.map(|m| m.extra_data).unwrap_or(0),
        );
    }

    let final_winner = sim.winner_index();
    println!(
        "== turn cap after {} turns (winner_index {final_winner}) · p1 diverged from greedy on {deviations} turns ==",
        spec.max_turns
    );
    GameOutcome {
        winner_seat: if final_winner != 2 { Some(final_winner) } else { None },
        turns: spec.max_turns,
        trace: vec![],
    }
}

/// Run each spec through `play`, serial or across `threads` scoped workers (each game owns its
/// whole world, so parallelism is trivially safe). Results come back in spec order; a panicking
/// game yields `Err` instead of poisoning the batch. The one home for the scheduling + panic-string
/// extraction that every `run_games_*` variant shares.
fn run_batch<T: Send>(
    specs: &[GameSpec],
    threads: usize,
    play: impl Fn(&GameSpec) -> T + Sync,
) -> Vec<Result<T, String>> {
    let run_one = |spec: &GameSpec| -> Result<T, String> {
        catch_unwind(AssertUnwindSafe(|| play(spec))).map_err(|e| {
            e.downcast_ref::<String>()
                .cloned()
                .or_else(|| e.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_else(|| "panic".to_string())
        })
    };
    if threads <= 1 || specs.len() <= 1 {
        return specs.iter().map(|spec| run_one(spec)).collect();
    }

    let n = threads.min(specs.len());
    let mut slots: Vec<Option<Result<T, String>>> = Vec::with_capacity(specs.len());
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
                let r = run_one(&specs[idx]);
                slots.lock().unwrap()[idx] = Some(r);
            });
        }
    });

    slots.into_inner().unwrap().into_iter().map(|r| r.expect("slot filled")).collect()
}

/// Run a batch of independent games (see `run_batch`).
pub fn run_games(
    specs: &[GameSpec],
    book: &HashMap<String, Address>,
    threads: usize,
    trace: bool,
) -> Vec<Result<GameOutcome, String>> {
    run_batch(specs, threads, |spec| play_game(spec, book, trace))
}

// ── Trace table: per-turn rows for face-off extraction + role measures (measure.md) ──
//
// Same RNG discipline as `play_game`; captures a per-turn row (actives, chosen actions, damage
// traded to each active, stamina, KO bitmaps) that downstream queries segment into face-offs.

#[derive(Clone, Copy, Debug)]
pub struct TurnRow {
    pub turn: u32,
    pub p0_active: u8,   // team slot of each side's active mon (pre-execute)
    pub p1_active: u8,
    pub p0_move: i16,    // move_index, -1 = didn't act; SWITCH_MOVE_INDEX / NO_OP_INDEX as usual
    pub p1_move: i16,
    pub p0_dmg_out: i32, // HP the p0 active removed from the p1 active this turn
    pub p1_dmg_out: i32,
    pub p0_stam: i16,    // active stamina after the turn
    pub p1_stam: i16,
    pub p0_ko: u32,      // KO bitmaps after the turn
    pub p1_ko: u32,
    pub forced: bool,    // a forced-switch turn (switch_flag != 2)
}

pub struct TraceRecord {
    pub winner_seat: Option<u8>,
    pub p0_ids: Vec<u32>,
    pub p1_ids: Vec<u32>,
    pub rows: Vec<TurnRow>,
}

pub fn play_game_traced(spec: &GameSpec, book: &HashMap<String, Address>) -> TraceRecord {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new(
        spec.mons_per_team,
        spec.p0_team.clone(),
        spec.p1_team.clone(),
        spec.p0_ids.clone(),
        spec.p1_ids.clone(),
        book,
    );
    let mut seats = [
        SeatState { seat: Seat { cpu: 0 }, state: StratState::new(spec.p0_strategy), last_own_move: Mv { move_index: 0, extra_data: 0 } },
        SeatState { seat: Seat { cpu: 1 }, state: StratState::new(spec.p1_strategy), last_own_move: Mv { move_index: 0, extra_data: 0 } },
    ];
    let obs = Seat { cpu: 1 };
    let mut rows: Vec<TurnRow> = Vec::new();

    for t in 0..spec.max_turns {
        let winner = sim.winner_index();
        if winner != 2 {
            return TraceRecord { winner_seat: Some(winner), p0_ids: spec.p0_ids.clone(), p1_ids: spec.p1_ids.clone(), rows };
        }

        let bk: B256 = sim.battle_key;
        let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag;
        let p0_acts = flag != 1;
        let p1_acts = flag != 0;
        let forced = flag != 2;

        let mut p0_move: Option<Mv> = None;
        if p0_acts {
            let peek = seats[1].last_own_move;
            let mv = decide_one(&mut sim, &mut seats[0], peek, &mut rng);
            seats[0].last_own_move = mv;
            p0_move = Some(mv);
        }
        let mut p1_move: Option<Mv> = None;
        if p1_acts {
            let peek = p0_move.unwrap_or(Mv { move_index: 0, extra_data: 0 });
            let mv = decide_one(&mut sim, &mut seats[1], peek, &mut rng);
            seats[1].last_own_move = mv;
            p1_move = Some(mv);
        }

        // Pre-execute actives + their HP (damage this turn = HP removed from each active).
        let (p0a, p1a) = active_mon_indices(&mut sim, obs, bk);
        let p0_hp_pre = mon_current_hp(&mut sim, obs, bk, VOPP, p0a);
        let p1_hp_pre = mon_current_hp(&mut sim, obs, bk, VCPU, p1a);

        let p0_salt = if p0_move.is_some() { random_salt(&mut rng) } else { 0 };
        let p1_salt = if p1_move.is_some() { random_salt(&mut rng) } else { 0 };
        sim.execute_turn(
            p0_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p0_salt, p0_move.map(|m| m.extra_data).unwrap_or(0),
            p1_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p1_salt, p1_move.map(|m| m.extra_data).unwrap_or(0),
        );

        let bk2: B256 = sim.battle_key;
        let p0_hp_post = mon_current_hp(&mut sim, obs, bk2, VOPP, p0a);
        let p1_hp_post = mon_current_hp(&mut sim, obs, bk2, VCPU, p1a);
        rows.push(TurnRow {
            turn: t,
            p0_active: p0a as u8,
            p1_active: p1a as u8,
            p0_move: p0_move.map(|m| m.move_index as i16).unwrap_or(-1),
            p1_move: p1_move.map(|m| m.move_index as i16).unwrap_or(-1),
            p0_dmg_out: (p1_hp_pre - p1_hp_post).max(0) as i32,
            p1_dmg_out: (p0_hp_pre - p0_hp_post).max(0) as i32,
            p0_stam: mon_current_stamina(&mut sim, obs, bk2, VOPP, p0a) as i16,
            p1_stam: mon_current_stamina(&mut sim, obs, bk2, VCPU, p1a) as i16,
            p0_ko: ko_bitmap(&mut sim, obs, bk2, VOPP),
            p1_ko: ko_bitmap(&mut sim, obs, bk2, VCPU),
            forced,
        });
    }

    let fw = sim.winner_index();
    TraceRecord { winner_seat: if fw != 2 { Some(fw) } else { None }, p0_ids: spec.p0_ids.clone(), p1_ids: spec.p1_ids.clone(), rows }
}

/// Threaded traced batch (see `run_batch`).
pub fn run_games_traced(
    specs: &[GameSpec],
    book: &HashMap<String, Address>,
    threads: usize,
) -> Vec<Result<TraceRecord, String>> {
    run_batch(specs, threads, |spec| play_game_traced(spec, book))
}

// ── Yomi sampler: EVPI over the no-peek grid at each two-sided decision (measure.md) ──
//
// Drives the game with its spec pilots but, at every turn where both sides act, computes the
// no-peek my-action × their-action grid for each seat (on a scratch rng copy + saved fork counter,
// so the live game is unperturbed) and reads its yomi tension. Attributed to each seat's active mon.

#[derive(Clone, Copy, Debug)]
pub struct YomiSample {
    pub mon_id: u32,
    pub evpi: f64,
    pub seat: u8,
}

pub fn play_game_yomi(spec: &GameSpec, book: &HashMap<String, Address>) -> Vec<YomiSample> {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new(
        spec.mons_per_team,
        spec.p0_team.clone(),
        spec.p1_team.clone(),
        spec.p0_ids.clone(),
        spec.p1_ids.clone(),
        book,
    );
    let mut seats = [
        SeatState { seat: Seat { cpu: 0 }, state: StratState::new(spec.p0_strategy), last_own_move: Mv { move_index: 0, extra_data: 0 } },
        SeatState { seat: Seat { cpu: 1 }, state: StratState::new(spec.p1_strategy), last_own_move: Mv { move_index: 0, extra_data: 0 } },
    ];
    let obs = Seat { cpu: 1 };
    let mut samples: Vec<YomiSample> = Vec::new();

    for _t in 0..spec.max_turns {
        let winner = sim.winner_index();
        if winner != 2 {
            return samples;
        }
        let bk: B256 = sim.battle_key;
        let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag;
        let p0_acts = flag != 1;
        let p1_acts = flag != 0;

        // Yomi tension only exists where both sides genuinely choose (flag == 2).
        if flag == 2 {
            let (p0a, p1a) = active_mon_indices(&mut sim, obs, bk);
            let saved_fc = sim.fork_counter();
            for (si, seat_slot, mon_id) in [(1usize, p1a, spec.p1_ids[p1a]), (0usize, p0a, spec.p0_ids[p0a])] {
                let _ = seat_slot;
                let seat = seats[si].seat;
                let view = capture_view(&mut sim, seat, bk);
                let mut scratch = rng; // JsRng: Copy — leaves the live stream untouched
                let mut fc = ForkCache::new();
                let (_my, _opp, grid) = nopeek::action_grid(&mut sim, seat, &view, &mut scratch, &mut fc);
                fc.dispose_all(&mut sim);
                if let Some(e) = nopeek::yomi_tension(&grid) {
                    samples.push(YomiSample { mon_id, evpi: e, seat: si as u8 });
                }
            }
            sim.set_fork_counter(saved_fc);
        }

        let mut p0_move: Option<Mv> = None;
        if p0_acts {
            let peek = seats[1].last_own_move;
            let mv = decide_one(&mut sim, &mut seats[0], peek, &mut rng);
            seats[0].last_own_move = mv;
            p0_move = Some(mv);
        }
        let mut p1_move: Option<Mv> = None;
        if p1_acts {
            let peek = p0_move.unwrap_or(Mv { move_index: 0, extra_data: 0 });
            let mv = decide_one(&mut sim, &mut seats[1], peek, &mut rng);
            seats[1].last_own_move = mv;
            p1_move = Some(mv);
        }

        let p0_salt = if p0_move.is_some() { random_salt(&mut rng) } else { 0 };
        let p1_salt = if p1_move.is_some() { random_salt(&mut rng) } else { 0 };
        sim.execute_turn(
            p0_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p0_salt, p0_move.map(|m| m.extra_data).unwrap_or(0),
            p1_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p1_salt, p1_move.map(|m| m.extra_data).unwrap_or(0),
        );
    }
    samples
}

/// Threaded yomi batch (see `run_batch`).
pub fn run_games_yomi(
    specs: &[GameSpec],
    book: &HashMap<String, Address>,
    threads: usize,
) -> Vec<Result<Vec<YomiSample>, String>> {
    run_batch(specs, threads, |spec| play_game_yomi(spec, book))
}

// ── Breadth + close-call sampler: greedy's per-action scores at each decision (measure.md) ──
//
// Drives both seats with greedy and records greedy's fork score for every candidate at each
// decision: which move-lane was picked (dominance), how far each lane sat behind the best
// (dead-slot margin), and whether the top two were within noise while best-vs-worst was wide
// (a close call). Attributed to the deciding mon.

pub struct BreadthSample {
    pub mon_id: u32,
    pub chosen_move: i16,      // move_index of the pick (0..3 move, SWITCH_MOVE_INDEX, or NO_OP_INDEX)
    pub lane_scores: [f64; 4], // greedy score per move-lane candidate; NEG_INFINITY = not offered
    pub top1: f64,
    pub top2: f64,
    pub worst: f64,
}

fn summarize_scored(scored: &[(Mv, f64)]) -> ([f64; 4], f64, f64, f64) {
    let mut lane = [f64::NEG_INFINITY; 4];
    for (m, s) in scored {
        let l = m.move_index as usize;
        if l < 4 && *s > lane[l] {
            lane[l] = *s;
        }
    }
    let mut vals: Vec<f64> = scored.iter().map(|(_, s)| *s).collect();
    vals.sort_by(|a, b| b.partial_cmp(a).unwrap());
    let top1 = vals.first().copied().unwrap_or(f64::NAN);
    let top2 = vals.get(1).copied().unwrap_or(top1);
    let worst = vals.last().copied().unwrap_or(top1);
    (lane, top1, top2, worst)
}

pub fn play_game_breadth(spec: &GameSpec, book: &HashMap<String, Address>) -> Vec<BreadthSample> {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new(
        spec.mons_per_team, spec.p0_team.clone(), spec.p1_team.clone(),
        spec.p0_ids.clone(), spec.p1_ids.clone(), book,
    );
    let seat0 = Seat { cpu: 0 };
    let seat1 = Seat { cpu: 1 };
    let obs = Seat { cpu: 1 };
    let mut last1 = Mv { move_index: 0, extra_data: 0 }; // p1's previous move — the p0 seat's stale peek
    let mut samples: Vec<BreadthSample> = Vec::new();

    for _t in 0..spec.max_turns {
        if sim.winner_index() != 2 {
            return samples;
        }
        let bk: B256 = sim.battle_key;
        let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag;
        let p0_acts = flag != 1;
        let p1_acts = flag != 0;
        let (p0a, p1a) = active_mon_indices(&mut sim, obs, bk);

        let mut p0_move: Option<Mv> = None;
        if p0_acts {
            let view = capture_view(&mut sim, seat0, bk);
            let (chosen, scored) = greedy::decide_scored(&mut sim, seat0, &view, last1, &mut rng);
            if !scored.is_empty() {
                let (lane, t1, t2, w) = summarize_scored(&scored);
                samples.push(BreadthSample { mon_id: spec.p0_ids[p0a], chosen_move: chosen.move_index as i16, lane_scores: lane, top1: t1, top2: t2, worst: w });
            }
            p0_move = Some(chosen);
        }
        let mut p1_move: Option<Mv> = None;
        if p1_acts {
            let peek = p0_move.unwrap_or(Mv { move_index: 0, extra_data: 0 });
            let view = capture_view(&mut sim, seat1, bk);
            let (chosen, scored) = greedy::decide_scored(&mut sim, seat1, &view, peek, &mut rng);
            if !scored.is_empty() {
                let (lane, t1, t2, w) = summarize_scored(&scored);
                samples.push(BreadthSample { mon_id: spec.p1_ids[p1a], chosen_move: chosen.move_index as i16, lane_scores: lane, top1: t1, top2: t2, worst: w });
            }
            last1 = chosen;
            p1_move = Some(chosen);
        }

        let p0_salt = if p0_move.is_some() { random_salt(&mut rng) } else { 0 };
        let p1_salt = if p1_move.is_some() { random_salt(&mut rng) } else { 0 };
        sim.execute_turn(
            p0_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p0_salt, p0_move.map(|m| m.extra_data).unwrap_or(0),
            p1_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p1_salt, p1_move.map(|m| m.extra_data).unwrap_or(0),
        );
    }
    samples
}

/// Threaded breadth batch (see `run_batch`).
pub fn run_games_breadth(
    specs: &[GameSpec],
    book: &HashMap<String, Address>,
    threads: usize,
) -> Vec<Result<Vec<BreadthSample>, String>> {
    run_batch(specs, threads, |spec| play_game_breadth(spec, book))
}

// ── Instrumented runner: per-mon KO attribution + active-turns (measure.md) ──
//
// Rides the exact seat/peek/salt RNG discipline of `play_game` so an instrumented
// batch draws the same games as the plain arena. Each turn we credit the fighters
// (active-turn count) and diff the ko-bitmap across `execute_turn`, attributing
// every fresh KO to the opponent's active mon that turn — the "which mon held the
// opposing active slot at the moment of KO" proxy [ruled 2026-07-08].

/// One attributed knockout.
#[derive(Clone, Copy, Debug)]
pub struct KoEvent {
    pub turn: u32,
    pub killer_seat: u8, // physical seat of the KOing mon (0 or 1)
    pub killer_id: u32,  // global mon-id that landed the KO (opponent-active proxy)
    pub victim_id: u32,  // global mon-id that was KOed
}

/// Per-game per-mon attribution, folded by `analysis`.
pub struct InstrRecord {
    pub winner_seat: Option<u8>, // 0 / 1, None = turn-cap draw
    pub turns: u32,
    pub p0_ids: Vec<u32>,
    pub p1_ids: Vec<u32>,
    /// Active-turn count per team slot (parallel to p0_ids / p1_ids).
    pub active_turns_p0: Vec<u32>,
    pub active_turns_p1: Vec<u32>,
    pub kos: Vec<KoEvent>,
}

pub fn play_game_instrumented(spec: &GameSpec, book: &HashMap<String, Address>) -> InstrRecord {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new(
        spec.mons_per_team,
        spec.p0_team.clone(),
        spec.p1_team.clone(),
        spec.p0_ids.clone(),
        spec.p1_ids.clone(),
        book,
    );

    let mut seats = [
        SeatState {
            seat: Seat { cpu: 0 },
            state: StratState::new(spec.p0_strategy),
            last_own_move: Mv { move_index: 0, extra_data: 0 },
        },
        SeatState {
            seat: Seat { cpu: 1 },
            state: StratState::new(spec.p1_strategy),
            last_own_move: Mv { move_index: 0, extra_data: 0 },
        },
    ];

    // Non-flipped observer: active_mon_indices → (p0_active, p1_active);
    // ko_bitmap(VOPP) = physical p0, ko_bitmap(VCPU) = physical p1.
    let obs = Seat { cpu: 1 };
    let mut active_turns_p0 = vec![0u32; spec.p0_ids.len()];
    let mut active_turns_p1 = vec![0u32; spec.p1_ids.len()];
    let mut kos: Vec<KoEvent> = Vec::new();

    for t in 0..spec.max_turns {
        let winner = sim.winner_index();
        if winner != 2 {
            return InstrRecord {
                winner_seat: Some(winner), turns: t,
                p0_ids: spec.p0_ids.clone(), p1_ids: spec.p1_ids.clone(),
                active_turns_p0, active_turns_p1, kos,
            };
        }

        let bk: B256 = sim.battle_key;
        let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag;
        let p0_acts = flag != 1;
        let p1_acts = flag != 0;

        let mut p0_move: Option<Mv> = None;
        if p0_acts {
            let peek = seats[1].last_own_move;
            let mv = decide_one(&mut sim, &mut seats[0], peek, &mut rng);
            seats[0].last_own_move = mv;
            p0_move = Some(mv);
        }
        let mut p1_move: Option<Mv> = None;
        if p1_acts {
            let peek = p0_move.unwrap_or(Mv { move_index: 0, extra_data: 0 });
            let mv = decide_one(&mut sim, &mut seats[1], peek, &mut rng);
            seats[1].last_own_move = mv;
            p1_move = Some(mv);
        }

        // Fighters this turn (active-turn credit) + KO bitmap before execute.
        let (p0a, p1a) = active_mon_indices(&mut sim, obs, bk);
        if let Some(c) = active_turns_p0.get_mut(p0a) { *c += 1; }
        if let Some(c) = active_turns_p1.get_mut(p1a) { *c += 1; }
        let ko_before_p0 = ko_bitmap(&mut sim, obs, bk, VOPP);
        let ko_before_p1 = ko_bitmap(&mut sim, obs, bk, VCPU);

        let p0_salt = if p0_move.is_some() { random_salt(&mut rng) } else { 0 };
        let p1_salt = if p1_move.is_some() { random_salt(&mut rng) } else { 0 };
        sim.execute_turn(
            p0_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX),
            p0_salt,
            p0_move.map(|m| m.extra_data).unwrap_or(0),
            p1_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX),
            p1_salt,
            p1_move.map(|m| m.extra_data).unwrap_or(0),
        );

        // Fresh KOs this turn → attribute to the opposing active mon.
        let bk2: B256 = sim.battle_key;
        let new_p0 = ko_bitmap(&mut sim, obs, bk2, VOPP) & !ko_before_p0;
        let new_p1 = ko_bitmap(&mut sim, obs, bk2, VCPU) & !ko_before_p1;
        if new_p0 != 0 {
            if let Some(&killer_id) = spec.p1_ids.get(p1a) {
                for slot in 0..spec.p0_ids.len() {
                    if new_p0 & (1u32 << slot) != 0 {
                        kos.push(KoEvent { turn: t, killer_seat: 1, killer_id, victim_id: spec.p0_ids[slot] });
                    }
                }
            }
        }
        if new_p1 != 0 {
            if let Some(&killer_id) = spec.p0_ids.get(p0a) {
                for slot in 0..spec.p1_ids.len() {
                    if new_p1 & (1u32 << slot) != 0 {
                        kos.push(KoEvent { turn: t, killer_seat: 0, killer_id, victim_id: spec.p1_ids[slot] });
                    }
                }
            }
        }
    }

    let fw = sim.winner_index();
    InstrRecord {
        winner_seat: if fw != 2 { Some(fw) } else { None },
        turns: spec.max_turns,
        p0_ids: spec.p0_ids.clone(), p1_ids: spec.p1_ids.clone(),
        active_turns_p0, active_turns_p1, kos,
    }
}

/// Threaded instrumented batch (see `run_batch`).
pub fn run_games_instrumented(
    specs: &[GameSpec],
    book: &HashMap<String, Address>,
    threads: usize,
) -> Vec<Result<InstrRecord, String>> {
    run_batch(specs, threads, |spec| play_game_instrumented(spec, book))
}

// ── Mock loop (mock2 T2): repack a mock move's word from live state each turn, then instrument ──
//
// Identical to `play_game_instrumented` except that, before the pilots decide, it recomputes the
// mock move's inline word from live state (crate::mock2::repack_turn) — so the conditional-power
// logic lives in Rust and the engine just runs a standard inline attack.

pub fn play_game_mock(
    spec: &GameSpec,
    book: &HashMap<String, Address>,
    target_id: u32,
    lane: usize,
    mock: &crate::mock2::MockMove,
) -> InstrRecord {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new(
        spec.mons_per_team, spec.p0_team.clone(), spec.p1_team.clone(),
        spec.p0_ids.clone(), spec.p1_ids.clone(), book,
    );
    let mut seats = [
        SeatState { seat: Seat { cpu: 0 }, state: StratState::new(spec.p0_strategy), last_own_move: Mv { move_index: 0, extra_data: 0 } },
        SeatState { seat: Seat { cpu: 1 }, state: StratState::new(spec.p1_strategy), last_own_move: Mv { move_index: 0, extra_data: 0 } },
    ];
    let obs = Seat { cpu: 1 };
    let mut active_turns_p0 = vec![0u32; spec.p0_ids.len()];
    let mut active_turns_p1 = vec![0u32; spec.p1_ids.len()];
    let mut kos: Vec<KoEvent> = Vec::new();
    let mut last_dmg = [0i32; 2]; // HP the mock mon lost last turn (for the counter power rule)
    let mut adapted: [Option<chomp_engine::Enums::Type>; 2] = [None, None]; // the mock mon's Adapted type per side

    for t in 0..spec.max_turns {
        let winner = sim.winner_index();
        if winner != 2 {
            return InstrRecord { winner_seat: Some(winner), turns: t, p0_ids: spec.p0_ids.clone(), p1_ids: spec.p1_ids.clone(), active_turns_p0, active_turns_p1, kos };
        }
        let bk: B256 = sim.battle_key;

        // T2: recompute the mock move's word from live state before the pilots decide.
        crate::mock2::repack_turn(&mut sim, bk, spec, target_id, lane, mock, &last_dmg);

        let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag;
        let p0_acts = flag != 1;
        let p1_acts = flag != 0;

        let mut p0_move: Option<Mv> = None;
        if p0_acts {
            let peek = seats[1].last_own_move;
            let mv = decide_one(&mut sim, &mut seats[0], peek, &mut rng);
            seats[0].last_own_move = mv;
            p0_move = Some(mv);
        }
        let mut p1_move: Option<Mv> = None;
        if p1_acts {
            let peek = p0_move.unwrap_or(Mv { move_index: 0, extra_data: 0 });
            let mv = decide_one(&mut sim, &mut seats[1], peek, &mut rng);
            seats[1].last_own_move = mv;
            p1_move = Some(mv);
        }

        let (p0a, p1a) = active_mon_indices(&mut sim, obs, bk);
        if let Some(c) = active_turns_p0.get_mut(p0a) { *c += 1; }
        if let Some(c) = active_turns_p1.get_mut(p1a) { *c += 1; }
        let ko_before_p0 = ko_bitmap(&mut sim, obs, bk, VOPP);
        let ko_before_p1 = ko_bitmap(&mut sim, obs, bk, VCPU);
        // T2: opp-action mocks get their power set now, from the opponent's chosen move.
        crate::mock2::repack_postdecide(&mut sim, bk, spec, target_id, lane, mock, p0_move, p1_move, &adapted);
        // Mock mon's HP before the turn (sentinel = not the active mon this turn), for the counter rule.
        let mhp0_before = if spec.p0_ids.get(p0a) == Some(&target_id) { mon_current_hp(&mut sim, obs, bk, VOPP, p0a) } else { i64::MIN };
        let mhp1_before = if spec.p1_ids.get(p1a) == Some(&target_id) { mon_current_hp(&mut sim, obs, bk, VCPU, p1a) } else { i64::MIN };

        let p0_salt = if p0_move.is_some() { random_salt(&mut rng) } else { 0 };
        let p1_salt = if p1_move.is_some() { random_salt(&mut rng) } else { 0 };
        sim.execute_turn(
            p0_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p0_salt, p0_move.map(|m| m.extra_data).unwrap_or(0),
            p1_move.map(|m| m.move_index).unwrap_or(NO_OP_INDEX), p1_salt, p1_move.map(|m| m.extra_data).unwrap_or(0),
        );

        let bk2: B256 = sim.battle_key;
        if mhp0_before != i64::MIN { last_dmg[0] = (mhp0_before - mon_current_hp(&mut sim, obs, bk2, VOPP, p0a)).max(0) as i32; }
        if mhp1_before != i64::MIN { last_dmg[1] = (mhp1_before - mon_current_hp(&mut sim, obs, bk2, VCPU, p1a)).max(0) as i32; }
        // Adaptor: record the mock mon's adapted type the first time it takes damage.
        if last_dmg[0] > 0 && adapted[0].is_none() { adapted[0] = p1_move.and_then(|m| crate::mock2::move_type_of(&mut sim, bk2, obs, VCPU, p1a, m.move_index)); }
        if last_dmg[1] > 0 && adapted[1].is_none() { adapted[1] = p0_move.and_then(|m| crate::mock2::move_type_of(&mut sim, bk2, obs, VOPP, p0a, m.move_index)); }
        // Write-mutator post-effect: if the mock mon used the mock lane this turn, apply its heal rider.
        if let crate::mock2::MockPost::HealPctMaxHp(pct) = mock.post {
            if spec.p0_ids.get(p0a) == Some(&target_id) && p0_move.map(|m| m.move_index as usize) == Some(lane) {
                let max = mon_max_hp(&mut sim, obs, bk2, VOPP, p0a);
                crate::mock2::heal_mon(&mut sim, bk2, 0, p0a, (max * pct as i64 / 100) as i32);
            }
            if spec.p1_ids.get(p1a) == Some(&target_id) && p1_move.map(|m| m.move_index as usize) == Some(lane) {
                let max = mon_max_hp(&mut sim, obs, bk2, VCPU, p1a);
                crate::mock2::heal_mon(&mut sim, bk2, 1, p1a, (max * pct as i64 / 100) as i32);
            }
        }
        let new_p0 = ko_bitmap(&mut sim, obs, bk2, VOPP) & !ko_before_p0;
        let new_p1 = ko_bitmap(&mut sim, obs, bk2, VCPU) & !ko_before_p1;
        if new_p0 != 0 {
            if let Some(&killer_id) = spec.p1_ids.get(p1a) {
                for slot in 0..spec.p0_ids.len() {
                    if new_p0 & (1u32 << slot) != 0 { kos.push(KoEvent { turn: t, killer_seat: 1, killer_id, victim_id: spec.p0_ids[slot] }); }
                }
            }
        }
        if new_p1 != 0 {
            if let Some(&killer_id) = spec.p0_ids.get(p0a) {
                for slot in 0..spec.p1_ids.len() {
                    if new_p1 & (1u32 << slot) != 0 { kos.push(KoEvent { turn: t, killer_seat: 0, killer_id, victim_id: spec.p1_ids[slot] }); }
                }
            }
        }
    }

    let fw = sim.winner_index();
    InstrRecord { winner_seat: if fw != 2 { Some(fw) } else { None }, turns: spec.max_turns, p0_ids: spec.p0_ids.clone(), p1_ids: spec.p1_ids.clone(), active_turns_p0, active_turns_p1, kos }
}

/// Threaded mock batch (see `run_batch`); the mock's word is repacked each turn in play_game_mock.
pub fn run_games_mock(
    specs: &[GameSpec],
    book: &HashMap<String, Address>,
    threads: usize,
    target_id: u32,
    lane: usize,
    mock: &crate::mock2::MockMove,
) -> Vec<Result<InstrRecord, String>> {
    run_batch(specs, threads, |spec| play_game_mock(spec, book, target_id, lane, mock))
}
