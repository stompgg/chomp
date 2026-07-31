//! Mainnet battle-log replay — drive the engine with the LOGGED actions and
//! salts (the CPU's salt is always 0 on-chain, so complete player salts
//! reproduce the keccak rng bit-exactly), and at every CPU decision point ask
//! the current Rust policies what they would play instead.
//!
//! Fidelity is self-checking: a truncated salt or wrong stat model desyncs the
//! forced-switch pattern / legality of logged moves within a turn or two, and
//! the replay reports the mismatch instead of silently diverging.

use std::collections::HashMap;

use chomp_engine::Engine;
use chomp_engine::Structs::{Mon, MonStats};
use chomp_rt::{Address, U256};

use crate::arena::build_team_mon;
use crate::bot::{BattleMode, Bot, BotConfig, DecisionCtx};
use crate::bots;
use crate::doubles::{self, Difficulty, DoublesEvalW, SlotMove};
use crate::evaluator::{Weights, DEFAULT_WEIGHTS, N_FEATURES};
use crate::jsrng::derive;
use crate::roster::Roster;
use crate::sim::{pack_side, Sim};
use crate::view::{
    capture_view, mon_current_hp, mon_current_stamina, mon_max_hp, mon_skip_turn, Mv, Seat,
    NO_OP_INDEX, SWITCH_MOVE_INDEX, VCPU, VOPP,
};

// ── Parsed log model ────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq)]
pub struct LoggedAction {
    pub move_index: u8, // lane 0-3, SWITCH_MOVE_INDEX, NO_OP_INDEX
    pub extra_data: u16,
}

pub struct LoggedTurn {
    /// One action per side in singles, two (lane 0, lane 1) in doubles.
    pub a: Vec<LoggedAction>,
    pub b: Vec<LoggedAction>,
    pub a_salt: u128,
    pub b_salt: u128,
}

pub struct LoggedMon {
    pub name: String,
    pub facet: u8, // facetId; 0 = none
    pub moves: Vec<String>,
}

pub struct LoggedBattle {
    pub key: String,
    pub difficulty: String,
    pub doubles: bool,
    /// 0 = side A is the CPU, 1 = side B.
    pub cpu_side: u8,
    /// 0 = A won, 1 = B won (by address match).
    pub winner_side: u8,
    pub logged_turns_field: u32,
    pub team_a: Vec<LoggedMon>,
    pub team_b: Vec<LoggedMon>,
    pub turns: Vec<LoggedTurn>,
}

fn paren_addr(s: &str) -> &str {
    let open = s.rfind('(').map(|i| i + 1).unwrap_or(0);
    let close = s.rfind(')').unwrap_or(s.len());
    &s[open..close]
}

fn parse_action(s: &str) -> Option<(LoggedAction, u128)> {
    let mut toks = s.split_whitespace();
    let head = toks.next()?;
    let act = if let Some(t) = head.strip_prefix("SWITCH→") {
        LoggedAction { move_index: SWITCH_MOVE_INDEX, extra_data: t.parse().ok()? }
    } else if head == "NO_OP" {
        LoggedAction { move_index: NO_OP_INDEX, extra_data: 0 }
    } else if let Some(t) = head.strip_prefix("move") {
        let mi: u8 = t.parse().ok()?;
        let x = toks.next()?.strip_prefix('x')?.parse().ok()?;
        LoggedAction { move_index: mi, extra_data: x }
    } else {
        return None;
    };
    let salt = toks.next()?.strip_prefix("salt")?.parse().ok()?;
    Some((act, salt))
}

/// A side's turn text: `mon0 <action>` (singles) or `<action> | <action>` (doubles).
fn parse_side(s: &str) -> Option<(Vec<LoggedAction>, u128)> {
    let mut acts = Vec::new();
    let mut salt = 0u128;
    for lane in s.split(" | ") {
        let lane = lane.trim().strip_prefix("mon0 ").unwrap_or(lane.trim());
        let (a, sl) = parse_action(lane)?;
        acts.push(a);
        salt = sl; // lanes repeat the side's single salt
    }
    Some((acts, salt))
}

