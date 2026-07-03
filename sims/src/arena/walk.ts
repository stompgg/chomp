/**
 * Exact-1v1 walk runner — plays a scripted board deterministically so the consequence walks in the
 * design docs can be machine-checked turn by turn. No CPU anywhere; both sides' actions come from
 * the script, so there is no peek or prediction confound.
 *
 *   bun arena/walk.ts --p0 gorillax --p1 malalien,sofabbi \
 *     --script "p0:PoundGround p1:rest; p0:RockPull p1:switch:1" \
 *     --expect "t2 p1.0.ko == 1; t2 p1.active == 1"
 *
 * Script: turns separated by ';', each turn gives both sides' actions. An action is a move name
 * (case/space-insensitive, resolved against the active mon's four slots), a slot number 0-3,
 * `switch:<team index>`, or `rest`. Targeted moves take extra data with `@`: `HitAndDip@1`.
 * Expectations: "tN pS.<slot>.<hp|stamina|ko> <op> <value>" or "tN pS.active == <index>", checked
 * after turn N. Any failed expectation exits 3. Every run journals to sims/runs.jsonl.
 */
import { appendFileSync } from 'node:fs';
import { makeSimContext, startBattle, executeTurn, type TurnInput, type TurnSnapshot } from '../harness';
import { loadRoster } from '../util/csv-load';
import { buildTeamMon } from './team';
import { MemoizedInlineRngOracle } from './rng-oracle';
import * as Constants from '../../../transpiler/ts-output/Constants';

const args = process.argv.slice(2);
const argVal = (flag: string, def: string) => {
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : def;
};

const roster = loadRoster();
const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');

function monByName(name: string) {
  const m = roster.mons.find((r: any) => norm(r.name) === norm(name));
  if (!m) throw new Error(`unknown mon "${name}" — roster: ${roster.mons.map((r: any) => r.name).join(', ')}`);
  return m;
}

const p0Names = argVal('--p0', '');
const p1Names = argVal('--p1', '');
const script = argVal('--script', '');
const expectArg = argVal('--expect', '');
const seed = Number(argVal('--seed', '1'));
if (!p0Names || !p1Names || !script) {
  console.error('usage: bun arena/walk.ts --p0 <mons> --p1 <mons> --script "p0:<action> p1:<action>; ..." [--expect "..."] [--seed N]');
  process.exit(1);
}

const p0Mons = p0Names.split(',').map(monByName);
const p1Mons = p1Names.split(',').map(monByName);
const ctx = makeSimContext({ monsPerTeam: BigInt(Math.max(p0Mons.length, p1Mons.length)) });
const p0Team = p0Mons.map((m: any) => buildTeamMon(ctx, roster, m.id));
const p1Team = p1Mons.map((m: any) => buildTeamMon(ctx, roster, m.id));
const { battleKey } = startBattle(ctx, p0Team, p1Team);
// Same oracle flip as the arena, so the keccak(p0Salt, p1Salt) inline rng path runs.
const engine = ctx.engine as any;
engine.battleConfig[engine._getStorageKey(battleKey)].rngOracle = new MemoizedInlineRngOracle();

// The engine's first turn is lead selection (both sides must send a mon out), so the runner plays
// it implicitly — scripted turns then start on the first real move turn. Override with --leads.
const leads = argVal('--leads', '0,0').split(',').map(Number);
executeTurn(ctx, battleKey, {
  p0MoveIndex: Number(Constants.SWITCH_MOVE_INDEX),
  p1MoveIndex: Number(Constants.SWITCH_MOVE_INDEX),
  p0ExtraData: BigInt(leads[0]),
  p1ExtraData: BigInt(leads[1]),
  p0Salt: 1n,
  p1Salt: 2n,
});
console.log(`leads: p0 ${p0Mons[leads[0]].name}, p1 ${p1Mons[leads[1]].name}`);

interface Action { index: number; extra: bigint; label: string }

function parseAction(token: string, sideMons: any[], activeIdx: number): Action {
  const [head, extraStr] = token.split('@');
  const extra = extraStr !== undefined ? BigInt(extraStr) : 0n;
  if (head === 'rest') return { index: Number(Constants.NO_OP_MOVE_INDEX), extra, label: 'rest' };
  if (head.startsWith('switch:')) {
    const target = head.slice('switch:'.length);
    return { index: Number(Constants.SWITCH_MOVE_INDEX), extra: BigInt(target), label: `switch:${target}` };
  }
  if (/^[0-3]$/.test(head)) return { index: Number(head), extra, label: `slot ${head}` };
  const active = sideMons[activeIdx];
  const slots = (roster.movesByMon.get(active.name) ?? []).slice(0, 4);
  const slot = slots.findIndex((mv: any) => norm(mv.name) === norm(head));
  if (slot < 0) {
    throw new Error(`"${head}" is not a move of ${active.name} — slots: ${slots.map((mv: any) => mv.name).join(', ')}`);
  }
  return { index: slot, extra, label: `${slots[slot].name}` };
}

interface Expect { turn: number; side: 0 | 1; slot: string; field: string; op: string; value: number; raw: string }

