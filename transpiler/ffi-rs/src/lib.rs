//! chomp-ffi — cdylib surface for bun:ffi (Phase 5: arena drive).
//!
//! Handle-based battle API with a JSON boundary: the engine executes
//! native (no bigint), one FFI crossing per call. Strings returned by
//! `chomp_battle_*` are heap CStrings — release them with
//! `chomp_str_free`.
//!
//!   chomp_battle_new(cfg_json)   -> handle (0 = error; see cfg below)
//!   chomp_battle_validate(h, seat, moveIndex, extraData) -> 1/0
//!   chomp_battle_turn(h, input_json) -> snapshot json (null on error)
//!   chomp_battle_free(h)
//!
//! cfg JSON: { monsPerTeam, p0Team: [Mon], p1Team: [Mon],
//!             addressBook?: {name: "0x.."} }
//! Mon JSON mirrors the lockstep fixture: stats fields + type1/type2 (u8)
//! + moves (hex u256 words: inline-packed or contract addresses from the
//! book) + ability (hex).
//! turn JSON: { p0MoveIndex, p1MoveIndex, p0Salt, p1Salt,
//!              p0ExtraData, p1ExtraData } (salts are decimal strings).

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

use serde::Deserialize;
use serde_json::json;

use chomp_engine::world::{deploy_all, ExternalCalls, World};
use chomp_engine::Enums::Type;
use chomp_engine::Structs::{Battle, Mon, MonStats};
use chomp_engine::{Constants, Engine};
use chomp_rt::{Address, B256, U256};

/// ABI/version probe: returns (major << 16 | minor). bun:ffi smoke tests
/// call this to prove symbol resolution + calling convention.
#[no_mangle]
pub extern "C" fn chomp_ffi_version() -> u32 {
    (0u32 << 16) | 2u32
}

/// Cheap end-to-end proof that the emitted engine code is linked in and
/// executes across the FFI boundary: type effectiveness lookup.
#[no_mangle]
pub extern "C" fn chomp_type_effectiveness(attacker: u8, defender: u8, base_power: u32) -> u32 {
    chomp_engine::types::TypeCalcLib::getTypeEffectiveness(
        Type::from_u8(attacker),
        Type::from_u8(defender),
        base_power,
    )
}

// ---------------------------------------------------------------------------
// Battle sessions
// ---------------------------------------------------------------------------

const P0: Address = addr(0x01);
const P1: Address = addr(0x02);
const MATCHMAKER: Address = addr(0xcafe);
const MOVE_MANAGER: Address = addr(0xbeef);
const TEAM_REGISTRY: Address = addr(0xa55e);
const ENGINE_ADDR: Address = addr(0xe7);

const fn addr(low: u16) -> Address {
    let mut b = [0u8; 20];
    b[18] = (low >> 8) as u8;
    b[19] = (low & 0xff) as u8;
    Address::new(b)
}

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct MonJson {
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
#[allow(non_snake_case)]
struct BattleCfg {
    monsPerTeam: u64,
    p0Team: Vec<MonJson>,
    p1Team: Vec<MonJson>,
    #[serde(default)]
    addressBook: HashMap<String, String>,
    /// Oracle address for BattleConfig. DEFAULT: zero — the engine's
    /// inline keccak(p0Salt, p1Salt) path, no oracle dispatch (the arena
    /// path; the TS memoized-oracle shim has no Rust counterpart on
    /// purpose). Set explicitly only to mirror a recorded TS fixture.
    #[serde(default)]
    rngOracle: Option<String>,
}

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct TurnInput {
    p0MoveIndex: u8,
    p1MoveIndex: u8,
    p0Salt: String,
    p1Salt: String,
    #[serde(default)]
    p0ExtraData: u16,
    #[serde(default)]
    p1ExtraData: u16,
}

struct HarnessExt {
    p0_team: Vec<Mon>,
    p1_team: Vec<Mon>,
}

impl ExternalCalls for HarnessExt {
    fn ITeamRegistry_getTeams(
        &mut self,
        _t: Address,
        _p0: Address,
        _i0: U256,
        _p1: Address,
        _i1: U256,
    ) -> (Vec<Mon>, Vec<Mon>) {
        (self.p0_team.clone(), self.p1_team.clone())
    }

    fn ITeamRegistry_getExpAndLevelsForTeams(
        &mut self,
        _t: Address,
        _p0: Address,
        _i0: U256,
        _p1: Address,
        _i1: U256,
    ) -> (Vec<U256>, Vec<U256>, Vec<U256>, Vec<U256>, Vec<U256>, Vec<U256>) {
        panic!("getExpAndLevelsForTeams not on the battle path");
    }
}

struct Session {
    world: World,
    battle_key: B256,
}

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

fn registry() -> &'static Mutex<HashMap<u64, Session>> {
    static REG: std::sync::OnceLock<Mutex<HashMap<u64, Session>>> = std::sync::OnceLock::new();
    REG.get_or_init(|| Mutex::new(HashMap::new()))
}

