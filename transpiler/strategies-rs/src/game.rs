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
use crate::sim::Sim;
use crate::view::{capture_view, Mv, Seat, NO_OP_INDEX};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StrategyKind {
    Hard,
    Greedy,
}

impl StrategyKind {
    pub fn parse(name: &str) -> Option<StrategyKind> {
        match name {
            "hard" => Some(StrategyKind::Hard),
            "greedy" => Some(StrategyKind::Greedy),
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
    /// Per-turn submissions when tracing (the lockstep gate's compare key).
    pub trace: Vec<TurnTrace>,
}

struct SeatState {
    kind: StrategyKind,
    seat: Seat,
    hard: HardState,
    last_own_move: Mv,
}

fn decide_one(sim: &mut Sim, s: &mut SeatState, pm: Mv, rng: &mut JsRng) -> Mv {
    let view = capture_view(sim, s.seat, sim.battle_key);
    match s.kind {
        StrategyKind::Hard => hard::decide(sim, s.seat, &view, pm, rng, &mut s.hard),
        StrategyKind::Greedy => greedy::decide(sim, s.seat, &view, pm, rng),
    }
}

pub fn play_game(spec: &GameSpec, book: &HashMap<String, Address>, trace: bool) -> GameOutcome {
    let mut rng = JsRng::new(spec.seed);
    let mut sim = Sim::new(
        spec.mons_per_team,
        spec.p0_team.clone(),
        spec.p1_team.clone(),
        book,
        Address::ZERO, // inline keccak(p0Salt, p1Salt) rng — the arena path
    );

    let mut seats = [
        SeatState {
            kind: spec.p0_strategy,
            seat: Seat { cpu: 0 },
            hard: HardState::default(),
            last_own_move: Mv { move_index: 0, extra_data: 0 },
        },
        SeatState {
            kind: spec.p1_strategy,
            seat: Seat { cpu: 1 },
            hard: HardState::default(),
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
            let (s0, _) = seats.split_at_mut(1);
            let mv = decide_one(&mut sim, &mut s0[0], peek, &mut rng);
            s0[0].last_own_move = mv;
            p0_move = Some(mv);
        }
        // p1 seat replies with the true reveal (production semantics).
        let mut p1_move: Option<Mv> = None;
        if p1_acts {
            let peek = p0_move.unwrap_or(Mv { move_index: 0, extra_data: 0 });
            let (_, s1) = seats.split_at_mut(1);
            let mv = decide_one(&mut sim, &mut s1[0], peek, &mut rng);
            s1[0].last_own_move = mv;
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

pub struct GameResult {
    pub idx: usize,
    pub outcome: Result<GameOutcome, String>,
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
/// back in spec order.
pub fn run_games(
    specs: &[GameSpec],
    book: &HashMap<String, Address>,
    threads: usize,
    trace: bool,
) -> Vec<GameResult> {
    if threads <= 1 || specs.len() <= 1 {
        return specs
            .iter()
            .enumerate()
            .map(|(idx, spec)| GameResult { idx, outcome: run_one(spec, book, trace) })
            .collect();
    }

    let n = threads.min(specs.len());
    let mut slots: Vec<Option<GameResult>> = Vec::with_capacity(specs.len());
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
                let r = GameResult { idx, outcome: run_one(&specs[idx], book, trace) };
                slots.lock().unwrap()[idx] = Some(r);
            });
        }
    });

    slots.into_inner().unwrap().into_iter().map(|r| r.expect("slot filled")).collect()
}
