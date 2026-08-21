//! Head-to-head between search SHAPES — the strength gate for a cheaper beam.
//!
//! Each row plays a candidate `SearchOpts` against the shipped shape at the same depth, peek
//! and weights, so the only difference is cost. Cheaper is only worth adopting when its
//! interval straddles 50%.
//!
//!   cargo run --release -p chomp-strategies --bin shapeoff -- --games 2000
//!   cargo run --release -p chomp-strategies --bin shapeoff -- --only guide3 --games 6000

use chomp_strategies::arena::shape_ab_winrate;
use chomp_strategies::roster::load_roster;
use chomp_strategies::search::{SearchOpts, MUNCH_SINGLES};
use chomp_strategies::sim::Field;
use std::path::PathBuf;

fn arg(args: &[String], flag: &str) -> Option<String> {
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}
fn arg_u(args: &[String], flag: &str, def: u64) -> u64 {
    match arg(args, flag) {
        Some(v) if v.starts_with("0x") => u64::from_str_radix(&v[2..], 16).unwrap_or(def),
        Some(v) => v.parse().unwrap_or(def),
        None => def,
    }
}

/// The shape the beam sweep was originally run against. It is NOT what munch ships today
/// (settlement is off there and the deepest ply caps at 2) — see `MUNCH_SINGLES`. Kept as the
/// baseline the existing rows' historical numbers are comparable to.
const SHIPPED: SearchOpts = SearchOpts {
    vetoes: 0,
    settle_rounds: 2,
    opp_streak: 0,
    beam_k: 2,
    guide_actions: 0,
    int_actions: 4,
    int_actions_deep: 0,
    rank_capped: false,
    salt_samples: 0,
};

fn shape(int_actions: usize, guide_actions: usize, int_deep: usize, settle: u32) -> SearchOpts {
    SearchOpts { int_actions, guide_actions, int_actions_deep: int_deep, settle_rounds: settle, ..SHIPPED }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let games = arg_u(&args, "--games", 2000) as usize;
    let seed = arg_u(&args, "--seed", 0xbeefcafe) as u32;
    let seed_base = arg_u(&args, "--seed-base", 10_000) as u32;
    let depth = arg_u(&args, "--depth", 3) as u32;
    let default_threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let threads = arg_u(&args, "--threads", default_threads as u64) as usize;
    let only = arg(&args, "--only").unwrap_or_default();
    let field = arg(&args, "--field")
        .map(|v| Field::parse(&v).expect("--field: none | flux | elemental | unstable"))
        .unwrap_or(Field::None);

    // `--set combo` retests the rows the first sweep cleared, plus their combinations: the
    // caps interact (int2 and guide4 each held strength alone, together they did not), so a
    // combined shape has to be measured rather than inferred from its parts.
    let combo: Vec<(&str, SearchOpts)> = vec![
        ("int2+settle0 i2 g- s0", shape(2, 0, 0, 0)),
        ("int2+deep2   i2 g- s2 d2", shape(2, 0, 2, 2)),
        ("int2+d2+s0   i2 g- s0 d2", shape(2, 0, 2, 0)),
        ("deep2+settle0 i4 g- s0 d2", shape(4, 0, 2, 0)),
        ("int2         i2 g- s2", shape(2, 0, 0, 2)),
        ("settle0      i4 g- s0", shape(4, 0, 0, 0)),
        ("self-control i4 g- s2", SHIPPED),
    ];

    // Ordered cheapest-looking first; the labels match the munch sweep's shapes.
    let variants: Vec<(&str, SearchOpts)> = vec![
        ("int2+guide2  i2 g2 s2", shape(2, 2, 0, 2)),
        ("int2+guide3  i2 g3 s2", shape(2, 3, 0, 2)),
        ("int3+guide3  i3 g3 s2", shape(3, 3, 0, 2)),
        ("int2+guide4  i2 g4 s2", shape(2, 4, 0, 2)),
        ("int3+guide4  i3 g4 s2", shape(3, 4, 0, 2)),
        ("guide4       i4 g4 s2", shape(4, 4, 0, 2)),
        ("int2         i2 g- s2", shape(2, 0, 0, 2)),
        ("deep2        i4 g- s2 d2", shape(4, 0, 2, 2)),
        ("deep2+guide3 i4 g3 s2 d2", shape(4, 3, 2, 2)),
        ("settle1      i4 g- s1", shape(4, 0, 0, 1)),
        ("settle0      i4 g- s0", shape(4, 0, 0, 0)),
        ("self-control i4 g- s2", SHIPPED),
    ];

    let chomp_root = std::env::var("CHOMP_ROOT").map(PathBuf::from).unwrap_or_else(|_| {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..")
    });
    let roster = load_roster(&chomp_root);
    eprintln!(
        "shapeoff: d{depth} peek maximin · {games} games/row · {threads} threads · field {field:?}"
    );
    println!("{:>26}  {:>7}  {:>8}  {:>10}  {:>14}", "candidate", "drafts", "win%", "95% CI", "w-l-draw");
    // `--set rank` asks one question: does ranking a capped candidate list by base power beat
    // truncating it in loadout order? Both sides run the live munch shape, so nothing else moves.
    let rank_rows: Vec<(&str, SearchOpts)> = vec![
        ("rank-capped  i4 s0 d2", MUNCH_SINGLES),
        ("self-control i4 s0 d2", SearchOpts { rank_capped: false, ..MUNCH_SINGLES }),
    ];
    let set = arg(&args, "--set").unwrap_or_default();
    let (variants, base) = match set.as_str() {
        "combo" => (combo, SHIPPED),
        "rank" => (rank_rows, SearchOpts { rank_capped: false, ..MUNCH_SINGLES }),
        _ => (variants, SHIPPED),
    };
    for (label, opts) in &variants {
        if !only.is_empty() && !label.contains(&only) {
            continue;
        }
        let started = std::time::Instant::now();
        let r = shape_ab_winrate(
            &roster, depth, *opts, base, games, seed, seed_base, threads, field,
        );
        println!(
            "{:>26}  {:>7}  {:>7.1}%  ±{:>8.1}%  {:>5}-{:>4}-{:<4}",
            label, r.drafts, r.win_rate() * 100.0, r.ci95() * 100.0, r.wins, r.losses, r.draws
        );
        eprintln!("    ({:.1}s)", started.elapsed().as_secs_f64());
    }
}
