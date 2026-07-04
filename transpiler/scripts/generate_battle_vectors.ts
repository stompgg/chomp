// Battle-replay vector generator (Phase 2 lockstep gate): drives the TS
// transpiled Engine through scripted DAMAGE-ONLY battles via sims/harness
// and records per-turn state snapshots. The Rust differential test
// (tests/battle_replay.rs) replays the same recorded inputs through the
// generated World and diffs every field per turn.
//
//   bun transpiler/scripts/generate_battle_vectors.ts
//
// Scope (Phase 2): inline packed moves only (no IMoveSet dispatch), no
// effects, no abilities, inline stamina-regen ruleset, zero validator.
// Scenario POLICIES may read live TS engine state (forced-switch flag,
// alive bitmap) — only the resulting recorded inputs matter to the replay.

import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  makeSimContext, buildMon, startBattle, executeTurn,
  type SimContext, type HarnessMonConfig, type TurnSnapshot,
} from '../../sims/src/harness';
import { buildTeamMon } from '../../sims/src/arena/team';
import { loadRoster } from '../../sims/src/util/csv-load';
import { contractAddresses } from '../ts-output/runtime';
import * as Constants from '../ts-output/Constants';
import type * as Structs from '../ts-output/Structs';

const FIXTURES = join(import.meta.dir, '..', 'differential-rs', 'fixtures');
mkdirSync(FIXTURES, { recursive: true });

const SWITCH = Number(Constants.SWITCH_MOVE_INDEX); // 125
const NO_OP = Number(Constants.NO_OP_MOVE_INDEX);   // 126

// ---------------------------------------------------------------------------
// Deterministic PRNG (xorshift64*) — same generator as the golden vectors.
// ---------------------------------------------------------------------------

const U64 = (1n << 64n) - 1n;
let state = 0xc0ffee0dda7a5eedn;

function nextU64(): bigint {
  state ^= state >> 12n;
  state = (state ^ (state << 25n)) & U64;
  state ^= state >> 27n;
  return (state * 0x2545f4914f6cdd1dn) & U64;
}

/** uint104 salt for an acting side. */
function salt(): bigint {
  return ((nextU64() << 40n) | (nextU64() & ((1n << 40n) - 1n))) & ((1n << 104n) - 1n);
}

// ---------------------------------------------------------------------------
// Mon + scenario builders
// ---------------------------------------------------------------------------

type MoveSpec = {
  basePower: number; staminaCost: number;
  moveType: string;
  moveClass: 'Physical' | 'Special'; priority?: number;
};

function mon(stats: {
  hp: number; stamina: number; speed: number; attack: number; defense: number;
  spa: number; spd: number; type1: number; type2: number;
}, moves: MoveSpec[]): HarnessMonConfig {
  return {
    stats: {
      hp: BigInt(stats.hp), stamina: BigInt(stats.stamina), speed: BigInt(stats.speed),
      attack: BigInt(stats.attack), defense: BigInt(stats.defense),
      specialAttack: BigInt(stats.spa), specialDefense: BigInt(stats.spd),
    },
    type1: stats.type1, type2: stats.type2,
    moves: moves.map((m) => ({
      kind: 'inline' as const,
      json: {
        name: 'V', basePower: m.basePower, staminaCost: m.staminaCost,
        moveType: m.moveType as any, moveClass: m.moveClass,
        effectAccuracy: 0, effect: null, priority: m.priority ?? 0,
      },
    })),
    ability: null,
  };
}

interface TurnRecord {
  p0MoveIndex: number; p1MoveIndex: number;
  p0Salt: string; p1Salt: string;
  p0ExtraData: number; p1ExtraData: number;
  expect: {
    turnId: string; winnerIndex: number;
    p0Active: number; p1Active: number;
    p0States: { hpDelta: number; staminaDelta: number; isKnockedOut: boolean }[];
    p1States: { hpDelta: number; staminaDelta: number; isKnockedOut: boolean }[];
  };
}

interface ScenarioOut {
  name: string;
  monsPerTeam: number;
  p0Team: any[];
  p1Team: any[];
  battleKey: string;
  /** Contract name -> address, exported per scenario (the TS address
   * scheme is generation-order-dependent). Rust deploy_all consumes it. */
  addressBook: Record<string, string>;
  turns: TurnRecord[];
}

