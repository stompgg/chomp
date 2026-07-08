//! Standalone roster loader for the pure-Rust arena — replaces the TS team-builder the FFI arena
//! fed in. Reads `drool/*.csv` + the per-move inline JSONs and resolves each mon's move catalog to
//! the packed engine words, a faithful port of `sims/src/arena/team.ts` + `mon-builder.ts` +
//! `processing/packMoves.py`. Addresses are a deterministic name→address map (the arena only needs
//! deploy_all and the move/ability words to agree; the specific values are irrelevant).

use std::fs;
use std::path::Path;
use chomp_rt::{Address, U256};
use chomp_engine::Structs::MonStats;
use chomp_engine::Enums::Type;
use serde::Deserialize;

// The transpiled/deployed contracts (the ContractId set). A move whose contract name is in here
// resolves to its address; otherwise it falls to an inline JSON. Keep in sync with world.rs's enum.
const DEPLOYED: &[&str] = &[
    "ActusReus", "Adaptor", "Angery", "Baselight", "BlessedStatus", "Brightback", "BubbleBop",
    "BullRush", "BurnStatus", "CarrotHarvest", "ChainExpansion", "Chronoffense", "ContagiousSlumber",
    "Deadlift", "DeepFreeze", "Dreamcatcher", "DualShock", "EternalGrudge", "FoulLanguage",
    "FrostbiteStatus", "Gachachacha", "GildedRecovery", "GraveAffliction", "GuestFeature", "HardReset",
    "HeatBeacon", "HitAndDip", "HoneyBribe", "InfernalFlame", "Interweaving", "InvokeTaboo", "IronWall",
    "Loop", "MegaStarBlast", "ModalBolt", "NightTerrors", "NineNineNine", "Overclock", "Overflow",
    "PanicStatus", "PistolSquat", "PostWorkout", "PreemptiveShock", "Q5", "Renormalize",
    "RiseFromTheGrave", "RockPull", "RoundTrip", "Sanctify", "SaviorComplex", "SetAblaze", "SleepStatus",
    "SnackBreak", "SneakAttack", "Somniphobia", "StaminaRegen", "Tinderclaws", "TripleThink",
    "UnboundedStrike", "UpOnly", "VitalSiphon", "VolatilePunch", "WitherAway",
];

fn is_deployed(contract: &str) -> bool {
    DEPLOYED.contains(&contract)
}

/// "Bull Rush" / "Hit-And-Dip" → "BullRush" / "HitAndDip": split on space/hyphen, capitalize each
/// word's first char (rest untouched), join. Mirrors mon-builder.ts:moveNameToContract.
fn move_name_to_contract(name: &str) -> String {
    let mut out = String::new();
    for word in name.split(|c: char| c.is_whitespace() || c == '-').filter(|w| !w.is_empty()) {
        let mut chars = word.chars();
        if let Some(first) = chars.next() {
            out.extend(first.to_uppercase());
            out.push_str(chars.as_str());
        }
    }
    out
}

/// Deterministic name→address (FNV-1a-64 in the low 8 bytes). Unique for the ~70 distinct contract
/// names; never zero. deploy_all and team-building both resolve through this, so they agree.
pub fn addr_of(name: &str) -> Address {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in name.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    let mut bytes = [0u8; 20];
    bytes[12..20].copy_from_slice(&h.to_be_bytes());
    Address::from(bytes)
}

fn type_from_name(name: &str) -> Type {
    match name {
        "Yin" => Type::Yin, "Yang" => Type::Yang, "Earth" => Type::Earth, "Liquid" => Type::Liquid,
        "Fire" => Type::Fire, "Metal" => Type::Metal, "Ice" => Type::Ice, "Nature" => Type::Nature,
        "Lightning" => Type::Lightning, "Faith" => Type::Faith, "Air" => Type::Air, "Math" => Type::Math,
        "Cyber" => Type::Cyber, "Cosmic" => Type::Cosmic, "NA" | "" | "None" => Type::None,
        other => panic!("unknown type {other:?}"),
    }
}

