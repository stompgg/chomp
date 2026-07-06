//! chomp-ffi — cdylib surface for bun:ffi.
//!
//! Handle-based battle API with a JSON boundary: the engine executes
//! native (no bigint), one FFI crossing per call. Strings returned by
//! `chomp_battle_*` / `chomp_run_games` are heap CStrings — release them
//! with `chomp_str_free`.
//!
//!   chomp_battle_new(cfg_json)   -> handle (0 = error; see cfg below)
//!   chomp_battle_validate(h, bk, seat, moveIndex, extraData) -> 1/0
//!   chomp_battle_turn(h, input_json) -> snapshot json (null on error)
//!   chomp_run_games(cfg_json)    -> results json (batch mode: whole
//!                                   games with native strategies)
//!   chomp_battle_free(h)
//!
//! cfg JSON: { monsPerTeam, p0Team: [Mon], p1Team: [Mon],
//!             addressBook?: {name: "0x.."} }
//! Mon JSON mirrors the lockstep fixture: stats fields + type1/type2 (u8)
//! + moves (hex u256 words: inline-packed or contract addresses from the
//! book) + ability (hex).
//! turn JSON: { p0MoveIndex, p1MoveIndex, p0Salt, p1Salt,
//!              p0ExtraData, p1ExtraData } (salts are decimal strings).
//!
//! Harness semantics (world setup, turn boundaries, hypothetical forks)
//! live in chomp_strategies::sim — ONE implementation shared with the
//! native batch runner; this crate only parses and serializes.

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde::Deserialize;
use serde_json::json;

use chomp_engine::world::World;
use chomp_engine::Enums::Type;
use chomp_engine::Structs::{Mon, MonStats};
use chomp_engine::{Constants, Engine};
use chomp_rt::{Address, B256, U256};
use chomp_strategies::game::{run_games, GameSpec, StrategyKind};
use chomp_strategies::sim::{HypoMove, Sim};

/// ABI/version probe: returns (major << 16 | minor). rust-engine.ts
/// asserts this at dlopen so exported-signature drift fails at load time.
#[no_mangle]
pub extern "C" fn chomp_ffi_version() -> u32 {
    (0u32 << 16) | 3u32
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
    /// path). Set explicitly only to mirror a recorded TS fixture.
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

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

/// Two-level locking: the registry mutex is held only long enough to clone
/// the session Arc; each battle then serializes on ITS OWN mutex. bun
/// Workers are threads in one process sharing these globals — with a single
/// registry-wide lock held across engine execution, a worker pool would
/// serialize completely.
fn registry() -> &'static Mutex<HashMap<u64, Arc<Mutex<Sim>>>> {
    static REG: std::sync::OnceLock<Mutex<HashMap<u64, Arc<Mutex<Sim>>>>> =
        std::sync::OnceLock::new();
    REG.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Grab a session's Arc without holding the registry lock during the call.
fn session(handle: u64) -> Option<Arc<Mutex<Sim>>> {
    registry().lock().unwrap().get(&handle).cloned()
}

fn hex_u256(s: &str) -> Option<U256> {
    let t = s.strip_prefix("0x").unwrap_or(s);
    U256::from_str_radix(t, 16).ok()
}

fn hex_address(s: &str) -> Option<Address> {
    let t = s.strip_prefix("0x").unwrap_or(s);
    if t.len() > 40 || t.len() % 2 != 0 {
        return None; // stricter than from_str_radix: reject odd-length input
    }
    hex_u256(s).map(chomp_rt::address_from_u256)
}

fn parse_book(book: &HashMap<String, String>) -> HashMap<String, Address> {
    book.iter()
        .filter_map(|(k, v)| Some((k.clone(), hex_address(v)?)))
        .collect()
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

fn to_team(team: &[MonJson]) -> Option<Vec<Mon>> {
    team.iter().map(to_mon).collect()
}

/// Read a NUL-terminated argument string (JSON payloads and plain hex keys).
unsafe fn read_cstr<'a>(ptr: *const c_char) -> Option<&'a str> {
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
    let Some(raw) = read_cstr(cfg_json) else { return 0 };
    let Ok(cfg) = serde_json::from_str::<BattleCfg>(raw) else { return 0 };
    let (Some(p0_team), Some(p1_team)) = (to_team(&cfg.p0Team), to_team(&cfg.p1Team)) else {
        return 0;
    };
    let book = parse_book(&cfg.addressBook);
    let rng_oracle = cfg
        .rngOracle
        .as_deref()
        .and_then(hex_address)
        .unwrap_or(Address::ZERO);

    let result = std::panic::catch_unwind(move || {
        Sim::new(cfg.monsPerTeam, p0_team, p1_team, &book, rng_oracle)
    });
    let Ok(sim) = result else { return 0 };

    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    registry()
        .lock()
        .unwrap()
        .insert(handle, Arc::new(Mutex::new(sim)));
    handle
}

/// Engine-side legality check (inline validator), 1 = valid. `bk` is a
/// plain hex C string — the LIVE key or a fork key; null = live battle.
#[no_mangle]
pub unsafe extern "C" fn chomp_battle_validate(
    handle: u64,
    bk: *const c_char,
    seat: u8,
    move_index: u8,
    extra_data: u16,
) -> i32 {
    let Some(sess) = session(handle) else { return -1 };
    let mut s = sess.lock().unwrap();
    let key = match read_cstr(bk) {
        Some(raw) if !raw.is_empty() => match parse_b256(raw) {
            Some(k) => k,
            None => return -1,
        },
        _ => s.battle_key,
    };
    let s = &mut *s;
    let ok = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        s.validate_move(key, U256::from(seat as u64), move_index, extra_data)
    }));
    match ok {
        Ok(true) => 1,
        Ok(false) => 0,
        Err(_) => -1,
    }
}