function exportAddressBook(ctx: SimContext): Record<string, string> {
  const book: Record<string, string> = {};
  for (const name of ctx.container.getRegisteredNames()) {
    book[name] = contractAddresses.getAddress(name);
  }
  return book;
}

function exportMon(m: ReturnType<typeof buildMon>): any {
  return {
    hp: Number(m.stats.hp), stamina: Number(m.stats.stamina), speed: Number(m.stats.speed),
    attack: Number(m.stats.attack), defense: Number(m.stats.defense),
    specialAttack: Number(m.stats.specialAttack), specialDefense: Number(m.stats.specialDefense),
    type1: Number(m.stats.type1), type2: Number(m.stats.type2),
    moves: m.moves.map((w) => '0x' + w.toString(16)),
    ability: '0x' + m.ability.toString(16),
  };
}

/** A per-turn decision when the side acts normally (flag lets it move).
 * `validate` runs the engine's own inline-validator check for the side. */
type Policy = (
  turn: number, side: 0 | 1, snap: TurnSnapshot | null,
  validate: (side: 0 | 1, moveIndex: number, extraData: number) => boolean,
) => { moveIndex: number; extraData: number };

/** Lowest alive, non-active team slot (forced/voluntary switch target). */
function switchTarget(snap: TurnSnapshot, side: 0 | 1): number {
  const states = side === 0 ? snap.p0States : snap.p1States;
  const active = side === 0 ? snap.p0Active : snap.p1Active;
  for (let i = 0; i < states.length; i++) {
    if (i !== active && !states[i].isKnockedOut) return i;
  }
  throw new Error('no switch target');
}

function runScenario(
  name: string, monsPerTeam: number,
  p0Cfg: HarnessMonConfig[], p1Cfg: HarnessMonConfig[],
  policy: Policy, maxTurns: number,
): ScenarioOut {
  const ctx: SimContext = makeSimContext({ monsPerTeam: BigInt(monsPerTeam) });
  return runBuiltScenario(
    ctx, name, monsPerTeam,
    p0Cfg.map((c) => buildMon(ctx, c)),
    p1Cfg.map((c) => buildMon(ctx, c)),
    policy, maxTurns,
  );
}

function runBuiltScenario(
  ctx: SimContext, name: string, monsPerTeam: number,
  p0Team: Structs.Mon[], p1Team: Structs.Mon[],
  policy: Policy, maxTurns: number,
): ScenarioOut {
  const started = startBattle(ctx, p0Team, p1Team);
  const engine = ctx.engine as any;
  const validate = (side: 0 | 1, moveIndex: number, extraData: number): boolean =>
    engine.validatePlayerMoveForBattle(
      started.battleKey, BigInt(moveIndex), BigInt(side), BigInt(extraData),
    ) as boolean;

  const turns: TurnRecord[] = [];
  let last: TurnSnapshot | null = null;
  for (let t = 0; t < maxTurns; t++) {
    if (last && last.winnerIndex !== 2n) break;
    const flag = Number(engine.battleData[started.battleKey].playerSwitchForTurnFlag);
    const p0Acts = flag !== 1;
    const p1Acts = flag !== 0;

    let p0Move = { moveIndex: NO_OP, extraData: 0 };
    let p1Move = { moveIndex: NO_OP, extraData: 0 };
    if (p0Acts) {
      p0Move = flag === 0 && last
        ? { moveIndex: SWITCH, extraData: switchTarget(last, 0) }
        : policy(t, 0, last, validate);
    }
    if (p1Acts) {
      p1Move = flag === 1 && last
        ? { moveIndex: SWITCH, extraData: switchTarget(last, 1) }
        : policy(t, 1, last, validate);
    }
    const p0Salt = p0Acts ? salt() : 0n;
    const p1Salt = p1Acts ? salt() : 0n;

    const snap = executeTurn(ctx, started.battleKey, {
      p0MoveIndex: p0Move.moveIndex, p1MoveIndex: p1Move.moveIndex,
      p0Salt, p1Salt,
      p0ExtraData: BigInt(p0Move.extraData), p1ExtraData: BigInt(p1Move.extraData),
    });
    last = snap;
    turns.push({
      p0MoveIndex: p0Move.moveIndex, p1MoveIndex: p1Move.moveIndex,
      p0Salt: p0Salt.toString(), p1Salt: p1Salt.toString(),
      p0ExtraData: p0Move.extraData, p1ExtraData: p1Move.extraData,
      expect: {
        turnId: snap.turnId.toString(),
        winnerIndex: Number(snap.winnerIndex),
        p0Active: snap.p0Active, p1Active: snap.p1Active,
        p0States: snap.p0States.map((s) => ({
          hpDelta: Number(s.hpDelta), staminaDelta: Number(s.staminaDelta),
          isKnockedOut: s.isKnockedOut,
        })),
        p1States: snap.p1States.map((s) => ({
          hpDelta: Number(s.hpDelta), staminaDelta: Number(s.staminaDelta),
          isKnockedOut: s.isKnockedOut,
        })),
      },
    });
  }
  if (turns.length === 0) throw new Error(`${name}: no turns recorded`);
  console.log(`${name}: ${turns.length} turns, winner=${turns[turns.length - 1].expect.winnerIndex}`);
  return {
    name, monsPerTeam,
    p0Team: p0Team.map(exportMon), p1Team: p1Team.map(exportMon),
    battleKey: started.battleKey,
    addressBook: exportAddressBook(ctx),
    turns,
  };
}