fn class_from_name(name: &str) -> u64 {
    match name { "Physical" => 0, "Special" => 1, "Self" => 2, "Other" => 3, o => panic!("class {o:?}") }
}

#[derive(Deserialize)]
struct InlineMoveJson {
    #[serde(rename = "basePower")] base_power: u64,
    #[serde(rename = "staminaCost")] stamina_cost: u64,
    #[serde(rename = "moveType")] move_type: String,
    #[serde(rename = "moveClass")] move_class: String,
    #[serde(rename = "effectAccuracy")] effect_accuracy: u64,
    effect: Option<String>,
    #[serde(default)] priority: u64,
}

/// packMoves.py layout: [basePower:8|moveClass:2|priority:2|moveType:4|stamina:4|effectAccuracy:8|_:68|effect:160].
fn pack_inline_move(m: &InlineMoveJson) -> U256 {
    let effect_addr = match &m.effect {
        Some(e) if !e.is_empty() => U256::from_be_bytes::<32>({
            let mut b = [0u8; 32];
            b[12..].copy_from_slice(addr_of(&move_name_to_contract(e)).as_slice());
            b
        }),
        _ => U256::ZERO,
    };
    (U256::from(m.base_power) << 248)
        | (U256::from(class_from_name(&m.move_class)) << 246)
        | (U256::from(m.priority) << 244)
        | (U256::from(type_from_name(&m.move_type) as u64) << 240)
        | (U256::from(m.stamina_cost) << 236)
        | (U256::from(m.effect_accuracy) << 228)
        | effect_addr
}

fn addr_to_word(a: Address) -> U256 {
    let mut b = [0u8; 32];
    b[12..].copy_from_slice(a.as_slice());
    U256::from_be_bytes::<32>(b)
}

#[derive(Clone)]
pub struct CatalogMove {
    pub word: U256,
    pub name: String,
    pub unlock_level: u8,
}

pub struct RosterMon {
    pub id: u32,
    pub name: String,
    pub stats: MonStats,
    pub ability: U256,
    pub catalog: Vec<CatalogMove>,
}

pub struct Roster {
    pub mons: Vec<RosterMon>,
}

// Minimal CSV: split on commas, no quoted-field handling (the drool CSVs have none in the columns we
// read). Returns header + rows as field vecs.
fn read_csv(path: &Path) -> (Vec<String>, Vec<Vec<String>>) {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    let mut lines = text.lines().filter(|l| !l.trim().is_empty());
    let header: Vec<String> = lines.next().unwrap().split(',').map(|s| s.trim().to_string()).collect();
    let rows = lines.map(|l| l.split(',').map(|s| s.trim().to_string()).collect()).collect();
    (header, rows)
}

fn col(header: &[String], name: &str) -> usize {
    header.iter().position(|h| h == name).unwrap_or_else(|| panic!("no column {name}"))
}