fn hex_u256(s: &str) -> Option<U256> {
    let t = s.strip_prefix("0x").unwrap_or(s);
    U256::from_str_radix(t, 16).ok()
}

fn hex_address(s: &str) -> Option<Address> {
    let t = s.strip_prefix("0x").unwrap_or(s);
    if t.len() > 40 || t.len() % 2 != 0 {
        return None;
    }
    let padded = format!("{:0>40}", t);
    let mut raw = [0u8; 20];
    for i in 0..20 {
        raw[i] = u8::from_str_radix(&padded[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(Address::new(raw))
}

fn to_mon(m: &MonJson) -> Option<Mon> {
    Some(Mon {
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
        ability: hex_u256(&m.ability)?,
        moves: m.moves.iter().map(|w| hex_u256(w)).collect::<Option<Vec<_>>>()?,
    })
}

unsafe fn read_json<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

fn out_string(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// Create a battle session. Returns a nonzero handle, or 0 on bad input.
#[no_mangle]
pub unsafe extern "C" fn chomp_battle_new(cfg_json: *const c_char) -> u64 {
    let Some(raw) = read_json(cfg_json) else { return 0 };
    let Ok(cfg) = serde_json::from_str::<BattleCfg>(raw) else { return 0 };
    let (Some(p0_team), Some(p1_team)) = (
        cfg.p0Team.iter().map(to_mon).collect::<Option<Vec<_>>>(),
        cfg.p1Team.iter().map(to_mon).collect::<Option<Vec<_>>>(),
    ) else {
        return 0;
    };

    let result = std::panic::catch_unwind(move || {
        let mut world = World::new(Box::new(HarnessExt { p0_team, p1_team }));
        world.Engine = Engine::construct(
            U256::from(cfg.monsPerTeam),
            Constants::GAME_MOVES_PER_MON,
        );

        let book: HashMap<String, Address> = cfg
            .addressBook
            .iter()
            .filter_map(|(k, v)| Some((k.clone(), hex_address(v)?)))
            .collect();
        let engine_addr = book.get("Engine").copied().unwrap_or(ENGINE_ADDR);
        let rng_oracle = cfg
            .rngOracle
            .as_deref()
            .and_then(hex_address)
            .unwrap_or(Address::ZERO);
        if !book.is_empty() {
            let addr_of = move |name: &str| -> Address {
                *book
                    .get(name)
                    .unwrap_or_else(|| panic!("address book missing `{name}`"))
            };
            deploy_all(&mut world, &addr_of);
        }

        world.env.current_contract = engine_addr;
        world.env.block_timestamp = U256::from(1_800_000_000u64);
        world.env.block_number = U256::from(1u64);
        world.Engine.isMatchmakerFor.get_mut(&P0).set(MATCHMAKER, true);
        world.Engine.isMatchmakerFor.get_mut(&P1).set(MATCHMAKER, true);

        let (battle_key, _) = Engine::computeBattleKey(&mut world, P0, P1);
        let mut battle = Battle {
            p0: P0,
            p0TeamIndex: 0,
            p1: P1,
            p1TeamIndex: 0,
            teamRegistry: TEAM_REGISTRY,
            validator: Address::ZERO,
            rngOracle: rng_oracle,
            ruleset: Constants::INLINE_STAMINA_REGEN_RULESET,
            moveManager: MOVE_MANAGER,
            matchmaker: MATCHMAKER,
            engineHooks: Vec::new(),
        };
        world.env.msg_sender = MATCHMAKER;
        Engine::startBattle(&mut world, &mut battle);
        Session { world, battle_key }
    });
    let Ok(session) = result else { return 0 };

    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    registry().lock().unwrap().insert(handle, session);
    handle
}

/// Engine-side legality check (inline validator), 1 = valid.
#[no_mangle]
pub extern "C" fn chomp_battle_validate(
    handle: u64,
    seat: u8,
    move_index: u8,
    extra_data: u16,
) -> i32 {
    let mut reg = registry().lock().unwrap();
    let Some(s) = reg.get_mut(&handle) else { return -1 };
    let key = s.battle_key;
    let world = &mut s.world;
    let ok = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        Engine::validatePlayerMoveForBattle(
            world,
            key,
            U256::from(move_index),
            U256::from(seat),
            extra_data,
        )
    }));
    match ok {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => -1,
    }
}

fn snapshot_json(world: &mut World, battle_key: B256) -> String {
    let storage_key = Engine::_getStorageKey(world, battle_key);
    let data = world.Engine.battleData.get(&battle_key);
    let team_sizes = world.Engine.battleConfig.get_mut(&storage_key).teamSizes;
    let p0_size = (team_sizes & 0x0f) as usize;
    let p1_size = (team_sizes >> 4) as usize;
    let norm = |v: i32| if v == Constants::CLEARED_MON_STATE_SENTINEL { 0 } else { v };
    let mut sides = Vec::new();
    for (side, size) in [(0usize, p0_size), (1usize, p1_size)] {
        let mut mons = Vec::new();
        for i in 0..size {
            let cfg = world.Engine.battleConfig.get_mut(&storage_key);
            let s = if side == 0 {
                cfg.p0States.get(&U256::from(i as u64))
            } else {
                cfg.p1States.get(&U256::from(i as u64))
            };
            mons.push(json!({
                "hpDelta": norm(s.hpDelta),
                "staminaDelta": norm(s.staminaDelta),
                "isKnockedOut": s.isKnockedOut,
                "shouldSkipTurn": s.shouldSkipTurn,
            }));
        }
        sides.push(mons);
    }
    let p1_states = sides.pop().unwrap();
    let p0_states = sides.pop().unwrap();
    json!({
        "turnId": data.turnId,
        "winnerIndex": data.winnerIndex,
        "playerSwitchForTurnFlag": data.playerSwitchForTurnFlag,
        "p0Active": u64::try_from(Engine::_unpackActiveMonIndex(data.activeMonIndex, U256::ZERO)).unwrap(),
        "p1Active": u64::try_from(Engine::_unpackActiveMonIndex(data.activeMonIndex, U256::from(1u64))).unwrap(),
        "p0States": p0_states,
        "p1States": p1_states,
    })
    .to_string()
}

/// Execute one turn; returns the post-turn snapshot JSON (free with
/// chomp_str_free), or null on error / revert.
#[no_mangle]
pub unsafe extern "C" fn chomp_battle_turn(handle: u64, input_json: *const c_char) -> *mut c_char {
    let Some(raw) = read_json(input_json) else { return std::ptr::null_mut() };
    let Ok(input) = serde_json::from_str::<TurnInput>(raw) else {
        return std::ptr::null_mut();
    };
    let (Ok(p0_salt), Ok(p1_salt)) = (input.p0Salt.parse::<u128>(), input.p1Salt.parse::<u128>())
    else {
        return std::ptr::null_mut();
    };
    let mut reg = registry().lock().unwrap();
    let Some(s) = reg.get_mut(&handle) else { return std::ptr::null_mut() };
    let key = s.battle_key;
    let world = &mut s.world;
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        world.reset_transient();
        world.env.block_timestamp = world.env.block_timestamp + U256::from(1u64);
        world.env.msg_sender = MOVE_MANAGER;
        Engine::executeWithMoves(
            world,
            key,
            input.p0MoveIndex,
            p0_salt,
            input.p0ExtraData,
            input.p1MoveIndex,
            p1_salt,
            input.p1ExtraData,
        );
        snapshot_json(world, key)
    }));
    match out {
        Ok(snap) => out_string(snap),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Current snapshot without executing a turn (free with chomp_str_free).
#[no_mangle]
pub extern "C" fn chomp_battle_snapshot(handle: u64) -> *mut c_char {
    let mut reg = registry().lock().unwrap();
    let Some(s) = reg.get_mut(&handle) else { return std::ptr::null_mut() };
    let key = s.battle_key;
    let snap = snapshot_json(&mut s.world, key);
    out_string(snap)
}

#[no_mangle]
pub extern "C" fn chomp_battle_free(handle: u64) {
    registry().lock().unwrap().remove(&handle);
}

/// Release a string returned by chomp_battle_turn / chomp_battle_snapshot.
#[no_mangle]
pub unsafe extern "C" fn chomp_str_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