/** Mon with contract-move slots and/or a named ability. */
function cmon(stats: {
  hp: number; stamina: number; speed: number; attack: number; defense: number;
  spa: number; spd: number; type1: number; type2: number;
}, moves: (string | MoveSpec)[], ability: string | null = null): HarnessMonConfig {
  return {
    stats: {
      hp: BigInt(stats.hp), stamina: BigInt(stats.stamina), speed: BigInt(stats.speed),
      attack: BigInt(stats.attack), defense: BigInt(stats.defense),
      specialAttack: BigInt(stats.spa), specialDefense: BigInt(stats.spd),
    },
    type1: stats.type1, type2: stats.type2,
    moves: moves.map((m) => typeof m === 'string'
      ? { kind: 'contract' as const, contractName: m }
      : {
          kind: 'inline' as const,
          json: {
            name: 'V', basePower: m.basePower, staminaCost: m.staminaCost,
            moveType: m.moveType as any, moveClass: m.moveClass,
            effectAccuracy: 0, effect: null, priority: m.priority ?? 0,
          },
        }),
    ability,
  };
}

// ---------------------------------------------------------------------------
// Scenarios (types: Fire=4, Liquid=3, Nature=7, Metal=5, Air=10, None=15)
// ---------------------------------------------------------------------------

const scenarios: ScenarioOut[] = [];

// 1. Plain 1v1: asymmetric speed and power, both spam move 0.
scenarios.push(runScenario(
  '1v1_basic', 1,
  [mon({ hp: 120, stamina: 10, speed: 10, attack: 55, defense: 45, spa: 40, spd: 40, type1: 4, type2: 14 },
    [{ basePower: 60, staminaCost: 1, moveType: 'Fire', moveClass: 'Physical' }])],
  [mon({ hp: 140, stamina: 10, speed: 8, attack: 45, defense: 55, spa: 50, spd: 35, type1: 3, type2: 14 },
    [{ basePower: 45, staminaCost: 1, moveType: 'Liquid', moveClass: 'Physical' }])],
  () => ({ moveIndex: 0, extraData: 0 }),
  40,
));

// 2. Type matchup + special class + priority difference; alternating moves.
scenarios.push(runScenario(
  '1v1_types_special', 1,
  [mon({ hp: 150, stamina: 12, speed: 12, attack: 40, defense: 50, spa: 65, spd: 50, type1: 7, type2: 14 },
    [{ basePower: 50, staminaCost: 1, moveType: 'Nature', moveClass: 'Special' },
     { basePower: 35, staminaCost: 1, moveType: 'Air', moveClass: 'Physical', priority: 1 }])],
  [mon({ hp: 150, stamina: 12, speed: 12, attack: 55, defense: 45, spa: 45, spd: 55, type1: 3, type2: 5 },
    [{ basePower: 55, staminaCost: 2, moveType: 'Liquid', moveClass: 'Special' },
     { basePower: 40, staminaCost: 1, moveType: 'Metal', moveClass: 'Physical' }])],
  (t) => ({ moveIndex: t % 2, extraData: 0 }),
  40,
));