fn parse_mon_line(s: &str) -> Option<LoggedMon> {
    let name = s.split_whitespace().next()?.to_string();
    let facet: u8 = s
        .split_whitespace()
        .find_map(|t| t.strip_prefix("facet"))
        .and_then(|t| t.parse().ok())?;
    let inner = &s[s.find("moves[")? + 6..s.rfind(']')?];
    let moves = inner.split(", ").map(|m| m.trim().to_string()).collect();
    Some(LoggedMon { name, facet, moves })
}

pub fn parse_logs(text: &str) -> Vec<LoggedBattle> {
    let mut out: Vec<LoggedBattle> = Vec::new();
    let mut lines = text.lines().peekable();
    while let Some(line) = lines.next() {
        let Some(rest) = line.strip_prefix("Battle 0x") else { continue };
        let key = format!("0x{}", rest.split_whitespace().next().unwrap_or(""));

        let vs = lines.next().unwrap_or("");
        let (a_part, b_part) = vs.split_once("  vs  ").unwrap_or((vs, ""));
        let cpu_side = if a_part.contains("CPU") { 0 } else { 1 };
        let (a_addr, b_addr) = (paren_addr(a_part).to_string(), paren_addr(b_part).to_string());

        let win_line = lines.next().unwrap_or("");
        let win_addr = paren_addr(win_line.split("Turns:").next().unwrap_or("")).to_string();
        let winner_side = if win_addr == a_addr { 0 } else { 1 };
        debug_assert!(win_addr == a_addr || win_addr == b_addr);
        let logged_turns_field: u32 = win_line
            .split("Turns:")
            .nth(1)
            .and_then(|t| t.trim().parse().ok())
            .unwrap_or(0);

        let difficulty = lines
            .next()
            .and_then(|l| l.strip_prefix("CPU difficulty:"))
            .map(|s| s.trim().to_string())
            .unwrap_or_default();

        let mut team_a = Vec::new();
        let mut team_b = Vec::new();
        let mut turns = Vec::new();
        let mut doubles = false;
        let mut current: Option<&mut Vec<LoggedMon>> = None;
        loop {
            let Some(&peeked) = lines.peek() else { break };
            if peeked.starts_with("Battle 0x") {
                break;
            }
            let l = lines.next().unwrap();
            if l.starts_with("Team A:") {
                current = Some(&mut team_a);
            } else if l.starts_with("Team B:") {
                current = Some(&mut team_b);
            } else if l.starts_with('T') && l[1..2].chars().all(|c| c.is_ascii_digit()) {
                let body = l.splitn(2, char::is_whitespace).nth(1).unwrap_or("").trim();
                let body = body.strip_prefix("A ").unwrap_or(body);
                let (a_txt, b_txt) = body.split_once("   B ").unwrap_or((body, ""));
                let (Some((a, a_salt)), Some((b, b_salt))) = (parse_side(a_txt), parse_side(b_txt))
                else {
                    eprintln!("  !! unparseable turn line: {l}");
                    continue;
                };
                doubles = doubles || a.len() == 2;
                turns.push(LoggedTurn { a, b, a_salt, b_salt });
            } else if let Some(m) = parse_mon_line(l) {
                if let Some(team) = current.as_deref_mut() {
                    team.push(m);
                }
            }
        }
        out.push(LoggedBattle {
            key,
            difficulty,
            doubles,
            cpu_side,
            winner_side,
            logged_turns_field,
            team_a,
            team_b,
            turns,
        });
    }
    out
}

// ── Fixture building ────────────────────────────────────────────────────────

/// Facets.sol: facetId 1-12, boost = (id-1)/3, nerf skips the boost group;
/// +5% always, cost 5% (10% when the boost is Speed), floor of BASE stats.
pub fn apply_facet(stats: &mut MonStats, facet_id: u8) {
    if facet_id == 0 || facet_id > 12 {
        return;
    }
    let idx = (facet_id - 1) as u32;
    let boost = idx / 3;
    let off = idx % 3;
    let nerf = if off < boost { off } else { off + 1 };
    let cost_pct = if boost == 3 { 10 } else { 5 };
    let base = stats.clone();
    let mut apply = |group: u32, pct: u32, up: bool| {
        let bump = |s: &mut u32, b: u32| {
            let d = b * pct / 100;
            *s = if up { *s + d } else { *s - d };
        };
        match group {
            0 => bump(&mut stats.hp, base.hp),
            1 => {
                bump(&mut stats.attack, base.attack);
                bump(&mut stats.specialAttack, base.specialAttack);
            }
            2 => {
                bump(&mut stats.defense, base.defense);
                bump(&mut stats.specialDefense, base.specialDefense);
            }
            _ => bump(&mut stats.speed, base.speed),
        }
    };
    apply(boost, 5, true);
    apply(nerf, cost_pct, false);
}

