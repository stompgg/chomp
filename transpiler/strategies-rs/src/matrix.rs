//! Static damage-to-KO matrix — measure.md's "static half" of the wall/check matrix, computed
//! straight off the damage math for every ordered mon pair (default loadout, no boosts, no crit,
//! no volatility). Supplementary to the 4v4 signal, never a verdict on its own [ruled 2026-07-08].
//!
//! For each ordered pair (A attacks B) we take A's best deterministic damaging move against B and
//! the resulting move-turns-to-KO. The ruled definitions then fall out:
//!   - A *checks* B: A OHKO/2HKOs B (≤2 turns) AND out-damages B.
//!   - B *walls* A: A needs ≥3 moves to KO B AND B out-damages A.

use chomp_engine::Enums::MoveClass;
use chomp_rt::B256;

use crate::arena::build_team_mon;
use crate::roster::{self, Roster};
use crate::shared::{build_damage_calc_context, estimate_damage};
use crate::sim::Sim;
use crate::view::{mon_max_hp, move_slot, slot_move_class, Seat, VCPU, VOPP};

pub const INF_TURNS: u32 = u32::MAX;

pub struct StaticMatrix {
    pub ids: Vec<u32>,
    /// best_damage[i][j] = best deterministic damage mon i deals mon j (default loadout).
    pub best_damage: Vec<Vec<i64>>,
    /// turns_to_ko[i][j] = ceil(maxHp[j] / best_damage[i][j]); INF_TURNS if i can't damage j.
    pub turns_to_ko: Vec<Vec<u32>>,
    pub max_hp: Vec<i64>,
}

impl StaticMatrix {
    pub fn n(&self) -> usize {
        self.ids.len()
    }

    /// Mons that `i` checks: OHKO/2HKO while out-damaging.
    pub fn checks(&self, i: usize) -> Vec<usize> {
        (0..self.n())
            .filter(|&j| j != i && self.turns_to_ko[i][j] <= 2 && self.best_damage[i][j] > self.best_damage[j][i])
            .collect()
    }

    /// Mons that wall `i`: i needs ≥3 moves to KO them AND they out-damage i.
    pub fn walled_by(&self, i: usize) -> Vec<usize> {
        (0..self.n())
            .filter(|&j| j != i && self.turns_to_ko[i][j] >= 3 && self.best_damage[j][i] > self.best_damage[i][j])
            .collect()
    }
}

/// Build a fresh 1v1 sim per ordered pair (no boosts at turn 0 → base-stat damage) and read the
/// best damaging move each direction. ~n² tiny sims; n=13 is a few hundred, well under a second.
pub fn compute_static_matrix(roster: &Roster) -> StaticMatrix {
    let book = roster::address_book();
    let ids: Vec<u32> = roster.mons.iter().map(|m| m.id).collect();
    let n = ids.len();
    let obs = Seat { cpu: 1 };

    let mut best_damage = vec![vec![0i64; n]; n];
    let mut turns_to_ko = vec![vec![INF_TURNS; n]; n];
    let mut max_hp = vec![0i64; n];

    for i in 0..n {
        for j in 0..n {
            if i == j {
                continue;
            }
            // Attacker i = p0 (VOPP slot 0), defender j = p1 (VCPU slot 0).
            let mut sim = Sim::new(
                1,
                vec![build_team_mon(&roster.mons[i])],
                vec![build_team_mon(&roster.mons[j])],
                vec![ids[i]],
                vec![ids[j]],
                &book,
            );
            let bk: B256 = sim.battle_key;
            let hp_j = mon_max_hp(&mut sim, obs, bk, VCPU, 0);
            if max_hp[j] == 0 {
                max_hp[j] = hp_j;
            }

            let mut ctx = build_damage_calc_context(&mut sim, obs, bk, VOPP, 0, VCPU, 0);
            let mut best = 0i64;
            for mi in 0..4usize {
                if let Some(slot) = move_slot(&mut sim, obs, bk, VOPP, 0, mi) {
                    let mc = slot_move_class(&mut sim, bk, slot);
                    if mc == MoveClass::Physical || mc == MoveClass::Special {
                        let d = estimate_damage(&mut sim, bk, &mut ctx, slot, mc);
                        if d > best {
                            best = d;
                        }
                    }
                }
            }
            best_damage[i][j] = best;
            turns_to_ko[i][j] = if best <= 0 { INF_TURNS } else { ((hp_j + best - 1) / best) as u32 };
        }
    }

    StaticMatrix { ids, best_damage, turns_to_ko, max_hp }
}