// 3. Speed tie: identical speed forces the RNG priority coin flip every turn.
scenarios.push(runScenario(
  '1v1_speed_tie', 1,
  [mon({ hp: 160, stamina: 10, speed: 10, attack: 50, defense: 50, spa: 50, spd: 50, type1: 12, type2: 14 },
    [{ basePower: 50, staminaCost: 1, moveType: 'Cyber', moveClass: 'Physical' }])],
  [mon({ hp: 160, stamina: 10, speed: 10, attack: 50, defense: 50, spa: 50, spd: 50, type1: 13, type2: 14 },
    [{ basePower: 50, staminaCost: 1, moveType: 'Cosmic', moveClass: 'Physical' }])],
  () => ({ moveIndex: 0, extraData: 0 }),
  40,
));

// 4. 2v2 with a voluntary switch mid-fight and KO-forced switches.
scenarios.push(runScenario(
  '2v2_switches', 2,
  [mon({ hp: 100, stamina: 10, speed: 11, attack: 50, defense: 45, spa: 40, spd: 45, type1: 4, type2: 14 },
    [{ basePower: 55, staminaCost: 1, moveType: 'Fire', moveClass: 'Physical' }]),
   mon({ hp: 110, stamina: 10, speed: 9, attack: 45, defense: 50, spa: 55, spd: 50, type1: 2, type2: 14 },
    [{ basePower: 50, staminaCost: 1, moveType: 'Earth', moveClass: 'Special' }])],
  [mon({ hp: 105, stamina: 10, speed: 10, attack: 48, defense: 48, spa: 48, spd: 48, type1: 3, type2: 14 },
    [{ basePower: 52, staminaCost: 1, moveType: 'Liquid', moveClass: 'Physical' }]),
   mon({ hp: 95, stamina: 10, speed: 13, attack: 52, defense: 42, spa: 42, spd: 42, type1: 10, type2: 14 },
    [{ basePower: 48, staminaCost: 1, moveType: 'Air', moveClass: 'Physical' }])],
  (t, side, snap) => {
    // p0 switches voluntarily on scripted turn 3 (if its bench is alive).
    if (t === 3 && side === 0 && snap) {
      try { return { moveIndex: SWITCH, extraData: switchTarget(snap, 0) }; } catch { /* bench dead */ }
    }
    return { moveIndex: 0, extraData: 0 };
  },
  60,
));

