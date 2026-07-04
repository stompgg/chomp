//! Battle-replay lockstep gate (Phase 2): replays scripted damage-only
//! battles recorded from the TS oracle (scripts/generate_battle_vectors.ts)
//! through the generated Rust World and diffs every state field per turn.
//!
//! Scope mirrors the TS sim harness: inline packed moves (no IMoveSet
//! dispatch), no effects, no abilities, inline stamina-regen ruleset, zero
//! validator, ITeamRegistry mocked through World::ext.

#![allow(non_snake_case)]

use std::collections::HashMap;

use serde::Deserialize;

use chomp_engine::world::{deploy_all, ExternalCalls, World};
use chomp_engine::Structs::{Battle, Mon, MonStats};
use chomp_engine::Enums::Type;
use chomp_engine::{Constants, Engine};
use chomp_rt::{Address, B256, U256};

// Address book — mirrors sims/src/harness.ts. Only INLINE_STAMINA_REGEN_RULESET
// is semantic (engine compares it against a Constants sentinel); the rest just
// have to be internally consistent (matchmaker approval, moveManager check).
const P0: Address = addr(0x01);
const P1: Address = addr(0x02);
const MATCHMAKER: Address = addr(0xcafe);
const MOVE_MANAGER: Address = addr(0xbeef);
const TEAM_REGISTRY: Address = addr(0xa55e);
const RNG_ORACLE: Address = addr(0x99); // calls alias to DefaultRandomnessOracle
const ENGINE_ADDR: Address = addr(0xe7);

const fn addr(low: u16) -> Address {
    let mut b = [0u8; 20];
    b[18] = (low >> 8) as u8;
    b[19] = (low & 0xff) as u8;
    Address::new(b)
}

// ---------------------------------------------------------------------------
// Fixture shapes
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct Fixture {
    scenarios: Vec<Scenario>,
}

#[derive(Deserialize)]
struct Scenario {
    name: String,
    monsPerTeam: u64,
    p0Team: Vec<FixtureMon>,
    p1Team: Vec<FixtureMon>,
    battleKey: String,
    #[serde(default)]
    addressBook: HashMap<String, String>,
    turns: Vec<Turn>,
}

#[derive(Deserialize)]
struct FixtureMon {
    hp: u32,
    stamina: u32,
    speed: u32,
    attack: u32,
    defense: u32,
    specialAttack: u32,
    specialDefense: u32,
    type1: u8,
    type2: u8,
    moves: Vec<String>,
    ability: String,
}

#[derive(Deserialize)]
struct Turn {
    p0MoveIndex: u8,
    p1MoveIndex: u8,
    p0Salt: String,
    p1Salt: String,
    p0ExtraData: u16,
    p1ExtraData: u16,
    expect: Expect,
}

#[derive(Deserialize)]
struct Expect {
    turnId: String,
    winnerIndex: u8,
    p0Active: usize,
    p1Active: usize,
    p0States: Vec<ExpectMonState>,
    p1States: Vec<ExpectMonState>,
}

#[derive(Deserialize)]
struct ExpectMonState {
    hpDelta: i32,
    staminaDelta: i32,
    isKnockedOut: bool,
}

fn hex_u256(s: &str) -> U256 {
    let t = s.strip_prefix("0x").unwrap_or(s);
    U256::from_str_radix(t, 16).expect("bad hex u256 in fixture")
}

fn hex_address(s: &str) -> Address {
    let t = s.strip_prefix("0x").unwrap_or(s);
    let padded = format!("{:0>40}", t);
    let raw: Vec<u8> = (0..40)
        .step_by(2)
        .map(|i| u8::from_str_radix(&padded[i..i + 2], 16).expect("bad hex byte"))
        .collect();
    Address::from_slice(&raw)
}

fn hex_b256(s: &str) -> B256 {
    let t = s.strip_prefix("0x").unwrap_or(s);
    let mut b = [0u8; 32];
    let raw = (0..t.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&t[i..i + 2], 16).expect("bad hex byte"))
        .collect::<Vec<u8>>();
    b[32 - raw.len()..].copy_from_slice(&raw);
    B256::new(b)
}