fn parse_b256(raw: &str) -> Option<B256> {
    raw.parse::<B256>().ok() // optionally-0x-prefixed, exactly 64 nibbles
}

fn snapshot_json(world: &mut World, battle_key: B256) -> String {
    let storage_key = Engine::_getStorageKey(world, battle_key);
    let data = world.Engine.battleData.get(&battle_key);
    let team_sizes = world.Engine.battleConfig.get_mut(&storage_key).teamSizes;
    let norm = |v: i32| if v == Constants::CLEARED_MON_STATE_SENTINEL { 0 } else { v };
    let mut side_states = |p1: bool| -> Vec<serde_json::Value> {
        let size = if p1 { team_sizes >> 4 } else { team_sizes & 0x0f } as usize;
        (0..size)
            .map(|i| {
                let cfg = world.Engine.battleConfig.get_mut(&storage_key);
                let s = if p1 {
                    cfg.p1States.get(&U256::from(i as u64))
                } else {
                    cfg.p0States.get(&U256::from(i as u64))
                };
                json!({
                    "hpDelta": norm(s.hpDelta),
                    "staminaDelta": norm(s.staminaDelta),
                    "isKnockedOut": s.isKnockedOut,
                    "shouldSkipTurn": s.shouldSkipTurn,
                })
            })
            .collect()
    };
    let p0_states = side_states(false);
    let p1_states = side_states(true);
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
    let Some(raw) = read_cstr(input_json) else { return std::ptr::null_mut() };
    let Ok(input) = serde_json::from_str::<TurnInput>(raw) else {
        return std::ptr::null_mut();
    };
    let (Ok(p0_salt), Ok(p1_salt)) = (input.p0Salt.parse::<u128>(), input.p1Salt.parse::<u128>())
    else {
        return std::ptr::null_mut();
    };
    let Some(sess) = session(handle) else { return std::ptr::null_mut() };
    let mut s = sess.lock().unwrap();
    let s = &mut *s;
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        s.execute_turn(
            input.p0MoveIndex,
            p0_salt,
            input.p0ExtraData,
            input.p1MoveIndex,
            p1_salt,
            input.p1ExtraData,
        );
        snapshot_json(&mut s.world, s.battle_key)
    }));
    match out {
        Ok(snap) => out_string(snap),
        Err(_) => std::ptr::null_mut(),
    }
}

// ---------------------------------------------------------------------------
// Rich state + forward-model forks (the arena adapter surface).
//
// The rich state is built ENTIRELY from transpiled engine getters — the TS
// adapter is a dumb cache reader over this JSON; no engine semantics are
// reimplemented on either side of the boundary.
// ---------------------------------------------------------------------------

