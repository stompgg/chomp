// Phase-5 FFI smoke + parity check: drives recorded lockstep scenarios
// through the compiled cdylib (bun:ffi) and asserts every per-turn field
// matches the fixture — the same check as tests/battle_replay.rs, but
// through the C ABI the arena will use. Also prints a rough turns/sec
// number for the native engine.
//
//   cargo build --release -p chomp-ffi   (in transpiler/rs-output)
//   bun transpiler/scripts/ffi_battle_smoke.ts

import { dlopen, FFIType, ptr, CString } from 'bun:ffi';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dir, '..');
const LIB = join(ROOT, 'rs-output', 'target', 'release', 'libchomp_ffi.so');

const lib = dlopen(LIB, {
  chomp_ffi_version: { args: [], returns: FFIType.u32 },
  chomp_battle_new: { args: [FFIType.ptr], returns: FFIType.u64 },
  chomp_battle_validate: {
    args: [FFIType.u64, FFIType.u8, FFIType.u8, FFIType.u16],
    returns: FFIType.i32,
  },
  chomp_battle_turn: { args: [FFIType.u64, FFIType.ptr], returns: FFIType.ptr },
  chomp_battle_snapshot: { args: [FFIType.u64], returns: FFIType.ptr },
  chomp_battle_free: { args: [FFIType.u64], returns: FFIType.void },
  chomp_str_free: { args: [FFIType.ptr], returns: FFIType.void },
});

function cjson(obj: unknown): Buffer {
  return Buffer.from(JSON.stringify(obj) + '\0', 'utf8');
}

function takeString(p: number | bigint): string {
  if (!p) throw new Error('null return from FFI');
  const s = new CString(p as any).toString();
  lib.symbols.chomp_str_free(p as any);
  return s;
}

const version = lib.symbols.chomp_ffi_version();
console.log(`chomp-ffi version 0x${version.toString(16)}`);

const fixture = JSON.parse(
  readFileSync(join(ROOT, 'differential-rs', 'fixtures', 'battle_replay.json'), 'utf8'),
);

function battleCfg(sc: any) {
  return {
    monsPerTeam: sc.monsPerTeam,
    p0Team: sc.p0Team,
    p1Team: sc.p1Team,
    addressBook: sc.addressBook ?? {},
  };
}

function replayScenario(sc: any): void {
  const handle = lib.symbols.chomp_battle_new(ptr(cjson(battleCfg(sc))));
  if (!handle) throw new Error(`${sc.name}: chomp_battle_new failed`);
  try {
    for (let ti = 0; ti < sc.turns.length; ti++) {
      const t = sc.turns[ti];
      const out = lib.symbols.chomp_battle_turn(handle, ptr(cjson({
        p0MoveIndex: t.p0MoveIndex, p1MoveIndex: t.p1MoveIndex,
        p0Salt: t.p0Salt, p1Salt: t.p1Salt,
        p0ExtraData: t.p0ExtraData, p1ExtraData: t.p1ExtraData,
      })));
      const snap = JSON.parse(takeString(out as any));
      const e = t.expect;
      const ctx = `${sc.name} turn ${ti}`;
      if (String(snap.turnId) !== e.turnId) throw new Error(`${ctx} turnId ${snap.turnId} != ${e.turnId}`);
      if (snap.winnerIndex !== e.winnerIndex) throw new Error(`${ctx} winner ${snap.winnerIndex} != ${e.winnerIndex}`);
      if (snap.p0Active !== e.p0Active || snap.p1Active !== e.p1Active) throw new Error(`${ctx} actives`);
      for (const side of ['p0States', 'p1States'] as const) {
        if (snap[side].length !== e[side].length) throw new Error(`${ctx} ${side} len`);
        for (let i = 0; i < e[side].length; i++) {
          const a = snap[side][i]; const b = e[side][i];
          if (a.hpDelta !== b.hpDelta || a.staminaDelta !== b.staminaDelta
              || a.isKnockedOut !== b.isKnockedOut) {
            throw new Error(`${ctx} ${side}[${i}]: ${JSON.stringify(a)} != ${JSON.stringify(b)}`);
          }
        }
      }
    }
  } finally {
    lib.symbols.chomp_battle_free(handle);
  }
}

let turns = 0;
for (const sc of fixture.scenarios) {
  replayScenario(sc);
  turns += sc.turns.length;
}
console.log(`FFI parity: ${fixture.scenarios.length} scenarios, ${turns} turns bit-identical through the cdylib`);

// Rough native-engine throughput: re-run the biggest roster scenario in a loop.
const bench = fixture.scenarios.find((s: any) => s.name === 'roster_3v3_b') ?? fixture.scenarios[0];
const N = 200;
const t0 = performance.now();
let benchTurns = 0;
for (let r = 0; r < N; r++) {
  const h = lib.symbols.chomp_battle_new(ptr(cjson(battleCfg(bench))));
  for (const t of bench.turns) {
    const out = lib.symbols.chomp_battle_turn(h, ptr(cjson({
      p0MoveIndex: t.p0MoveIndex, p1MoveIndex: t.p1MoveIndex,
      p0Salt: t.p0Salt, p1Salt: t.p1Salt,
      p0ExtraData: t.p0ExtraData, p1ExtraData: t.p1ExtraData,
    })));
    lib.symbols.chomp_str_free(out as any);
    benchTurns++;
  }
  lib.symbols.chomp_battle_free(h);
}
const ms = performance.now() - t0;
console.log(`bench: ${benchTurns} turns (${N}x ${bench.name}) in ${ms.toFixed(1)}ms — ${(benchTurns / (ms / 1000)).toFixed(0)} turns/sec incl. JSON boundary`);