// 5. 3v3, mixed priorities and stamina costs; no-op turns exercise the
// inline stamina regen; pseudorandom move picks recorded per turn.
{
  const picks: number[] = [];
  scenarios.push(runScenario(
    '3v3_mixed', 3,
    [mon({ hp: 90, stamina: 6, speed: 14, attack: 52, defense: 40, spa: 44, spd: 40, type1: 8, type2: 14 },
      [{ basePower: 45, staminaCost: 1, moveType: 'Lightning', moveClass: 'Special' },
       { basePower: 70, staminaCost: 3, moveType: 'Lightning', moveClass: 'Special' }]),
     mon({ hp: 130, stamina: 6, speed: 6, attack: 40, defense: 60, spa: 35, spd: 60, type1: 5, type2: 2 },
      [{ basePower: 40, staminaCost: 1, moveType: 'Metal', moveClass: 'Physical' },
       { basePower: 30, staminaCost: 1, moveType: 'Earth', moveClass: 'Physical', priority: 1 }]),
     mon({ hp: 110, stamina: 6, speed: 10, attack: 48, defense: 48, spa: 48, spd: 48, type1: 6, type2: 14 },
      [{ basePower: 50, staminaCost: 2, moveType: 'Ice', moveClass: 'Special' },
       { basePower: 35, staminaCost: 1, moveType: 'Ice', moveClass: 'Physical' }])],
    [mon({ hp: 100, stamina: 6, speed: 12, attack: 50, defense: 44, spa: 46, spd: 44, type1: 0, type2: 14 },
      [{ basePower: 48, staminaCost: 1, moveType: 'Yin', moveClass: 'Physical' },
       { basePower: 65, staminaCost: 3, moveType: 'Yin', moveClass: 'Special' }]),
     mon({ hp: 120, stamina: 6, speed: 8, attack: 44, defense: 54, spa: 40, spd: 54, type1: 1, type2: 14 },
      [{ basePower: 42, staminaCost: 1, moveType: 'Yang', moveClass: 'Physical' },
       { basePower: 30, staminaCost: 1, moveType: 'Yang', moveClass: 'Physical', priority: 2 }]),
     mon({ hp: 105, stamina: 6, speed: 11, attack: 47, defense: 47, spa: 51, spd: 47, type1: 13, type2: 14 },
      [{ basePower: 50, staminaCost: 2, moveType: 'Cosmic', moveClass: 'Special' },
       { basePower: 38, staminaCost: 1, moveType: 'Cosmic', moveClass: 'Physical' }])],
    (t, side) => {
      // Deterministic pseudo-random pick incl. occasional no-op (regen turn).
      const r = Number(nextU64() % 5n);
      picks.push(r);
      if (r === 4) return { moveIndex: NO_OP, extraData: 0 };
      return { moveIndex: r % 2, extraData: 0 };
    },
    80,
  ));
}

// ---------------------------------------------------------------------------
// Phase-3 scenarios: CONTRACT moves (real dispatch), status effects, ability
// ---------------------------------------------------------------------------

// 6. Burn: SetAblaze is a StandardAttack with EFFECT=BurnStatus — chip damage
// per turn plus the attack-halving stat boost through the inlined engine path.
scenarios.push(runScenario(
  'burn_setablaze', 1,
  [cmon({ hp: 220, stamina: 20, speed: 9, attack: 50, defense: 50, spa: 55, spd: 50, type1: 4, type2: 14 },
    ['SetAblaze'])],
  [cmon({ hp: 220, stamina: 20, speed: 11, attack: 55, defense: 50, spa: 45, spd: 50, type1: 7, type2: 14 },
    [{ basePower: 40, staminaCost: 1, moveType: 'Nature', moveClass: 'Physical' }])],
  () => ({ moveIndex: 0, extraData: 0 }),
  30,
));

// 7. Frostbite: DeepFreeze applies FrostbiteStatus (special-attack halving +
// per-turn chip), against a special attacker so the halving is observable.
scenarios.push(runScenario(
  'frostbite_deepfreeze', 1,
  [cmon({ hp: 200, stamina: 20, speed: 12, attack: 45, defense: 50, spa: 60, spd: 55, type1: 6, type2: 14 },
    ['DeepFreeze'])],
  [cmon({ hp: 200, stamina: 20, speed: 10, attack: 40, defense: 55, spa: 65, spd: 45, type1: 3, type2: 14 },
    [{ basePower: 45, staminaCost: 1, moveType: 'Liquid', moveClass: 'Special' }])],
  () => ({ moveIndex: 0, extraData: 0 }),
  30,
));

// 8. Zap + battlefield effect: DualShock (ZapStatus, Overclock global).
scenarios.push(runScenario(
  'zap_dualshock', 1,
  [cmon({ hp: 190, stamina: 20, speed: 13, attack: 45, defense: 45, spa: 60, spd: 50, type1: 8, type2: 14 },
    ['DualShock'])],
  [cmon({ hp: 210, stamina: 20, speed: 9, attack: 55, defense: 55, spa: 40, spd: 55, type1: 2, type2: 14 },
    [{ basePower: 45, staminaCost: 1, moveType: 'Earth', moveClass: 'Physical' }])],
  () => ({ moveIndex: 0, extraData: 0 }),
  30,
));