fn hex<T: std::fmt::LowerHex>(v: T) -> String {
    format!("{:#x}", v)
}

fn mon_json(world: &mut World, bk: B256, p: U256, i: U256, full: bool) -> serde_json::Value {
    use chomp_engine::Enums::MonStateIndexName;
    let stats = Engine::getMonStatsForBattle(world, bk, p, i);
    // state[j] / value[j] indexed by MonStateIndexName ordinal.
    let state: Vec<i64> = (0u8..=8)
        .map(|j| Engine::getMonStateForBattle(world, bk, p, i, MonStateIndexName::from_u8(j)) as i64)
        .collect();
    // value[] by MonStateIndexName ordinal; 7/8 (KO / skip flags) are not
    // value-getter domain — zero placeholders keep the ordinals aligned so
    // Type1 (9) / Type2 (10) land at their true indices.
    let value: Vec<u32> = (0u8..=10)
        .map(|j| match j {
            7 | 8 => 0,
            _ => Engine::getMonValueForBattle(world, bk, p, i, MonStateIndexName::from_u8(j)),
        })
        .collect();
    let mut out = json!({
        "stats": {
            "hp": stats.hp, "stamina": stats.stamina, "speed": stats.speed,
            "attack": stats.attack, "defense": stats.defense,
            "specialAttack": stats.specialAttack, "specialDefense": stats.specialDefense,
            "type1": stats.type1 as u8, "type2": stats.type2 as u8,
        },
        "state": state,
        "value": value,
    });
    if full {
        // Fork views (forward-model hypotheticals) never read moves/effects;
        // omitting them halves the dump cost. The TS adapter throws loudly
        // if a lite state's missing section is ever read.
        let moves: Vec<String> = (0u64..4)
            .map(|k| hex(Engine::getMoveForMonForBattle(world, bk, p, i, U256::from(k))))
            .collect();
        let (effs, idxs) = Engine::getEffects(world, bk, p, i);
        let effects: Vec<serde_json::Value> = effs
            .iter()
            .zip(idxs.iter())
            .map(|(e, ix)| {
                json!({
                    "address": hex(e.effect),
                    "stepsBitmap": e.stepsBitmap,
                    "data": hex(e.data),
                    "index": u64::try_from(*ix).unwrap(),
                })
            })
            .collect();
        out["moves"] = json!(moves);
        out["effects"] = json!(effects);
    }
    out
}

fn dcc_json(world: &mut World, bk: B256, atk: u64, def: u64) -> serde_json::Value {
    let d = Engine::getDamageCalcContext(world, bk, U256::from(atk), U256::from(def));
    json!({
        "attackerMonIndex": d.attackerMonIndex, "defenderMonIndex": d.defenderMonIndex,
        "attackerAttack": d.attackerAttack, "attackerAttackDelta": d.attackerAttackDelta,
        "attackerSpAtk": d.attackerSpAtk, "attackerSpAtkDelta": d.attackerSpAtkDelta,
        "defenderDef": d.defenderDef, "defenderDefDelta": d.defenderDefDelta,
        "defenderSpDef": d.defenderSpDef, "defenderSpDefDelta": d.defenderSpDefDelta,
        "defenderType1": d.defenderType1 as u8, "defenderType2": d.defenderType2 as u8,
    })
}

fn rich_state_json(world: &mut World, bk: B256, full: bool) -> String {
    let ctx = Engine::getBattleContext(world, bk);
    let mut side_json = |p: u64| -> serde_json::Value {
        let pi = U256::from(p);
        let size = u64::try_from(Engine::getTeamSize(world, bk, pi)).unwrap();
        let ko = Engine::getKOBitmap(world, bk, pi);
        let mons: Vec<serde_json::Value> = (0..size)
            .map(|i| mon_json(world, bk, pi, U256::from(i), full))
            .collect();
        let mut side = json!({
            "teamSize": size,
            "koBitmap": u64::try_from(ko).unwrap(),
            "mons": mons,
        });
        if full {
            let dec = Engine::getMoveDecisionForBattleState(world, bk, pi);
            side["moveDecision"] =
                json!({ "packedMoveIndex": dec.packedMoveIndex, "extraData": dec.extraData });
        }
        side
    };
    let p0 = side_json(0);
    let p1 = side_json(1);
    let mut out = json!({
        "turnId": ctx.turnId,
        "winnerIndex": ctx.winnerIndex,
        "playerSwitchForTurnFlag": ctx.playerSwitchForTurnFlag,
        "p0Active": ctx.p0ActiveMonIndex,
        "p1Active": ctx.p1ActiveMonIndex,
        "lite": !full,
        "p0": p0,
        "p1": p1,
    });
    if full {
        out["dcc01"] = dcc_json(world, bk, 0, 1);
        out["dcc10"] = dcc_json(world, bk, 1, 0);
    }
    out.to_string()
}

