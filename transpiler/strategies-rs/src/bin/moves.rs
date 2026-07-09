//! Move map — per mon, each catalog lane's name, inline/deployed status, and (for inline moves) the
//! packed base power / stamina / class. Used to pick informed, T1-mock-testable kit tweaks.
//!   cargo run --release -p chomp-strategies --bin moves

use chomp_engine::moves::MoveSlotLib;
use chomp_rt::U256;
use chomp_strategies::roster::load_roster;
use std::path::PathBuf;

fn field(word: U256, mask: u64, shift: u32) -> u64 {
    u64::try_from((word >> shift) & U256::from(mask)).unwrap_or(0)
}

fn class_name(c: u64) -> &'static str {
    match c {
        0 => "Physical",
        1 => "Special",
        2 => "Self",
        _ => "Other",
    }
}

fn main() {
    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);

    for m in &roster.mons {
        println!("\n{} (id {}):", m.name, m.id);
        for (l, cm) in m.catalog.iter().enumerate() {
            let inline = MoveSlotLib::isInline(cm.word);
            let tag = if l >= 4 { "  (rotating, not in default loadout)" } else { "" };
            if inline {
                let bp = field(cm.word, 0xFF, 248);
                let cls = field(cm.word, 0x3, 246);
                let pri = field(cm.word, 0x3, 244);
                let stam = field(cm.word, 0xF, 236);
                let ea = field(cm.word, 0xFF, 228);
                println!(
                    "  [{l}] {:<22} INLINE   pow={bp:<3} stam={stam} class={:<8} pri={pri} effAcc={ea}{tag}",
                    cm.name,
                    class_name(cls)
                );
            } else {
                println!("  [{l}] {:<22} deployed (contract move — T1 overlay inert; needs T2){tag}", cm.name);
            }
        }
    }
}
