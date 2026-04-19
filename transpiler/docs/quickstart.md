# Quickstart

You have a Foundry project with contracts in `src/`. `extruder` can generate files in `ts-output/`, a scaffolded config, and a test file that calls into the transpiled contracts.

## 1. Install

Clone extruder somewhere

```bash
git clone <REPO_URL> ~/tools/extruder
cd ~/tools/extruder && pip install -r requirements.txt
```

Add the JS runtime deps to your own Foundry project:

```bash
cd path/to/your/foundry/project
npm install -D viem vitest
```

## 2. Bootstrap your config with `extruder init`

```bash
python3 ~/tools/extruder/sol2ts.py init src/ --yes
```

This scans `src/` and writes:

- `transpiler-config.json` — populated with `skipFiles`, `interfaceAliases`,
  `dependencyOverrides`, and `runtimeReplacements` entries derived from the
  scan.
- `runtime-replacements/*.ts` — scaffolded stubs for every file the scan
  flagged as needing hand-written TypeScript.
- `.extruder-init-report.md` — a summary of what was decided vs. punted.

See [`init.md`](init.md) for details on classification and prompt behavior.
Drop `--yes` to run interactively.

## 3. Fill in the stub bodies

For each file under `runtime-replacements/`, replace the
`throw new Error('Not implemented…')` bodies with real logic. See
[`runtime-replacements.md`](runtime-replacements.md) for common patterns and
the ECDSA reference implementation.

You can defer this step if you want to see the transpiler run end-to-end —
the stubs throw loudly at call time, so missing implementations fail fast
rather than silently.

## 4. Transpile

```bash
python3 ~/tools/extruder/sol2ts.py src/ -o ts-output -d src --emit-metadata
```

- `src/` is the input tree.
- `-o ts-output` is where TypeScript lands. Add to `.gitignore` — it's
  regenerated output.
- `-d src` seeds the type-discovery registry (needed for cross-file
  resolution). Pass `-d` multiple times if your sources span multiple
  roots.
- `--emit-metadata` also writes `factories.ts`, which wires up a
  dependency-injection container.

Inspect what landed:

```
ts-output/
├── MyContract.ts          # One file per .sol
├── Structs.ts             # Shared structs (if any)
├── Enums.ts
├── factories.ts           # DI registry
└── runtime/               # Runtime library, copied in from extruder
```

## 5. Drive it

```ts
// harness.ts
import { ContractContainer } from './ts-output/runtime';
import { contracts, setupContainer } from './ts-output/factories';

const container = new ContractContainer();
setupContainer(container);

// Override contracts whose constructors take non-interface arguments:
// container.registerLazySingleton('MyContract', [], () =>
//   new contracts.MyContract.cls(ARG_1, ARG_2),
// );

const token = container.resolve('MyToken') as any;
token._msg.sender = '0x0000000000000000000000000000000000000001';
token.mint('0x0000000000000000000000000000000000000002', 100n);
console.log(token.balanceOf('0x0000000000000000000000000000000000000002')); // 100n
```

Run under vitest:

```bash
npx vitest run harness.test.ts
```

See [`runtime.md`](runtime.md) for the full container API, address
stamping, event draining, and call tracing.

## When things go wrong

- **Parse error or unhandled construct.** The transpiler prints the file
  and line. Either fix the Solidity, add the file to `skipFiles`, or write
  a runtime replacement (`--emit-replacement-stub`).
- **`W001` flood in your diagnostics.** Modifiers are stripped. Hand-audit
  the flagged functions, or spoof `msg.sender` in the harness to reach the
  same code paths. See [`semantics.md`](semantics.md#codegen-gaps).
- **`Contract.at(addr)` throws "no instance registered at address."** The
  address you're looking up isn't in the static registry. Either no
  contract with that address was constructed, or its address was
  overwritten. Log `Contract._addressRegistry` to see what's there.
- **Constructor dep came through as `any`.** The dependency resolver
  couldn't map an interface to a concrete contract. Look at
  `unresolved-dependencies.json`. Either re-run `extruder init` to let it
  prompt, or add the mapping by hand to `transpiler-config.json`'s
  `dependencyOverrides` or `interfaceAliases` — see
  [`configuration.md`](configuration.md).
- **Output looks stale.** Transpiler output is deterministic but can be
  cached by your editor / bundler. Delete `ts-output/` and re-run.

## Where to go next

- [`init.md`](init.md) — full walkthrough of the scan command.
- [`configuration.md`](configuration.md) — every config field explained.
- [`runtime-replacements.md`](runtime-replacements.md) — authoring runtime
  replacements.
- [`runtime.md`](runtime.md) — the runtime API surface.
- [`semantics.md`](semantics.md) — what's lost in translation; read this
  before trusting transpiled output for anything safety-critical.
- [`extending.md`](extending.md) — contributor-facing; closing gaps in the
  transpiler itself.
