/**
 * Batch-mode FFI bridge — the ONLY runtime seam between the TS arena and
 * the native Rust stack. bun serializes a batch config (teams from the
 * CSVs, the container's address book, strategy names, seeds); the Rust
 * side plays whole games natively and returns outcomes. No per-turn
 * coupling: the drive-mode adapter that let TS strategies read the Rust
 * engine was retired when the stacks were decoupled (git history:
 * sims/src/arena/rust-engine.ts).
 */
import { dlopen, FFIType, ptr, CString } from 'bun:ffi';
import { join } from 'node:path';
import { contractAddresses } from '../../../transpiler/ts-output/runtime';
import * as Structs from '../../../transpiler/ts-output/Structs';
import type { SimContext } from '../harness';

const LIB_PATH = process.env.CHOMP_FFI_LIB
  ?? join(import.meta.dir, '..', '..', '..', 'transpiler', 'rs-output', 'target', 'release', 'libchomp_ffi.so');

/** Expected chomp_ffi_version (major << 16 | minor). Bump in lockstep with
 * ffi-rs on every exported-signature change — the assert below turns silent
 * ABI drift into an immediate load-time failure. */
const EXPECTED_FFI_VERSION = (0 << 16) | 5;

let _lib: any = null;
export function ffi(): any {
  if (_lib === null) {
    _lib = dlopen(LIB_PATH, {
      chomp_ffi_version: { args: [], returns: FFIType.u32 },
      chomp_run_games: { args: [FFIType.ptr], returns: FFIType.ptr },
      chomp_str_free: { args: [FFIType.ptr], returns: FFIType.void },
    });
    const v = Number(_lib.symbols.chomp_ffi_version());
    if (v !== EXPECTED_FFI_VERSION) {
      throw new Error(`chomp_ffi ABI mismatch: lib=${v.toString(16)} expected=${EXPECTED_FFI_VERSION.toString(16)} — rebuild rs-output or update EXPECTED_FFI_VERSION`);
    }
  }
  return _lib;
}

export function cstr(s: string): Buffer {
  return Buffer.from(s + '\0', 'utf8');
}

export function takeString(p: number | bigint, what: string): string {
  if (!p) throw new Error(`rust-ffi: ${what} returned null (bad input or unknown strategy)`);
  const s = new CString(p as any).toString();
  ffi().symbols.chomp_str_free(p as any);
  return s;
}

/** Mon JSON as chomp_run_games expects it (see ffi-rs MonJson). */
export function monToJson(m: Structs.Mon): unknown {
  return {
    hp: Number(m.stats.hp), stamina: Number(m.stats.stamina), speed: Number(m.stats.speed),
    attack: Number(m.stats.attack), defense: Number(m.stats.defense),
    specialAttack: Number(m.stats.specialAttack), specialDefense: Number(m.stats.specialDefense),
    type1: Number(m.stats.type1), type2: Number(m.stats.type2),
    moves: m.moves.map((w) => '0x' + w.toString(16)),
    ability: '0x' + m.ability.toString(16),
  };
}

/** The container's full contract address book, as the Rust side expects it —
 * every batch must be configured with the SAME book the TS address registry
 * assigned, so contract-move words resolve to the right ContractIds. */
export function buildAddressBook(ctx: SimContext): Record<string, string> {
  const book: Record<string, string> = {};
  for (const name of ctx.container.getRegisteredNames()) {
    book[name] = contractAddresses.getAddress(name);
  }
  return book;
}