/// Live `getGlobalKV` read (transpiled getter; works on fork keys too since
/// forks stay resident until disposed). Mon metadata paths reach this
/// (HeatBeaconLib priority boosts etc.). Returns the value as a hex C
/// string, or null on error.
#[no_mangle]
pub unsafe extern "C" fn chomp_battle_kv(handle: u64, bk: *const c_char, key: u64) -> *mut c_char {
    let Some(raw) = read_cstr(bk) else { return std::ptr::null_mut() };
    let Some(k) = parse_b256(raw) else { return std::ptr::null_mut() };
    let Some(sess) = session(handle) else { return std::ptr::null_mut() };
    let mut s = sess.lock().unwrap();
    let s = &mut *s;
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        hex(s.global_kv(k, key))
    }));
    match out {
        Ok(v) => out_string(v),
        Err(_) => std::ptr::null_mut(),
    }
}

/// The session's battle key as a hex C string (free with chomp_str_free).
#[no_mangle]
pub extern "C" fn chomp_battle_key(handle: u64) -> *mut c_char {
    let Some(sess) = session(handle) else { return std::ptr::null_mut() };
    let key = sess.lock().unwrap().battle_key;
    out_string(hex(key))
}

/// Rich getter-backed state of the LIVE battle (free with chomp_str_free).
#[no_mangle]
pub extern "C" fn chomp_battle_state(handle: u64) -> *mut c_char {
    let Some(sess) = session(handle) else { return std::ptr::null_mut() };
    let mut s = sess.lock().unwrap();
    let s = &mut *s;
    let key = s.battle_key;
    s.world.reset_transient(); // fresh-tx boundary
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        rich_state_json(&mut s.world, key, true)
    }));
    match out {
        Ok(js) => out_string(js),
        Err(_) => std::ptr::null_mut(),
    }
}

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct HypoMoveJson {
    moveIndex: u8,
    salt: String,
    #[serde(default)]
    extraData: u16,
}

#[derive(Deserialize)]
struct HypoInput {
    p0: Option<HypoMoveJson>,
    p1: Option<HypoMoveJson>,
}

fn to_hypo(m: &HypoMoveJson) -> HypoMove {
    HypoMove {
        move_index: m.moveIndex,
        salt: m.salt.parse::<u128>().expect("bad salt"),
        extra_data: m.extraData,
    }
}

