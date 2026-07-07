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

impl Sim {
    /// Stand up a battle world. `book` maps contract names to addresses
    /// (the arena's exported address book); when empty, no contracts are
    /// deployed (inline-only battles). The rng oracle is always zero —
    /// the engine's inline keccak(p0Salt, p1Salt) path.
    pub fn new(
        mons_per_team: u64,
        p0_team: Vec<Mon>,
        p1_team: Vec<Mon>,
        book: &HashMap<String, Address>,
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
            teamRegistry: TEAM_REGISTRY,
            validator: Address::ZERO,
            rngOracle: Address::ZERO,
            ruleset: Constants::INLINE_STAMINA_REGEN_RULESET,
            moveManager: MOVE_MANAGER,
            matchmaker: MATCHMAKER,
            engineHooks: Vec::new(),
        };
        world.env.msg_sender = MATCHMAKER;
        Engine::startBattle(&mut world, &mut battle);
        world.reset_transient(); // startBattle's tx is over; reads start boundary-clean
        let sk = Engine::_getStorageKey(&mut world, battle_key);
        let ts = world.Engine.battleConfig.get_mut(&sk).teamSizes;
        let team_sizes = ((ts & 0x0f) as usize, (ts >> 4) as usize);
        Sim { world, battle_key, engine_addr, team_sizes, fork_counter: 0 }
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

    /// Clone the live battle's state tree under a fresh fork key
    /// (battleData + battleConfig + the globalKV entries holding move
    /// locks / once-per-game flags). No storage-key redirect:
    /// `_getStorageKey(fork) == fork`.
    fn fork_battle(&mut self) -> B256 {
        let bk = self.battle_key;
        let fork = self.next_fork_key();
        let world = &mut self.world;
        let sk = Engine::_getStorageKey(world, bk);
        let data = world.Engine.battleData.get(&bk);
        world.Engine.battleData.set(fork, data);
        let cfg = world.Engine.battleConfig.get(&sk);
        world.Engine.battleConfig.set(fork, cfg);
        let kv = world.Engine.globalKV.get(&sk);
        world.Engine.globalKV.set(fork, kv);
        let slots = world.Engine.globalKVKeySlots.get(&sk);
        world.Engine.globalKVKeySlots.set(fork, slots);
        fork
    }

    /// Fork the live battle, run ONE silent hypothetical turn on the fork
    /// (`applyHypotheticalMove` semantics — either side may be None on a
    /// forced-switch turn), and return the fork key for follow-up reads.
    /// PHYSICAL p0/p1 — seat translation happens in the caller.
    pub fn apply_hypothetical(&mut self, p0: Option<HypoMove>, p1: Option<HypoMove>) -> B256 {
        let fork = self.fork_battle();
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
        Engine::_executeInternal(world, fork, fork, false, false);
        world.reset_transient(); // fork tx over; capture reads boundary-clean
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
