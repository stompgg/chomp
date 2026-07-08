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

use crate::greedy;
use crate::hard::{self, HardState};
use crate::jsrng::{random_salt, JsRng};
use crate::override_cpu::{self, OverrideState};
use crate::sim::Sim;
use crate::view::{
    active_mon_indices, capture_view, mon_current_hp, mon_max_hp, Mv, Seat, NO_OP_INDEX,
    SWITCH_MOVE_INDEX, VCPU, VOPP,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StrategyKind {
    Hard,
    Greedy,
    Override,
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
            _ => None,
        }
    }
}

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
}

impl StratState {
    fn new(kind: StrategyKind) -> StratState {
        match kind {
            StrategyKind::Hard => StratState::Hard(HardState::default()),
            StrategyKind::Greedy => StratState::Greedy,
            StrategyKind::Override => StratState::Override(OverrideState::default()),
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

fn run_one(spec: &GameSpec, book: &HashMap<String, Address>, trace: bool) -> Result<GameOutcome, String> {
    catch_unwind(AssertUnwindSafe(|| play_game(spec, book, trace))).map_err(|e| {
        e.downcast_ref::<String>()
            .cloned()
            .or_else(|| e.downcast_ref::<&str>().map(|s| s.to_string()))
            .unwrap_or_else(|| "panic".to_string())
    })
}

/// Run a batch of independent games, optionally across threads (each game
/// owns its whole world, so parallelism is trivially safe). Results come
/// back in spec order; a panicking game yields Err instead of poisoning
/// the batch.
pub fn run_games(
    specs: &[GameSpec],
    book: &HashMap<String, Address>,
    threads: usize,
    trace: bool,
) -> Vec<Result<GameOutcome, String>> {
    if threads <= 1 || specs.len() <= 1 {
        return specs.iter().map(|spec| run_one(spec, book, trace)).collect();
    }

    let n = threads.min(specs.len());
    let mut slots: Vec<Option<Result<GameOutcome, String>>> = Vec::with_capacity(specs.len());
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
                let r = run_one(&specs[idx], book, trace);
                slots.lock().unwrap()[idx] = Some(r);
            });
        }
    });

    slots.into_inner().unwrap().into_iter().map(|r| r.expect("slot filled")).collect()
}
