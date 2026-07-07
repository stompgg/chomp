//! chomp-ffi — cdylib surface for bun:ffi: BATCH MODE ONLY.
//!
//! One entry point: `chomp_run_games` plays whole games natively
//! (transpiled engine + native strategies) and returns outcomes — one FFI
//! crossing per batch. The per-turn handle API that let TS strategies
//! drive the Rust engine was retired when the stacks were decoupled (git
//! history has it). Strings returned here are heap CStrings — release
//! with `chomp_str_free`.
//!
//! cfg JSON: { monsPerTeam, addressBook?: {name: "0x.."}, threads?,
//!             trace?, games: [ { seed, maxTurns, p0Strategy, p1Strategy,
//!             p0Team: [Mon], p1Team: [Mon] } ] }
//! Mon JSON matches rust-ffi.ts's monToJson: stats fields + type1/type2
//! (u8) + moves (hex u256 words: inline-packed or contract addresses from
//! the book) + ability (hex).

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};

use serde::Deserialize;
use serde_json::json;

use chomp_engine::Enums::Type;
use chomp_engine::Structs::{Mon, MonStats};
use chomp_rt::{Address, U256};
use chomp_strategies::game::{run_games, GameSpec, StrategyKind};

/// ABI/version probe: returns (major << 16 | minor). rust-ffi.ts asserts
/// this at dlopen so exported-signature drift fails at load time.
#[no_mangle]
pub extern "C" fn chomp_ffi_version() -> u32 {
    (0u32 << 16) | 5u32
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
    /// Record per-turn submissions in the results.
    #[serde(default)]
    trace: bool,
    games: Vec<BatchGameJson>,
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

/// Read a NUL-terminated argument string.
unsafe fn read_cstr<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok()
}

fn out_string(s: String) -> *mut c_char {
    CString::new(s).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

/// Run a batch of games natively (strategies + engine in-process).
/// Returns { results: [ { winnerSeat, turns, moves?, error? } ] } — free
/// with chomp_str_free; null on unparseable cfg / unknown strategy.
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

/// Release a string returned by chomp_run_games.
#[no_mangle]
pub unsafe extern "C" fn chomp_str_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