fn to_mon(m: &FixtureMon) -> Mon {
    Mon {
        stats: MonStats {
            hp: m.hp,
            stamina: m.stamina,
            speed: m.speed,
            attack: m.attack,
            defense: m.defense,
            specialAttack: m.specialAttack,
            specialDefense: m.specialDefense,
            type1: Type::from_u8(m.type1),
            type2: Type::from_u8(m.type2),
        },
        ability: hex_u256(&m.ability),
        moves: m.moves.iter().map(|w| hex_u256(w)).collect(),
    }
}

// ---------------------------------------------------------------------------
// Harness ExternalCalls: the team registry mock; anything else is a bug.
// ---------------------------------------------------------------------------

struct HarnessExt {
    p0_team: Vec<Mon>,
    p1_team: Vec<Mon>,
}

impl ExternalCalls for HarnessExt {
    fn ITeamRegistry_getTeams(
        &mut self,
        _target: Address,
        _p0: Address,
        _p0TeamIndex: U256,
        _p1: Address,
        _p1TeamIndex: U256,
    ) -> (Vec<Mon>, Vec<Mon>) {
        (self.p0_team.clone(), self.p1_team.clone())
    }

    fn ITeamRegistry_getExpAndLevelsForTeams(
        &mut self,
        _target: Address,
        _p0: Address,
        _p0TeamIndex: U256,
        _p1: Address,
        _p1TeamIndex: U256,
    ) -> (Vec<U256>, Vec<U256>, Vec<U256>, Vec<U256>, Vec<U256>, Vec<U256>) {
        // Only reachable from the getBattle view — never on the replay path.
        panic!("getExpAndLevelsForTeams called during battle replay");
    }
}

// ---------------------------------------------------------------------------
// Replay
// ---------------------------------------------------------------------------

fn norm(v: i32) -> i32 {
    if v == Constants::CLEARED_MON_STATE_SENTINEL { 0 } else { v }
}

