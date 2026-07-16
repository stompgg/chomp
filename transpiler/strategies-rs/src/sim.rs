//! Native battle harness — the ONE place that knows how to stand up a
//! world, execute turns, and fork hypothetical turns. `chomp-ffi`
//! delegates here for its handle API; the batch game runner drives it
//! directly. Semantics mirror the TS harness exactly:
//!
//!  - transient storage resets at every tx boundary (the TS runtime's
//!    depth-0→1 reset) — before validation/reads AND after execution;
//!  - hypothetical turns replicate `Engine.executeWithMoves` minus the
//!    moveManager gate: `_setMoveInternal` + the `_turnP*Packed`
//!    transients for acting sides only, then `_executeInternal` on a
//!    cloned fork of the battle's storage (forward-model.ts semantics);
//!  - the fork's storage key EQUALS the fork key (no redirect), so every
//!    engine reader resolves the fork at `battleConfig[forkKey]`.

use std::collections::HashMap;

use chomp_engine::world::{deploy_all, ExternalCalls, World};
use chomp_engine::Structs::{Battle, Mon};
use chomp_engine::{Constants, Engine};
use chomp_rt::{Address, B256, U256};

pub const P0: Address = addr(0x01);
pub const P1: Address = addr(0x02);
pub const MATCHMAKER: Address = addr(0xcafe);
pub const MOVE_MANAGER: Address = addr(0xbeef);
pub const TEAM_REGISTRY: Address = addr(0xa55e);
pub const ENGINE_ADDR: Address = addr(0xe7);