/// Load the full roster from `chomp_root` (the repo root holding `drool/` and `src/`).
pub fn load_roster(chomp_root: &Path) -> Roster {
    let drool = chomp_root.join("drool");
    let src_mons = chomp_root.join("src").join("mons");

    // moves.csv → per-mon ordered (name, unlock) list.
    let (mh, mrows) = read_csv(&drool.join("moves.csv"));
    let (m_name, m_mon, m_unlock) = (col(&mh, "Name"), col(&mh, "Mon"), col(&mh, "UnlockLevel"));
    let mut moves_by_mon: Vec<(String, Vec<(String, u8)>)> = Vec::new();
    for r in &mrows {
        let mon = &r[m_mon];
        let entry = match moves_by_mon.iter_mut().find(|(m, _)| m == mon) {
            Some(e) => e,
            None => { moves_by_mon.push((mon.clone(), Vec::new())); moves_by_mon.last_mut().unwrap() }
        };
        entry.1.push((r[m_name].clone(), r[m_unlock].parse().unwrap_or(0)));
    }
    let moves_for = |mon: &str| moves_by_mon.iter().find(|(m, _)| m == mon).map(|(_, v)| v.clone()).unwrap_or_default();

    // abilities.csv → per-mon ability name.
    let (ah, arows) = read_csv(&drool.join("abilities.csv"));
    let (a_name, a_mon) = (col(&ah, "Name"), col(&ah, "Mon"));
    let ability_for = |mon: &str| arows.iter().find(|r| &r[a_mon] == mon).map(|r| r[a_name].clone());

    // mons.csv → the mons, resolving each move to its catalog word.
    let (h, rows) = read_csv(&drool.join("mons.csv"));
    let (c_id, c_name) = (col(&h, "Id"), col(&h, "Name"));
    let (c_hp, c_atk, c_def) = (col(&h, "HP"), col(&h, "Attack"), col(&h, "Defense"));
    let (c_spa, c_spd, c_spe) = (col(&h, "SpecialAttack"), col(&h, "SpecialDefense"), col(&h, "Speed"));
    let (c_t1, c_t2) = (col(&h, "Type1"), col(&h, "Type2"));

    let mut mons = Vec::new();
    for r in &rows {
        let name = r[c_name].clone();
        let mon_dir = name.to_lowercase();

        let mut catalog = Vec::new();
        for (mv_name, unlock) in moves_for(&name) {
            let contract = move_name_to_contract(&mv_name);
            let word = if is_deployed(&contract) {
                addr_to_word(addr_of(&contract))
            } else {
                let json_path = src_mons.join(&mon_dir).join(format!("{contract}.json"));
                match fs::read_to_string(&json_path) {
                    Ok(text) => pack_inline_move(&serde_json::from_str(&text).unwrap()),
                    Err(_) => continue, // unimplemented move — skip (mirrors monCatalog)
                }
            };
            catalog.push(CatalogMove { word, name: mv_name, unlock_level: unlock });
        }
        if catalog.is_empty() {
            panic!("mon {name} has no resolvable moves");
        }

        let ability = ability_for(&name)
            .map(|a| move_name_to_contract(&a))
            .filter(|c| is_deployed(c))
            .map(|c| addr_to_word(addr_of(&c)))
            .unwrap_or(U256::ZERO);

        mons.push(RosterMon {
            id: r[c_id].parse().unwrap(),
            name,
            stats: MonStats {
                hp: r[c_hp].parse().unwrap(),
                stamina: 5, // DEFAULT_STAMINA — not a mons.csv column
                speed: r[c_spe].parse().unwrap(),
                attack: r[c_atk].parse().unwrap(),
                defense: r[c_def].parse().unwrap(),
                specialAttack: r[c_spa].parse().unwrap(),
                specialDefense: r[c_spd].parse().unwrap(),
                type1: type_from_name(&r[c_t1]),
                type2: type_from_name(&r[c_t2]),
            },
            ability,
            catalog,
        });
    }
    mons.sort_by_key(|m| m.id);
    Roster { mons }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chomp_root() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    }

    #[test]
    fn loads_every_mon_with_a_catalog() {
        let r = load_roster(&chomp_root());
        assert!(r.mons.len() >= 13, "expected the full roster, got {}", r.mons.len());
        for m in &r.mons {
            assert!(!m.catalog.is_empty(), "{} resolved no moves", m.name);
            // Every catalog word is non-zero and each deployed word has empty upper 96 bits (an
            // address), while inline words carry packed params (upper bits set).
            for mv in &m.catalog {
                assert!(mv.word != U256::ZERO, "{} / {} packed to zero", m.name, mv.name);
            }
        }
        // Spot-check a known deployed move + a known inline move resolve to the right shape.
        let ghouliath = r.mons.iter().find(|m| m.name == "Ghouliath").expect("Ghouliath");
        let inferno = ghouliath.catalog.iter().find(|c| c.name == "Infernal Flame").expect("Infernal Flame");
        assert!(inferno.word >> 160 == U256::ZERO, "deployed move should be a bare address");
        let osteo = ghouliath.catalog.iter().find(|c| c.name == "Osteoporosis").expect("Osteoporosis (inline)");
        assert!(osteo.word >> 160 != U256::ZERO, "inline move should carry packed params");
        println!("roster: {} mons, sample catalog {} = {}", r.mons.len(), ghouliath.name, ghouliath.catalog.len());
    }
}