/// Logged team → engine Mons + roster ids; verifies logged move names against
/// the default lanes so a lane-order mismatch fails loudly, not as skew.
fn build_side(roster: &Roster, team: &[LoggedMon], side: &str) -> (Vec<Mon>, Vec<u32>) {
    let mut mons = Vec::new();
    let mut ids = Vec::new();
    for lm in team {
        let rm = roster
            .mons
            .iter()
            .find(|m| m.name == lm.name)
            .unwrap_or_else(|| panic!("unknown mon in log: {}", lm.name));
        for (lane, want) in lm.moves.iter().enumerate() {
            let have = roster.move_name(rm.id, lane as u8);
            assert!(
                have == *want,
                "{side} {}: lane {lane} is {have:?} in the catalog but {want:?} in the log — \
                 non-default loadout, teach build_side to equip lanes first",
                lm.name
            );
        }
        let mut mon = build_team_mon(rm);
        apply_facet(&mut mon.stats, lm.facet);
        mons.push(mon);
        ids.push(rm.id);
    }
    (mons, ids)
}

// ── Replay drivers ──────────────────────────────────────────────────────────

fn mv(a: LoggedAction) -> Mv {
    Mv { move_index: a.move_index, extra_data: a.extra_data }
}

/// Display label for a singles/doubles action of `side`, given its active roster index.
fn label(roster: &Roster, ids: &[u32], active: usize, m: Mv) -> String {
    if m.move_index == SWITCH_MOVE_INDEX {
        let name = ids
            .get(m.extra_data as usize)
            .map(|&id| roster.mon_name(id))
            .unwrap_or_else(|| format!("#{}", m.extra_data));
        format!("switch→{name}")
    } else if m.move_index == NO_OP_INDEX {
        "rest".into()
    } else {
        let base = ids
            .get(active)
            .map(|&id| roster.move_name(id, m.move_index))
            .unwrap_or_else(|| format!("move{}", m.move_index));
        if m.extra_data != 0 {
            format!("{base} x{}", m.extra_data)
        } else {
            base
        }
    }
}

fn hp_pct(cur: i64, max: i64) -> i64 {
    if max <= 0 { 0 } else { (cur.max(0) * 100) / max }
}

pub struct ReplayReport {
    /// (policy label, CPU acting turns compared, turns where it agreed with the log).
    pub agreement: Vec<(String, u32, u32)>,
    pub fidelity_ok: bool,
}

