# Runtime replacements

A runtime replacement is TypeScript file that stands in for a Solidity
file the transpiler can't (or shouldn't) lower automatically. When the
transpiler encounters an import of the replaced file, it emits a re-export
stub instead of transpiled output, and your hand-written module is what
consumers actually call into.

## When to reach for one

- The source uses Yul patterns that need a memory model or precompiles
  (ecrecover, computed storage slots, low-level dispatch). See the red-flag
  list in [`init.md`](init.md#red-flags-that-force-replace).
- The source fails to parse.
- The transpiled output would compile but behave silently wrongly.
- You want to swap in a test-specific behavior without modifying the
  Solidity source (e.g., a mock oracle).

[`extruder init`](init.md) will flag files that need replacements and scaffold
stubs for them. This doc explains what the scaffold contains and how to
finish the job.

## Anatomy of a replacement

Here's one reference implementation: `runtime/Ownable.ts`. It stands in for
Solady's `lib/Ownable.sol`, whose storage-slot-heavy Yul is better represented
by a small hand-written TypeScript class.

```ts
import { Contract } from './base';

export abstract class Ownable extends Contract {
  private _owner: string = '0x0000000000000000000000000000000000000000';

  protected _checkOwner(): void {
    if (this._msg.sender !== this._owner) throw new Error('Unauthorized');
  }

  owner(): string {
    return this._owner;
  }
}
```

Two things to notice:

1. **The class extends `Contract`.** This means even libraries can be
   instantiated, participate in the address registry, and emit events — the
   same as transpiled contracts. You can write state if you want; you
   usually don't.
2. **No explicit registration.** The only thing connecting this file to the
   transpiler is the `transpiler-config.json` entry below. The generator emits
   a re-export stub for the replaced Solidity file, so downstream imports keep
   working while resolving to your hand-written module.

## Authoring workflow

### 1. Scaffold

```bash
cd /path/to/extruder
python3 -m transpiler \
  --emit-replacement-stub MyLib /path/to/your/foundry/project/src/lib/MyLib.sol \
  -o /path/to/your/foundry/project/runtime-replacements/MyLib.ts
```

This produces a TypeScript class with:

- The correct `abstract` / concrete distinction based on the Solidity source.
- Every method mapped to TS types: `uint256` → `bigint`, `address` →
  `string`, etc.
- Method bodies that `throw new Error('Not implemented: <visibility> <name>')`.
- State variables initialized to type-appropriate defaults.
- `static readonly` constants with literal values preserved where the parser
  could extract them.
- Custom errors and events listed as comments for reference.
- Contract-local structs emitted as sibling `export interface` blocks.
- Solidity overloads disambiguated with `_overload1`, `_overload2` suffixes
  plus a TODO comment (TypeScript doesn't have parameter-based method
  overloading; pick meaningful names during your fill-in pass).

The tool also prints a `runtimeReplacements` JSON entry to stdout, ready to
paste into `transpiler-config.json`.

### 2. Fill in the bodies

Replace each `throw new Error('Not implemented…')` with real logic. Three
common patterns:

- **Pure functions** — just write the TypeScript. Use viem for hash /
  encoding primitives; use `@noble/curves` for signature crypto.
- **Stateful libraries** — declare state variables, implement getters and
  mutators. The `Contract` base gives you `_storage` if you want to mirror
  Solidity's slot-keyed storage, but a plain field is usually clearer.
- **Mock / stub behavior** — throw with a useful message, return constants,
  or record calls for tests to inspect.

### 3. Register

Paste the `runtimeReplacements` entry into `transpiler-config.json` (or let
`extruder init` do it for you automatically). Re-transpile. The generated TS
now routes through your replacement.

## Caveats

- The scaffold **will not overwrite** an existing file without explicit
  action — but re-running `--emit-replacement-stub` on the same output path
  does overwrite. Treat the stub as a one-shot scaffold, not a
  regenerate-on-every-change artifact.
- **Method signatures come from the Solidity source.** If you change them
  in the replacement, generated code written against the original signatures
  won't typecheck. Either keep the shapes stable or re-scaffold when the
  source changes.
- **Runtime replacements skip the YulTranspiler entirely.** You're
  responsible for everything the Solidity source did — including side
  effects, state updates, and event emissions.

## When not to reach for one

- **Modifier-stripping (W001).** The modifier's code path disappears, but
  the rest of the contract transpiles fine. If your only concern is
  access control, fix it in the test harness (spoof `msg.sender`), not via
  a replacement.
- **Skipped receive/fallback functions (W003).** Degraded fidelity, but the
  contract still transpiles. Audit case-by-case; a replacement is overkill for
  most.
- **You just don't want this file transpiled.** Use `skipFiles` or
  `skipContracts` in the config; no replacement needed.

If a source file appears in both `runtimeReplacements` and `skipFiles` or
`skipDirs`, the runtime replacement wins. Remove the replacement entry when
you mean "skip this entirely."