/// Fork the battle, run ONE hypothetical turn on the fork (silent — the TS
/// forward-model's applyHypotheticalMove semantics), and return
/// { forkKey, state }. The fork STAYS LIVE for follow-up reads until
/// chomp_battle_dispose_fork — or battle_free reclaims everything.
#[no_mangle]
pub unsafe extern "C" fn chomp_battle_hypothetical(handle: u64, input_json: *const c_char) -> *mut c_char {
    let Some(raw) = read_cstr(input_json) else { return std::ptr::null_mut() };
    let Ok(input) = serde_json::from_str::<HypoInput>(raw) else {
        return std::ptr::null_mut();
    };
    let Some(sess) = session(handle) else { return std::ptr::null_mut() };
    let mut s = sess.lock().unwrap();
    let s = &mut *s;
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let fork = s.apply_hypothetical(
            input.p0.as_ref().map(to_hypo),
            input.p1.as_ref().map(to_hypo),
        );
        let state = rich_state_json(&mut s.world, fork, false);
        format!("{{\"forkKey\":\"{}\",\"state\":{state}}}", hex(fork))
    }));
    match out {
        Ok(js) => out_string(js),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Reclaim a fork's cloned state (mirrors the TS disposeFork).
#[no_mangle]
pub unsafe extern "C" fn chomp_battle_dispose_fork(handle: u64, fork_key: *const c_char) -> i32 {
    let Some(raw) = read_cstr(fork_key) else { return -1 };
    let Some(fork) = parse_b256(raw) else { return -1 };
    let Some(sess) = session(handle) else { return -1 };
    sess.lock().unwrap().dispose_fork(fork);
    1
}

/// Current snapshot without executing a turn (free with chomp_str_free).
#[no_mangle]
pub extern "C" fn chomp_battle_snapshot(handle: u64) -> *mut c_char {
    let Some(sess) = session(handle) else { return std::ptr::null_mut() };
    let mut s = sess.lock().unwrap();
    let s = &mut *s;
    let key = s.battle_key;
    let out = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        snapshot_json(&mut s.world, key)
    }));
    match out {
        Ok(snap) => out_string(snap),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn chomp_battle_free(handle: u64) {
    registry().lock().unwrap().remove(&handle); // Arc drops when last user releases
}

// ---------------------------------------------------------------------------
// Batch mode: whole games with NATIVE strategies — one crossing per batch.
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct BatchGameJson {
    seed: u32,
    maxTurns: u32,
    /// Physical-seat strategies ("hard" | "greedy" | "override").
    p0Strategy: String,
    p1Strategy: String,
    p0Team: Vec<MonJson>,
    p1Team: Vec<MonJson>,
}

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct BatchCfg {
    monsPerTeam: u64,
    #[serde(default)]
    addressBook: HashMap<String, String>,
    /// Worker threads (games are independent worlds). Default 1.
    #[serde(default)]
    threads: Option<usize>,
    /// Record per-turn submissions (the lockstep gate's compare key).
    #[serde(default)]
    trace: bool,
    games: Vec<BatchGameJson>,
}

/// Run a batch of games natively (strategies + engine in-process).
/// Returns { results: [ { winnerSeat, turns, moves?, error? } ] } — free
/// with chomp_str_free; null on unparseable cfg.
#[no_mangle]
pub unsafe extern "C" fn chomp_run_games(cfg_json: *const c_char) -> *mut c_char {
    let Some(raw) = read_cstr(cfg_json) else { return std::ptr::null_mut() };
    let Ok(cfg) = serde_json::from_str::<BatchCfg>(raw) else {
        return std::ptr::null_mut();
    };
    let book = parse_book(&cfg.addressBook);

    let mut specs: Vec<GameSpec> = Vec::with_capacity(cfg.games.len());
    for g in &cfg.games {
        let (Some(p0_strategy), Some(p1_strategy)) =
            (StrategyKind::parse(&g.p0Strategy), StrategyKind::parse(&g.p1Strategy))
        else {
            return std::ptr::null_mut(); // unknown strategy name
        };
        let (Some(p0_team), Some(p1_team)) = (to_team(&g.p0Team), to_team(&g.p1Team)) else {
            return std::ptr::null_mut();
        };
        specs.push(GameSpec {
            seed: g.seed,
            max_turns: g.maxTurns,
            mons_per_team: cfg.monsPerTeam,
            p0_team,
            p1_team,
            p0_strategy,
            p1_strategy,
        });
    }

    let results = run_games(&specs, &book, cfg.threads.unwrap_or(1), cfg.trace);
    let results_json: Vec<serde_json::Value> = results
        .iter()
        .map(|r| match r {
            Ok(o) => {
                let mut v = json!({
                    "winnerSeat": o.winner_seat,
                    "turns": o.turns,
                });
                if cfg.trace {
                    let moves: Vec<serde_json::Value> = o
                        .trace
                        .iter()
                        .map(|t| {
                            let enc = |m: Option<chomp_strategies::view::Mv>| match m {
                                Some(m) => json!([m.move_index, m.extra_data]),
                                None => json!(null),
                            };
                            json!([enc(t.p0), enc(t.p1)])
                        })
                        .collect();
                    v["moves"] = json!(moves);
                }
                v
            }
            Err(e) => json!({ "error": e }),
        })
        .collect();
    out_string(json!({ "results": results_json }).to_string())
}

/// Release a string returned by any chomp_* JSON entry point.
#[no_mangle]
pub unsafe extern "C" fn chomp_str_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
