//! Face-off extractor — measure.md's "behavioral half" of the wall/check matrix. Segments a traced
//! game into face-offs (maximal spans where the same two mons stand across each other) and records
//! who leaves first and how (KO / forced or voluntary switch). This is what catches "some other
//! method" walls — the sleep-and-drain / stamina-denial patterns that never show up as raw KOs
//! (e.g. Xmon walls Malalien), de-confounded from teammates.

use std::collections::HashMap;

use crate::arena::build_specs;
use crate::game::{run_games_traced, TraceRecord};
use crate::roster::{self, Roster};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LeftBy {
    P0Ko,
    P0Switch,
    P1Ko,
    P1Switch,
    Both,
    Cap,
}

pub struct FaceOff {
    pub p0_id: u32,
    pub p1_id: u32,
    pub turns: u32,
    pub p0_dmg: i64, // HP p0's mon removed from p1's mon over the span
    pub p1_dmg: i64,
    pub left: LeftBy,
}

/// Walk the trace rows, cutting a face-off each time either active slot changes. The reason the
/// span ended is read from the boundary: a KO bit set on the last row means that side was KOed;
/// an active change without the KO bit means it switched (forced or voluntary).
pub fn extract_faceoffs(rec: &TraceRecord) -> Vec<FaceOff> {
    let rows = &rec.rows;
    let mut out = Vec::new();
    if rows.is_empty() {
        return out;
    }
    let mut start = 0usize;
    for k in 0..rows.len() {
        let is_last = k + 1 == rows.len();
        let boundary = is_last
            || rows[k + 1].p0_active != rows[start].p0_active
            || rows[k + 1].p1_active != rows[start].p1_active;
        if !boundary {
            continue;
        }

        let first = &rows[start];
        let last = &rows[k];
        let p0_slot = first.p0_active as usize;
        let p1_slot = first.p1_active as usize;

        let mut p0_dmg = 0i64;
        let mut p1_dmg = 0i64;
        for r in &rows[start..=k] {
            p0_dmg += r.p0_dmg_out as i64;
            p1_dmg += r.p1_dmg_out as i64;
        }

        let p0_ko = last.p0_ko & (1u32 << p0_slot) != 0;
        let p1_ko = last.p1_ko & (1u32 << p1_slot) != 0;
        let (p0_left, p1_left) = if is_last {
            (p0_ko, p1_ko) // at game end, a side "left" only if it was KOed
        } else {
            (rows[k + 1].p0_active != first.p0_active, rows[k + 1].p1_active != first.p1_active)
        };
        let left = match (p0_left, p1_left) {
            (true, true) => LeftBy::Both,
            (true, false) => if p0_ko { LeftBy::P0Ko } else { LeftBy::P0Switch },
            (false, true) => if p1_ko { LeftBy::P1Ko } else { LeftBy::P1Switch },
            (false, false) => LeftBy::Cap,
        };

        out.push(FaceOff {
            p0_id: rec.p0_ids[p0_slot],
            p1_id: rec.p1_ids[p1_slot],
            turns: (k - start + 1) as u32,
            p0_dmg,
            p1_dmg,
            left,
        });
        start = k + 1;
    }
    out
}

pub struct FaceOffMatrix {
    /// leaves_first[(mon, opp)] = # face-offs where `mon` left first against `opp`.
    pub leaves_first: HashMap<(u32, u32), u32>,
    /// total[(a, b)] = # face-offs between a and b (stored symmetrically).
    pub total: HashMap<(u32, u32), u32>,
    pub faceoffs: u64,
    pub errors: u32,
}

impl FaceOffMatrix {
    /// Fraction of `mon`-vs-`opp` face-offs in which `mon` left first. None if they never met.
    pub fn leave_rate(&self, mon: u32, opp: u32) -> Option<f64> {
        let t = *self.total.get(&(mon, opp))?;
        if t == 0 {
            return None;
        }
        Some(*self.leaves_first.get(&(mon, opp)).unwrap_or(&0) as f64 / t as f64)
    }
}

pub fn run_faceoff_analysis(roster: &Roster, games: usize, wseed: u32, seed_base: u32, threads: usize) -> FaceOffMatrix {
    let book = roster::address_book();
    let (specs, _) = build_specs(roster, games, wseed, seed_base);
    let recs = run_games_traced(&specs, &book, threads);

    let mut leaves_first: HashMap<(u32, u32), u32> = HashMap::new();
    let mut total: HashMap<(u32, u32), u32> = HashMap::new();
    let (mut count, mut errors) = (0u64, 0u32);

    for r in &recs {
        let rec = match r {
            Ok(x) => x,
            Err(_) => {
                errors += 1;
                continue;
            }
        };
        for fo in extract_faceoffs(rec) {
            count += 1;
            let (a, b) = (fo.p0_id, fo.p1_id);
            *total.entry((a, b)).or_insert(0) += 1;
            *total.entry((b, a)).or_insert(0) += 1;
            match fo.left {
                LeftBy::P0Ko | LeftBy::P0Switch => *leaves_first.entry((a, b)).or_insert(0) += 1,
                LeftBy::P1Ko | LeftBy::P1Switch => *leaves_first.entry((b, a)).or_insert(0) += 1,
                LeftBy::Both | LeftBy::Cap => {}
            }
        }
    }

    FaceOffMatrix { leaves_first, total, faceoffs: count, errors }
}