fn replay_scenario(sc: &Scenario) {
    let ext = HarnessExt {
        p0_team: sc.p0Team.iter().map(to_mon).collect(),
        p1_team: sc.p1Team.iter().map(to_mon).collect(),
    };
    let mut world = World::new(Box::new(ext));
    world.Engine = Engine::construct(
        U256::from(sc.monsPerTeam),
        Constants::GAME_MOVES_PER_MON,
    );

    // TS-exported address book: register every contract's ContractId and
    // construct dispatchable states with identical dep wiring.
    let book: HashMap<String, Address> = sc
        .addressBook
        .iter()
        .map(|(k, v)| (k.clone(), hex_address(v)))
        .collect();
    let engine_addr = book.get("Engine").copied().unwrap_or(ENGINE_ADDR);
    let rng_oracle = book
        .get("DefaultRandomnessOracle")
        .copied()
        .unwrap_or(RNG_ORACLE);
    if !book.is_empty() {
        let sc_name = sc.name.clone();
        let addr_of = move |name: &str| -> Address {
            *book.get(name).unwrap_or_else(|| {
                panic!("[{sc_name}] address book missing contract `{name}`")
            })
        };
        deploy_all(&mut world, &addr_of);
    }

    world.env.current_contract = engine_addr;
    world.env.block_timestamp = U256::from(1_800_000_000u64);
    world.env.block_number = U256::from(1u64);

    // TS harness __mutateIsMatchmakerFor equivalent.
    world.Engine.isMatchmakerFor.get_mut(&P0).set(MATCHMAKER, true);
    world.Engine.isMatchmakerFor.get_mut(&P1).set(MATCHMAKER, true);

    let (battle_key, _pair_hash) = Engine::computeBattleKey(&mut world, P0, P1);
    assert_eq!(
        battle_key,
        hex_b256(&sc.battleKey),
        "[{}] battleKey mismatch",
        sc.name
    );

    let mut battle = Battle {
        p0: P0,
        p0TeamIndex: 0,
        p1: P1,
        p1TeamIndex: 0,
        teamRegistry: TEAM_REGISTRY,
        validator: Address::ZERO, // inline validator path
        rngOracle: rng_oracle,
        ruleset: Constants::INLINE_STAMINA_REGEN_RULESET,
        moveManager: MOVE_MANAGER,
        matchmaker: MATCHMAKER,
        engineHooks: Vec::new(),
    };
    world.env.msg_sender = MATCHMAKER;
    Engine::startBattle(&mut world, &mut battle);

    for (ti, turn) in sc.turns.iter().enumerate() {
        // Transaction boundary (EIP-1153 transient auto-clear), then the tx.
        world.reset_transient();
        world.env.block_timestamp = world.env.block_timestamp + U256::from(1u64);
        world.env.msg_sender = MOVE_MANAGER;
        Engine::executeWithMoves(
            &mut world,
            battle_key,
            turn.p0MoveIndex,
            turn.p0Salt.parse::<u128>().expect("bad p0Salt"),
            turn.p0ExtraData,
            turn.p1MoveIndex,
            turn.p1Salt.parse::<u128>().expect("bad p1Salt"),
            turn.p1ExtraData,
        );

        // Snapshot — mirrors sims/src/harness.ts executeTurn.
        let storage_key = Engine::_getStorageKey(&mut world, battle_key);
        let data = world.Engine.battleData.get(&battle_key);
        let team_sizes = world.Engine.battleConfig.get_mut(&storage_key).teamSizes;
        let p0_size = (team_sizes & 0x0f) as usize;
        let p1_size = (team_sizes >> 4) as usize;

        let ctx = |field: &str| format!("[{} turn {}] {}", sc.name, ti, field);
        let e = &turn.expect;
        assert_eq!(u64::from(data.turnId), e.turnId.parse::<u64>().unwrap(), "{}", ctx("turnId"));
        assert_eq!(data.winnerIndex, e.winnerIndex, "{}", ctx("winnerIndex"));
        let p0_active = Engine::_unpackActiveMonIndex(data.activeMonIndex, U256::ZERO);
        let p1_active = Engine::_unpackActiveMonIndex(data.activeMonIndex, U256::from(1u64));
        assert_eq!(usize::try_from(p0_active).unwrap(), e.p0Active, "{}", ctx("p0Active"));
        assert_eq!(usize::try_from(p1_active).unwrap(), e.p1Active, "{}", ctx("p1Active"));
        assert_eq!(p0_size, e.p0States.len(), "{}", ctx("p0 team size"));
        assert_eq!(p1_size, e.p1States.len(), "{}", ctx("p1 team size"));

        for i in 0..p0_size {
            let s = world
                .Engine
                .battleConfig
                .get_mut(&storage_key)
                .p0States
                .get(&U256::from(i as u64));
            let exp = &e.p0States[i];
            assert_eq!(norm(s.hpDelta), exp.hpDelta, "{}", ctx(&format!("p0States[{i}].hpDelta")));
            assert_eq!(norm(s.staminaDelta), exp.staminaDelta, "{}", ctx(&format!("p0States[{i}].staminaDelta")));
            assert_eq!(s.isKnockedOut, exp.isKnockedOut, "{}", ctx(&format!("p0States[{i}].isKnockedOut")));
        }
        for i in 0..p1_size {
            let s = world
                .Engine
                .battleConfig
                .get_mut(&storage_key)
                .p1States
                .get(&U256::from(i as u64));
            let exp = &e.p1States[i];
            assert_eq!(norm(s.hpDelta), exp.hpDelta, "{}", ctx(&format!("p1States[{i}].hpDelta")));
            assert_eq!(norm(s.staminaDelta), exp.staminaDelta, "{}", ctx(&format!("p1States[{i}].staminaDelta")));
            assert_eq!(s.isKnockedOut, exp.isKnockedOut, "{}", ctx(&format!("p1States[{i}].isKnockedOut")));
        }
    }
}

#[test]
fn battle_replay_lockstep() {
    let raw = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/fixtures/battle_replay.json"
    ))
    .expect("battle_replay.json missing — run bun transpiler/scripts/generate_battle_vectors.ts");
    let fixture: Fixture = serde_json::from_str(&raw).expect("bad fixture JSON");
    assert!(!fixture.scenarios.is_empty(), "no scenarios");
    let mut total_turns = 0usize;
    for sc in &fixture.scenarios {
        assert!(!sc.turns.is_empty(), "{}: no turns", sc.name);
        replay_scenario(sc);
        total_turns += sc.turns.len();
    }
    println!("battle replay: {} scenarios, {} turns bit-identical", fixture.scenarios.len(), total_turns);
}