function parseExpects(text: string): Expect[] {
  if (!text.trim()) return [];
  return text.split(';').map((raw) => {
    const m = raw.trim().match(/^t(\d+)\s+p([01])\.(\d+|active)(?:\.(hp|stamina|ko))?\s*(<=|>=|==|<|>)\s*(-?\d+)$/);
    if (!m) throw new Error(`bad expectation "${raw.trim()}" — form: tN pS.<slot>.<hp|stamina|ko> <op> <value> or tN pS.active == <index>`);
    return { turn: Number(m[1]), side: Number(m[2]) as 0 | 1, slot: m[3], field: m[4] ?? '', op: m[5], value: Number(m[6]), raw: raw.trim() };
  });
}

function evalExpect(e: Expect, snap: TurnSnapshot, teams: [any[], any[]]): { ok: boolean; actual: number } {
  let actual: number;
  if (e.slot === 'active') {
    actual = e.side === 0 ? snap.p0Active : snap.p1Active;
  } else {
    const i = Number(e.slot);
    const st = (e.side === 0 ? snap.p0States : snap.p1States)[i];
    const base = teams[e.side][i];
    if (e.field === 'hp') actual = Number(BigInt(base.stats.hp) + st.hpDelta);
    else if (e.field === 'stamina') actual = Number(BigInt(base.stats.stamina) + st.staminaDelta);
    else actual = st.isKnockedOut ? 1 : 0;
  }
  const ok =
    (e.op === '<=' && actual <= e.value) || (e.op === '>=' && actual >= e.value) ||
    (e.op === '==' && actual === e.value) || (e.op === '<' && actual < e.value) ||
    (e.op === '>' && actual > e.value);
  return { ok, actual };
}

function printState(turn: number, snap: TurnSnapshot) {
  const line = (side: 0 | 1) => {
    const mons = side === 0 ? p0Mons : p1Mons;
    const states = side === 0 ? snap.p0States : snap.p1States;
    const active = side === 0 ? snap.p0Active : snap.p1Active;
    return states.map((st, i) => {
      const base: any = (side === 0 ? p0Team : p1Team)[i];
      const hp = BigInt(base.stats.hp) + st.hpDelta;
      const stam = BigInt(base.stats.stamina) + st.staminaDelta;
      const mark = st.isKnockedOut ? ' KO' : i === active ? ' *' : '';
      return `${mons[i].name} ${hp}/${base.stats.hp} s${stam}${mark}`;
    }).join(' | ');
  };
  console.log(`t${turn}  p0: ${line(0)}`);
  console.log(`     p1: ${line(1)}`);
}

const expects = parseExpects(expectArg);
const turns = script.split(';').map((t) => t.trim()).filter(Boolean);
const failures: string[] = [];
const turnLog: any[] = [];
let p0Active = 0;
let p1Active = 0;

for (let t = 1; t <= turns.length; t++) {
  const parts = Object.fromEntries(
    turns[t - 1].split(/\s+/).map((tok) => {
      const m = tok.match(/^p([01]):(.+)$/);
      if (!m) throw new Error(`bad script token "${tok}" in turn ${t} — expected p0:<action> p1:<action>`);
      return [m[1], m[2]];
    }),
  );
  if (!(('0' in parts) && ('1' in parts))) throw new Error(`turn ${t} needs both p0: and p1: actions`);
  const a0 = parseAction(parts['0'], p0Mons, p0Active);
  const a1 = parseAction(parts['1'], p1Mons, p1Active);
  const input: TurnInput = {
    p0MoveIndex: a0.index,
    p1MoveIndex: a1.index,
    p0ExtraData: a0.extra,
    p1ExtraData: a1.extra,
    p0Salt: BigInt(seed * 7919 + t * 2),
    p1Salt: BigInt(seed * 104729 + t * 2 + 1),
  };
  const flag = Number(engine.getBattleContext(battleKey).playerSwitchForTurnFlag);
  const forced = flag === 0 ? '  (forced: only p0 acts)' : flag === 1 ? '  (forced: only p1 acts)' : '';
  console.log(`\n== turn ${t}: p0 ${a0.label}  /  p1 ${a1.label}${forced}`);
  const snap = executeTurn(ctx, battleKey, input);
  p0Active = snap.p0Active;
  p1Active = snap.p1Active;
  printState(t, snap);
  if (snap.winnerIndex !== 2n) console.log(`     winner: p${snap.winnerIndex}`);
  turnLog.push({ t, p0: a0.label, p1: a1.label, p0Active, p1Active });
  for (const e of expects.filter((x) => x.turn === t)) {
    const { ok, actual } = evalExpect(e, snap, [p0Team as any[], p1Team as any[]]);
    console.log(`     expect ${e.raw} -> ${ok ? 'PASS' : `FAIL (actual ${actual})`}`);
    if (!ok) failures.push(`${e.raw} (actual ${actual})`);
  }
}

const journalEntry = {
  ts: new Date().toISOString(),
  kind: 'walk',
  args,
  script,
  expects: expectArg || null,
  turns: turnLog,
  failures,
};
appendFileSync(new URL('../../runs.jsonl', import.meta.url), JSON.stringify(journalEntry) + '\n');
console.log(`\n${failures.length === 0 ? 'all expectations passed' : `${failures.length} expectation(s) FAILED`} — journaled -> sims/runs.jsonl`);
process.exit(failures.length === 0 ? 0 : 3);