const fn addr(low: u16) -> Address {
    let mut b = [0u8; 20];
    b[18] = (low >> 8) as u8;
    b[19] = (low & 0xff) as u8;
    Address::new(b)
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

    fn ITeamRegistry_isWhitelistedOpponent(&mut self, _t: Address, _addr: Address) -> bool {
        false // the arena pits two real teams — no phantom/CPU whitelist path
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

/// A hypothetical (or real) move submission for one side of a turn.
#[derive(Clone, Copy, Debug)]
pub struct HypoMove {
    pub move_index: u8,
    pub salt: u128,
    pub extra_data: u16,
}

/// One live battle: a world + its battle key. Fork keys created by
/// `apply_hypothetical` stay resident (readable like any battle key)
/// until `dispose_fork`.
pub struct Sim {
    pub world: World,
    pub battle_key: B256,
    pub engine_addr: Address,
    /// (p0, p1) team sizes, immutable after `startBattle` — cached because
    /// the transpiled `getTeamSize` getter deep-clones the whole
    /// BattleConfig per call, and view captures read sizes per fork.
    team_sizes: (usize, usize),
    /// (p0, p1) global mon-ids per team slot — carried from the drafted teams
    /// so the CPU can look up per-mon config by identity (the engine only
    /// tracks slots). Empty when the caller doesn't supply ids (config is inert).
    team_ids: (Vec<u32>, Vec<u32>),
    /// BATTLE_MODE_SINGLES/DOUBLES/MULTI — drives execute_turn vs execute_slot_turn.
    pub battle_mode: u8,
    /// Per-battle fork counter (keys are map identities scoped to THIS
    /// world, so no cross-Sim coordination is needed).
    fork_counter: u64,
}

/// executeWithMoves's transient packing (Engine.sol): storedIndex offset
/// for real move slots, IS_REAL_TURN_BIT, extraData in bits 8+, salt via
/// `_packTurn`.
pub fn pack_turn(mi: u8, salt: u128, extra: u16) -> U256 {
    let stored = if mi < Constants::SWITCH_MOVE_INDEX { mi + Constants::MOVE_INDEX_OFFSET } else { mi };
    let encoded = U256::from(stored as u16 | Constants::IS_REAL_TURN_BIT as u16)
        | (U256::from(extra) << 8);
    Engine::_packTurn(encoded, salt)
}

/// Build a side's raw slot-turn word for `executeWithSlotMoves`: slot-0 = (move `m0`, extraData `e0`)
/// in bits 0-23, slot-1 = (`m1`, `e1`) in bits 24-47, `salt` in bits 48-151. extraData carries the
/// target in bits 12-15 (`TARGET_BITS_SHIFT`). The engine's `_packSideTurn` re-encodes this raw form
/// into its internal `_turnP*Packed` layout (adding the move-index offset + real-turn bit).
pub fn pack_side(m0: u8, e0: u16, m1: u8, e1: u16, salt: u128) -> U256 {
    U256::from(m0)
        | (U256::from(e0) << 8)
        | (U256::from(m1) << 24)
        | (U256::from(e1) << 32)
        | (U256::from(salt) << 48)
}

impl Sim {
    /// Stand up a SINGLES battle world. `book` maps contract names to addresses
    /// (the arena's exported address book); when empty, no contracts are
    /// deployed (inline-only battles). The rng oracle is always zero —
    /// the engine's inline keccak(p0Salt, p1Salt) path.
    pub fn new(
        mons_per_team: u64,
        p0_team: Vec<Mon>,
        p1_team: Vec<Mon>,
        p0_ids: Vec<u32>,
        p1_ids: Vec<u32>,
        book: &HashMap<String, Address>,
    ) -> Sim {
        Self::new_with_mode(mons_per_team, p0_team, p1_team, p0_ids, p1_ids, book, Constants::BATTLE_MODE_SINGLES)
    }

    /// Stand up a DOUBLES battle world — two active mons per side (absolute slots 0-3), executed via
    /// packed slot moves (`execute_slot_turn`) instead of `execute_turn`.
    pub fn new_doubles(
        mons_per_team: u64,
        p0_team: Vec<Mon>,
        p1_team: Vec<Mon>,
        p0_ids: Vec<u32>,
        p1_ids: Vec<u32>,
        book: &HashMap<String, Address>,
    ) -> Sim {
        Self::new_with_mode(mons_per_team, p0_team, p1_team, p0_ids, p1_ids, book, Constants::BATTLE_MODE_DOUBLES)
    }

    fn new_with_mode(
        mons_per_team: u64,
        p0_team: Vec<Mon>,
        p1_team: Vec<Mon>,
        p0_ids: Vec<u32>,
        p1_ids: Vec<u32>,
        book: &HashMap<String, Address>,
        battle_mode: u8,
    ) -> Sim {
        let mut world = World::new(Box::new(HarnessExt {
            p0_team,
            p1_team,
        }));
        world.Engine = Engine::construct(
            U256::from(mons_per_team),
            Constants::GAME_MOVES_PER_MON,
        );

        let engine_addr = book.get("Engine").copied().unwrap_or(ENGINE_ADDR);
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
            // Multi seats: unused in the singles arena (startBattle keeps singles mode when p2==p3==0).
            p2: Address::ZERO,
            p2TeamIndex: 0,
            p3: Address::ZERO,
            p3TeamIndex: 0,
            teamRegistry: TEAM_REGISTRY,
            rngOracle: Address::ZERO,
            ruleset: Constants::INLINE_STAMINA_REGEN_RULESET,
            moveManager: MOVE_MANAGER,
            matchmaker: MATCHMAKER,
            engineHooks: Vec::new(),
        };
        world.env.msg_sender = MATCHMAKER;
        Engine::startBattleWithMode(&mut world, &mut battle, battle_mode);
        world.reset_transient(); // startBattle's tx is over; reads start boundary-clean
        let sk = Engine::_getStorageKey(&mut world, battle_key);
        let ts = world.Engine.battleConfig.get_mut(&sk).teamSizes;
        let team_sizes = ((ts & 0x0f) as usize, (ts >> 4) as usize);
        Sim { world, battle_key, engine_addr, team_sizes, team_ids: (p0_ids, p1_ids), battle_mode, fork_counter: 0 }
    }

    /// winnerIndex off the live battle data (2 = battle still running).
    pub fn winner_index(&mut self) -> u8 {
        self.world.Engine.battleData.get(&self.battle_key).winnerIndex
    }

    /// Team size for a PHYSICAL player index (same on every fork — sizes
    /// never change after battle start).
    pub fn team_size_phys(&self, phys: U256) -> usize {
        if phys == U256::ZERO {
            self.team_sizes.0
        } else {
            self.team_sizes.1
        }
    }

    /// Global mon-id at `slot` for a PHYSICAL player index (0 when no ids were
    /// supplied — config lookups then fall through to unset, i.e. no per-mon move).
    pub fn mon_id_phys(&self, phys: U256, slot: usize) -> u32 {
        let ids = if phys == U256::ZERO { &self.team_ids.0 } else { &self.team_ids.1 };
        ids.get(slot).copied().unwrap_or(0)
    }

    /// Fork counter snapshot/restore — lets a throwaway counterfactual decision (which forks then
    /// disposes) leave the counter exactly where the live decision expects it. Keys are unique by
    /// construction, so this is belt-and-suspenders; it keeps a narrated game bit-identical.
    pub fn fork_counter(&self) -> u64 {
        self.fork_counter
    }
    pub fn set_fork_counter(&mut self, v: u64) {
        self.fork_counter = v;
    }

    /// Engine-side legality check at a fresh-tx boundary. Every TS
    /// top-level call resets transient storage; owning that reset here
    /// keeps validate reads boundary-clean for the FFI and the native
    /// game loop alike.
    pub fn validate_move(&mut self, bk: B256, phys_player: U256, move_index: u8, extra_data: u16) -> bool {
        self.world.reset_transient();
        Engine::validatePlayerMoveForBattle(
            &mut self.world,
            bk,
            U256::from(move_index as u64),
            phys_player,
            extra_data,
        )
    }


    /// Execute one real turn (both submissions), like the TS harness's
    /// `executeTurn`: fresh-tx boundary, +1s block time, moveManager sender.
    pub fn execute_turn(
        &mut self,
        p0_mi: u8,
        p0_salt: u128,
        p0_extra: u16,
        p1_mi: u8,
        p1_salt: u128,
        p1_extra: u16,
    ) {
        let key = self.battle_key;
        let world = &mut self.world;
        world.reset_transient();
        world.env.block_timestamp = world.env.block_timestamp + U256::from(1u64);
        world.env.msg_sender = MOVE_MANAGER;
        Engine::executeWithMoves(world, key, p0_mi, p0_salt, p0_extra, p1_mi, p1_salt, p1_extra);
        world.reset_transient(); // tx over; subsequent reads are boundary-clean
    }

    /// Execute one DOUBLES turn from each side's packed slot word (see [`pack_side`]) — the doubles
    /// analogue of `execute_turn`, driving `executeWithSlotMoves`.
    pub fn execute_slot_turn(&mut self, side0_packed: U256, side1_packed: U256) {
        let key = self.battle_key;
        let world = &mut self.world;
        world.reset_transient();
        world.env.block_timestamp = world.env.block_timestamp + U256::from(1u64);
        world.env.msg_sender = MOVE_MANAGER;
        Engine::executeWithSlotMoves(world, key, side0_packed, side1_packed);
        world.reset_transient();
    }

    /// Fork key: tag nibbles + counter — can never collide with a real
    /// keccak battle key in practice (mirrors the TS forward-model's scheme).
    fn next_fork_key(&mut self) -> B256 {
        self.fork_counter += 1;
        let mut b = [0u8; 32];
        b[0] = 0xf0;
        b[1] = 0xfc;
        b[24..32].copy_from_slice(&self.fork_counter.to_be_bytes());
        B256::new(b)
    }

    /// Clone the battle state tree at `src` under a fresh fork key (battleData +
    /// battleConfig — which carries per-mon + global effects — + the globalKV
    /// entries holding move locks / once-per-game flags). `src` may be the live
    /// key or another fork (depth search); forks have no storage-key redirect
    /// (`_getStorageKey(fork) == fork`), so this nests correctly.
    fn fork_battle_from(&mut self, src: B256) -> B256 {
        let fork = self.next_fork_key();
        let world = &mut self.world;
        let sk = Engine::_getStorageKey(world, src);
        let data = world.Engine.battleData.get(&src);
        world.Engine.battleData.set(fork, data);
        let cfg = world.Engine.battleConfig.get(&sk);
        world.Engine.battleConfig.set(fork, cfg);
        let kv = world.Engine.globalKV.get(&sk);
        world.Engine.globalKV.set(fork, kv);
        let slots = world.Engine.globalKVKeySlots.get(&sk);
        world.Engine.globalKVKeySlots.set(fork, slots);
        fork
    }

    /// Fork `src`, run ONE silent hypothetical turn on the fork (either side may
    /// be None on a forced-switch turn), return the fork key. PHYSICAL p0/p1 —
    /// seat translation happens in the caller. `src` = live key (1-ply) or a
    /// fork key (deeper plies in the search tree).
    pub fn apply_hypothetical_from(&mut self, src: B256, p0: Option<HypoMove>, p1: Option<HypoMove>) -> B256 {
        let fork = self.fork_battle_from(src);
        let world = &mut self.world;
        world.reset_transient();
        world.env.msg_sender = world.Engine.battleConfig.get_mut(&fork).moveManager;
        if let Some(m) = p0 {
            Engine::_setMoveInternal(
                world.Engine.battleConfig.get_mut(&fork),
                U256::ZERO,
                m.move_index,
                m.salt,
                m.extra_data,
            );
            world.Engine._turnP0Packed = pack_turn(m.move_index, m.salt, m.extra_data);
        }
        if let Some(m) = p1 {
            Engine::_setMoveInternal(
                world.Engine.battleConfig.get_mut(&fork),
                U256::from(1u64),
                m.move_index,
                m.salt,
                m.extra_data,
            );
            world.Engine._turnP1Packed = pack_turn(m.move_index, m.salt, m.extra_data);
        }
        world.Engine.storageKeyForWrite = fork;
        world.Engine.battleKeyForWrite = fork; // write-gates (addEffect etc.) check this transient
        Engine::_executeInternal(world, fork, fork, false, false, false); // slotPacked=false (singles)
        world.reset_transient(); // fork tx over; capture reads boundary-clean
        fork
    }

    /// 1-ply hypothetical from the LIVE battle (the common case).
    pub fn apply_hypothetical(&mut self, p0: Option<HypoMove>, p1: Option<HypoMove>) -> B256 {
        let src = self.battle_key;
        self.apply_hypothetical_from(src, p0, p1)
    }

    /// DOUBLES analogue of [`apply_hypothetical_from`]: fork `src`, run ONE silent slot-turn
    /// from each side's packed word (see [`pack_side`]), return the fork key. Mirrors
    /// `executeWithSlotMoves` (turns come from `_packSideTurn` + `slotPacked=true`); `src` may be
    /// the live key or a fork (depth search).
    pub fn apply_hypothetical_slot(&mut self, src: B256, side0_packed: U256, side1_packed: U256) -> B256 {
        let fork = self.fork_battle_from(src);
        let world = &mut self.world;
        world.reset_transient();
        world.env.msg_sender = world.Engine.battleConfig.get_mut(&fork).moveManager;
        world.Engine._turnP0Packed = Engine::_packSideTurn(side0_packed);
        world.Engine._turnP1Packed = Engine::_packSideTurn(side1_packed);
        world.Engine.storageKeyForWrite = fork;
        world.Engine.battleKeyForWrite = fork; // write-gates (addEffect etc.) check this transient
        Engine::_executeInternal(world, fork, fork, false, false, true); // slotPacked=true, silent
        world.reset_transient();
        fork
    }

    /// Reclaim a fork's cloned state.
    pub fn dispose_fork(&mut self, fork: B256) {
        self.world.Engine.battleData.remove(&fork);
        self.world.Engine.battleConfig.remove(&fork);
        self.world.Engine.globalKV.remove(&fork);
        self.world.Engine.globalKVKeySlots.remove(&fork);
    }
}

#[cfg(test)]
mod doubles_seam_tests {
    use super::*;
    use crate::arena::build_team_mon;
    use crate::roster::load_roster;

    const SWITCH: u8 = 125;

    /// A doubles battle stands up and executes packed slot turns without panicking, and the engine
    /// stays in a valid state (winner_index ∈ {0,1,2}). Validates new_doubles + execute_slot_turn +
    /// pack_side against the transpiled `executeWithSlotMoves` path.
    #[test]
    fn doubles_battle_starts_and_runs_slot_turns() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..").join("..");
        let roster = load_roster(&root);
        let book = crate::roster::address_book();
        let team = |ids: &[u32]| ids.iter().map(|&id| build_team_mon(roster.mon_by_id(id).unwrap())).collect::<Vec<_>>();
        let p0_ids: Vec<u32> = roster.mons.iter().take(4).map(|m| m.id).collect();
        let p1_ids: Vec<u32> = roster.mons.iter().skip(4).take(4).map(|m| m.id).collect();

        let mut sim = Sim::new_doubles(4, team(&p0_ids), team(&p1_ids), p0_ids.clone(), p1_ids.clone(), &book);
        assert_eq!(sim.battle_mode, Constants::BATTLE_MODE_DOUBLES);
        assert_eq!(sim.winner_index(), 2, "battle ongoing at start");

        // Turn 0: each side places two leads — slot 0 → team member 0, slot 1 → team member 1.
        let lead = pack_side(SWITCH, 0, SWITCH, 1, 111);
        sim.execute_slot_turn(lead, lead);
        assert!(sim.winner_index() <= 2);

        // A few attack turns: both active slots use move 0 (target nibble 0 = first enemy slot).
        for t in 0..8u128 {
            if sim.winner_index() != 2 {
                break;
            }
            let atk = pack_side(0, 0, 0, 0, t + 1);
            sim.execute_slot_turn(atk, atk);
        }
        assert!(sim.winner_index() <= 2, "engine stayed in a valid state");
    }
}