/// Replay a SINGLES battle. Logged side A plays engine p0, B plays p1.
pub fn replay_singles(
    battle: &LoggedBattle,
    roster: &Roster,
    book: &HashMap<String, Address>,
) -> ReplayReport {
    assert_eq!(battle.cpu_side, 1, "replay assumes the CPU is side B (p1)");
    let (p0_team, p0_ids) = build_side(roster, &battle.team_a, "A");
    let (p1_team, p1_ids) = build_side(roster, &battle.team_b, "B");
    let mut sim = Sim::new(4, p0_team, p1_team, p0_ids.clone(), p1_ids.clone(), book);
    let cpu_seat = Seat { cpu: 1 };

    // Candidate policies, each on its own rng stream. The heuristic's
    // move-used bitmap follows ITS OWN picks, not the logged line — a small
    // infidelity that only affects configured-setup availability.
    let mut policies: Vec<(&str, Box<dyn Bot>)> = vec![
        ("heuristic", bots::build(bots::HEURISTIC, singles_cfg(0, false)).unwrap()),
        ("search-d1", bots::build(bots::SEARCH_D1, singles_cfg(1, true)).unwrap()),
        ("search-d2", bots::build(bots::SEARCH_D2, singles_cfg(2, true)).unwrap()),
    ];
    let mut rngs: Vec<_> = (0..policies.len() as u32).map(|i| derive(0xbeef, 100 + i)).collect();
    let mut compared = vec![(0u32, 0u32); policies.len()];
    let mut fidelity_ok = true;

    for (t, turn) in battle.turns.iter().enumerate() {
        if sim.winner_index() != 2 {
            eprintln!("  !! battle ended at engine turn {t} but the log has more lines — DESYNC");
            fidelity_ok = false;
            break;
        }
        let bk = sim.battle_key;
        let ctx0 = Engine::getBattleContext(&mut sim.world, bk);
        let flag = ctx0.playerSwitchForTurnFlag;
        let (p0_acts, p1_acts) = (flag != 1, flag != 0);
        let (a0, a1) = (ctx0.p0ActiveMonIndex as usize, ctx0.p1ActiveMonIndex as usize);

        // Fidelity: a non-acting side must be logged as a salt-0 NO_OP.
        let a_log = turn.a[0];
        let b_log = turn.b[0];
        if !p0_acts && (a_log.move_index != NO_OP_INDEX || turn.a_salt != 0) {
            eprintln!("  !! T{}: engine says p0 doesn't act, log disagrees — DESYNC", t + 1);
            fidelity_ok = false;
        }
        if !p1_acts && b_log.move_index != NO_OP_INDEX {
            eprintln!("  !! T{}: engine says p1 doesn't act, log disagrees — DESYNC", t + 1);
            fidelity_ok = false;
        }

        // Ask each policy for its counterfactual pick (prod peeks the reveal).
        let mut notes = String::new();
        if p1_acts && t > 0 {
            let peek = if p0_acts { Some(mv(a_log)) } else { None };
            for (pi, (name, bot)) in policies.iter_mut().enumerate() {
                let saved_fc = sim.fork_counter();
                let view = capture_view(&mut sim, cpu_seat, bk);
                let pick = {
                    let mut ctx = DecisionCtx {
                        sim: &mut sim,
                        seat: cpu_seat,
                        mode: BattleMode::Singles,
                        view: Some(&view),
                        peek,
                        rng: &mut rngs[pi],
                    };
                    bot.decide(&mut ctx).single()
                };
                sim.set_fork_counter(saved_fc);
                compared[pi].0 += 1;
                if (pick.move_index, pick.extra_data) == (b_log.move_index, b_log.extra_data) {
                    compared[pi].1 += 1;
                } else {
                    notes.push_str(&format!("  {name}→{}", label(roster, &p1_ids, a1, pick)));
                }
            }
        }

        let p0hp = hp_pct(
            mon_current_hp(&mut sim, cpu_seat, bk, VOPP, a0),
            mon_max_hp(&mut sim, cpu_seat, bk, VOPP, a0),
        );
        let p1hp = hp_pct(
            mon_current_hp(&mut sim, cpu_seat, bk, VCPU, a1),
            mon_max_hp(&mut sim, cpu_seat, bk, VCPU, a1),
        );
        let dump = if std::env::var("REPLAY_DUMP").is_ok() {
            let s0 = mon_current_stamina(&mut sim, cpu_seat, bk, VOPP, a0);
            let s1 = mon_current_stamina(&mut sim, cpu_seat, bk, VCPU, a1);
            let k0 = mon_skip_turn(&mut sim, cpu_seat, bk, VOPP, a0);
            let k1 = mon_skip_turn(&mut sim, cpu_seat, bk, VCPU, a1);
            let h0 = mon_current_hp(&mut sim, cpu_seat, bk, VOPP, a0);
            let h1 = mon_current_hp(&mut sim, cpu_seat, bk, VCPU, a1);
            format!("  [flag {flag} | p0 hp{h0} st{s0} skip{k0} | p1 hp{h1} st{s1} skip{k1}]")
        } else {
            String::new()
        };
        println!(
            "T{:<3} {:>9}({p0hp:>3}%) {:<24}| CPU {:>9}({p1hp:>3}%) {:<24}{notes}{dump}",
            t + 1,
            roster.mon_name(p0_ids[a0]),
            if p0_acts { label(roster, &p0_ids, a0, mv(a_log)) } else { "—".into() },
            roster.mon_name(p1_ids[a1]),
            if p1_acts { label(roster, &p1_ids, a1, mv(b_log)) } else { "—".into() },
        );

        for (side, act, phys) in [("p0", a_log, p0_acts), ("p1", b_log, p1_acts)] {
            if phys
                && !sim.validate_move(
                    bk,
                    if side == "p0" { U256::ZERO } else { U256::from(1u64) },
                    act.move_index,
                    act.extra_data,
                )
            {
                eprintln!("  !! T{}: logged {side} move invalid in replay state — DESYNC", t + 1);
                fidelity_ok = false;
            }
        }

        sim.execute_turn(
            if p0_acts { a_log.move_index } else { NO_OP_INDEX },
            if p0_acts { turn.a_salt } else { 0 },
            if p0_acts { a_log.extra_data } else { 0 },
            if p1_acts { b_log.move_index } else { NO_OP_INDEX },
            0, // the on-chain CPU relayer always submits salt 0
            if p1_acts { b_log.extra_data } else { 0 },
        );
    }

    finish(&mut sim, battle, compared, &policies.iter().map(|(n, _)| n.to_string()).collect::<Vec<_>>(), fidelity_ok)
}

