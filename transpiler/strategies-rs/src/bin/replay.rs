//! Replay mainnet battle logs against the current Rust CPU policies.
//!
//!   cargo run --release -p chomp-strategies --bin replay -- [--log logs.txt] [--battle N]

use chomp_strategies::replay::{parse_logs, replay_doubles, replay_singles};
use chomp_strategies::roster::{self, load_roster};
use std::path::PathBuf;

fn arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let log_path = arg(&args, "--log")
        .map(PathBuf::from)
        .unwrap_or_else(|| chomp_root.join("logs.txt"));
    let only: Option<usize> = arg(&args, "--battle").and_then(|v| v.parse().ok());

    let text = std::fs::read_to_string(&log_path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", log_path.display()));
    let battles = parse_logs(&text);
    println!("{} battles parsed from {}", battles.len(), log_path.display());

    let roster = load_roster(&chomp_root);
    let book = roster::address_book();

    for (i, b) in battles.iter().enumerate() {
        if only.is_some_and(|n| n != i) {
            continue;
        }
        println!(
            "\n═══ battle {i}: {} ({}, {} — logged winner side {}) ═══",
            b.key,
            if b.doubles { "doubles" } else { "singles" },
            b.difficulty,
            b.winner_side,
        );
        let report = if b.doubles {
            replay_doubles(b, &roster, &book)
        } else {
            replay_singles(b, &roster, &book)
        };
        println!(
            "   fidelity: {}",
            if report.fidelity_ok { "OK — exact replay" } else { "DESYNC(S) — see !! lines" }
        );
    }
}