// 9. Ability on switch-in: PreemptiveShock activates on every send-in;
// 2v2 with a mid-fight voluntary switch re-triggers it.
scenarios.push(runScenario(
  'ability_preemptive_shock', 2,
  [cmon({ hp: 130, stamina: 12, speed: 12, attack: 50, defense: 45, spa: 50, spd: 45, type1: 8, type2: 14 },
    [{ basePower: 45, staminaCost: 1, moveType: 'Lightning', moveClass: 'Special' }], 'PreemptiveShock'),
   cmon({ hp: 140, stamina: 12, speed: 8, attack: 45, defense: 55, spa: 45, spd: 55, type1: 5, type2: 14 },
    [{ basePower: 40, staminaCost: 1, moveType: 'Metal', moveClass: 'Physical' }], 'PreemptiveShock')],
  [cmon({ hp: 150, stamina: 12, speed: 10, attack: 50, defense: 50, spa: 50, spd: 50, type1: 3, type2: 14 },
    [{ basePower: 48, staminaCost: 1, moveType: 'Liquid', moveClass: 'Physical' }]),
   cmon({ hp: 150, stamina: 12, speed: 11, attack: 48, defense: 48, spa: 48, spd: 48, type1: 10, type2: 14 },
    [{ basePower: 45, staminaCost: 1, moveType: 'Air', moveClass: 'Physical' }])],
  (t, side, snap) => {
    if (t === 2 && side === 0 && snap) {
      try { return { moveIndex: SWITCH, extraData: switchTarget(snap, 0) }; } catch { /* bench dead */ }
    }
    return { moveIndex: 0, extraData: 0 };
  },
  40,
));

// 10. Sleep: ContagiousSlumber (SleepStatus — turn-skip with RNG wake).
scenarios.push(runScenario(
  'sleep_contagious_slumber', 1,
  [cmon({ hp: 200, stamina: 20, speed: 12, attack: 45, defense: 50, spa: 55, spd: 50, type1: 0, type2: 14 },
    ['ContagiousSlumber', { basePower: 45, staminaCost: 1, moveType: 'Yin', moveClass: 'Special' }])],
  [cmon({ hp: 200, stamina: 20, speed: 10, attack: 55, defense: 50, spa: 45, spd: 50, type1: 1, type2: 14 },
    [{ basePower: 45, staminaCost: 1, moveType: 'Yang', moveClass: 'Physical' }])],
  (t) => ({ moveIndex: t === 0 ? 0 : (t % 3 === 0 ? 0 : 1), extraData: 0 }),
  30,
));

// ---------------------------------------------------------------------------
// Phase-4 scenarios: the REAL roster (drool CSV stats, contract moves +
// abilities). Policy rotates move slots, validated by the engine's own
// inline validator; invalid slots fall through, no-op as last resort.
// ---------------------------------------------------------------------------

const rosterPolicy: Policy = (t, _side, _snap, validate) => {
  for (let k = 0; k < 4; k++) {
    const mi = (t + k) % 4;
    if (validate(_side, mi, 0)) return { moveIndex: mi, extraData: 0 };
  }
  return { moveIndex: NO_OP, extraData: 0 };
};

{
  const roster = loadRoster();
  const ids = roster.mons.map((m) => m.id).sort((a, b) => a - b);
  const pick = (list: number[]) => list.filter((id) => ids.includes(id));
  const matchups: [string, number[], number[]][] = [
    ['roster_3v3_a', pick([0, 1, 2]), pick([3, 4, 5])],
    ['roster_3v3_b', pick([6, 7, 8]), pick([9, 10, 11])],
    ['roster_2v2_c', pick([12, 2]), pick([7, 0])],
  ];
  for (const [name, p0Ids, p1Ids] of matchups) {
    const ctx = makeSimContext({ monsPerTeam: BigInt(p0Ids.length) });
    scenarios.push(runBuiltScenario(
      ctx, name, p0Ids.length,
      p0Ids.map((id) => buildTeamMon(ctx, roster, id)),
      p1Ids.map((id) => buildTeamMon(ctx, roster, id)),
      rosterPolicy, 80,
    ));
  }
}

const out = { scenarios };
const path = join(FIXTURES, 'battle_replay.json');
writeFileSync(path, JSON.stringify(out, null, 1));
console.log(`Wrote ${path} (${scenarios.length} scenarios, ${scenarios.reduce((n, s) => n + s.turns.length, 0)} turns)`);