fn singles_cfg(depth: u32, peek: bool) -> BotConfig {
    BotConfig {
        doubles_eval: DoublesEvalW::default(),
        weights: env_weights().unwrap_or(DEFAULT_WEIGHTS),
        search_depth: depth,
        search_peek: peek,
        search_mixed: false,
    }
}

/// REPLAY_WEIGHTS="1,150,..." swaps candidate eval weights into every queried
/// policy — the counterfactual side of the loss-replay regression gate.
fn env_weights() -> Option<Weights> {
    let s = std::env::var("REPLAY_WEIGHTS").ok()?;
    let vals: Vec<f64> = s.split(',').filter_map(|x| x.trim().parse().ok()).collect();
    if vals.len() != N_FEATURES {
        eprintln!("  !! REPLAY_WEIGHTS ignored: expected {N_FEATURES} comma-separated floats");
        return None;
    }
    let mut w = [0.0f64; N_FEATURES];
    w.copy_from_slice(&vals);
    Some(w)
}

/// Replay a DOUBLES battle (CPU = side B = p1, lanes at absolute slots 2/3).
pub fn replay_doubles(
    battle: &LoggedBattle,
    roster: &Roster,
    book: &HashMap<String, Address>,
) -> ReplayReport {
    assert_eq!(battle.cpu_side, 1, "replay assumes the CPU is side B (p1)");
    let (p0_team, p0_ids) = build_side(roster, &battle.team_a, "A");
    let (p1_team, p1_ids) = build_side(roster, &battle.team_b, "B");
    let mut sim = Sim::new_doubles(4, p0_team, p1_team, p0_ids.clone(), p1_ids.clone(), book);
    let cpu_seat = Seat { cpu: 1 };

    let names = ["slot-greedy", "search-d1", "search-d2"];
    let mut grng = derive(0xbeef, 200);
    let eval = DoublesEvalW::default();
    let mut compared = vec![(0u32, 0u32); names.len()];
    let (mut bm_d1, mut bm_d2) = (0u32, 0u32);
    let mut fidelity_ok = true;

    for (t, turn) in battle.turns.iter().enumerate() {
        if sim.winner_index() != 2 {
            eprintln!("  !! battle ended at engine turn {t} but the log has more lines — DESYNC");
            fidelity_ok = false;
            break;
        }
        let bk = sim.battle_key;
        let flag = Engine::getBattleContext(&mut sim.world, bk).playerSwitchForTurnFlag as u32;
        let cpu_acts = flag == 2 || (flag & 0b1100) != 0;

        let raw = Engine::getActiveSlots(&mut sim.world, bk);
        let lane_mon = |abs: usize| u64::try_from(raw[abs]).unwrap_or(0xFF) as usize;
        let lane_label = |ids: &[u32], abs: usize, a: LoggedAction| {
            let active = lane_mon(abs);
            if active == 0xFF && a.move_index == NO_OP_INDEX {
                "—".to_string()
            } else {
                label(roster, ids, active.min(3), mv(a))
            }
        };

        let logged: [SlotMove; 2] = [
            SlotMove { move_index: turn.b[0].move_index, extra_data: turn.b[0].extra_data },
            SlotMove { move_index: turn.b[1].move_index, extra_data: turn.b[1].extra_data },
        ];
        let mut notes = String::new();
        if cpu_acts && t > 0 {
            let picks: [(usize, (SlotMove, SlotMove)); 3] = [
                (0, doubles::pick_side_moves(&mut sim, bk, 1, Difficulty::Hard, &mut grng)),
                (1, doubles::search_side_moves(&mut sim, bk, 1, 1, &eval, &mut bm_d1)),
                (2, doubles::search_side_moves(&mut sim, bk, 1, 2, &eval, &mut bm_d2)),
            ];
            for (pi, (s0, s1)) in picks {
                compared[pi].0 += 1;
                let agree = (s0.move_index, s0.extra_data, s1.move_index, s1.extra_data)
                    == (logged[0].move_index, logged[0].extra_data, logged[1].move_index, logged[1].extra_data);
                if agree {
                    compared[pi].1 += 1;
                } else {
                    let m0 = LoggedAction { move_index: s0.move_index, extra_data: s0.extra_data };
                    let m1 = LoggedAction { move_index: s1.move_index, extra_data: s1.extra_data };
                    notes.push_str(&format!(
                        "  {}→[{}, {}]",
                        names[pi],
                        lane_label(&p1_ids, 2, m0),
                        lane_label(&p1_ids, 3, m1)
                    ));
                }
            }
        }

        let side_hp = |sim: &mut Sim, vp: u8, ids: &[u32]| -> String {
            (0..4)
                .map(|i| {
                    let pct = hp_pct(
                        mon_current_hp(sim, cpu_seat, bk, vp, i),
                        mon_max_hp(sim, cpu_seat, bk, vp, i),
                    );
                    format!("{}:{pct}%", roster.mon_name(ids[i]))
                })
                .collect::<Vec<_>>()
                .join(" ")
        };
        println!(
            "T{:<3} A[{}, {}]  B[{}, {}]{notes}\n     A {}   B {}",
            t + 1,
            lane_label(&p0_ids, 0, turn.a[0]),
            lane_label(&p0_ids, 1, turn.a[1]),
            lane_label(&p1_ids, 2, turn.b[0]),
            lane_label(&p1_ids, 3, turn.b[1]),
            side_hp(&mut sim, VOPP, &p0_ids),
            side_hp(&mut sim, VCPU, &p1_ids),
        );

        sim.execute_slot_turn(
            pack_side(
                turn.a[0].move_index,
                turn.a[0].extra_data,
                turn.a[1].move_index,
                turn.a[1].extra_data,
                turn.a_salt,
            ),
            pack_side(
                turn.b[0].move_index,
                turn.b[0].extra_data,
                turn.b[1].move_index,
                turn.b[1].extra_data,
                0,
            ),
        );
    }

    finish(&mut sim, battle, compared, &names.iter().map(|s| s.to_string()).collect::<Vec<_>>(), fidelity_ok)
}

fn finish(
    sim: &mut Sim,
    battle: &LoggedBattle,
    compared: Vec<(u32, u32)>,
    names: &[String],
    mut fidelity_ok: bool,
) -> ReplayReport {
    let w = sim.winner_index();
    let expect = battle.winner_side;
    if w == 2 {
        println!("== replay: battle still running after all logged turns (log says side {expect} won) — DESYNC");
        fidelity_ok = false;
    } else if w != expect {
        println!("== replay winner p{w} ≠ logged winner side {expect} — DESYNC");
        fidelity_ok = false;
    } else {
        println!("== replay winner p{w} matches the log ({} logged turns) ==", battle.turns.len());
    }
    let agreement = names
        .iter()
        .zip(compared)
        .map(|(n, (total, agree))| (n.clone(), total, agree))
        .collect::<Vec<_>>();
    for (n, total, agree) in &agreement {
        println!("   {n:<12} agreed {agree}/{total} CPU turns");
    }
    ReplayReport { agreement, fidelity_ok }
}
