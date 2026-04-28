# extruder

**extruder** is a source-to-source transpiler that compiles Solidity contracts
into TypeScript you can run in Node or the browser.

## Should I use this?

**Good fit** if you want:

- A TypeScript mirror of your contracts you can step through in a debugger,
  mutate freely, etc.
- A client-side simulator for a game or protocol so users can preview
  outcomes before signing.

**Bad fit** if you need:

- Bytecode-level or gas-exact accuracy.
- Storage-layout compatibility with a deployed contract (we do not model
  slots on-chain-compatible).
- To port complex `delegatecall` or proxy patterns — those don't survive
  translation.

## Install

```bash
git clone <REPO_URL> ~/tools/extruder
cd ~/tools/extruder

# Optional: install the standalone CLI in editable mode.
python3 -m pip install -e ./transpiler

# In your own Foundry project:
npm install -D viem vitest
```

If installed, run:

```bash
extruder --help
```

From a source checkout, you can also run extruder as a Python module from
the directory that contains the `transpiler/` package:

```bash
cd ~/tools/extruder
python3 -m transpiler --help
```

Do not run `transpiler/sol2ts.py` directly; it uses package-relative imports.

## Quickstart

Bootstrap the config and scaffolded runtime-replacement stubs with one
command:

```bash
cd ~/tools/extruder
extruder init /path/to/your/foundry/project/src --yes
```

Then transpile:

```bash
extruder /path/to/your/foundry/project/src \
  -o /path/to/your/foundry/project/ts-output \
  -d /path/to/your/foundry/project/src \
  --emit-metadata
```

See [`docs/quickstart.md`](docs/quickstart.md) for the full walkthrough.

## What it does

- **Parse → AST → emit TS.** Not bytecode, not an EVM.
- `uint*` / `int*` → `bigint`. `address` / `bytes*` → `string`. Mappings →
  `Record`. Structs → interfaces + factory. Enums → TypeScript `enum`s.
- Contracts become ES classes extending a runtime `Contract` base that
  carries `_contractAddress`, `_storage`, `_msg`, an event emitter, and a
  transient-storage reset hook.
- Inter-contract references are plain object references. There's no
  address-based dispatch unless you opt into it.

## What it does not

extruder does not produce bytecode-compatible output, does not run an EVM,
and does not preserve all Solidity semantics exactly. The biggest gaps —
modifiers, gas, low-level calls, revert reason propagation, overflow checks
— are detailed in [`docs/semantics.md`](docs/semantics.md). Read it before
trusting a transpiled contract to behave identically to its on-chain
counterpart.

## CLI

```
extruder [input] [options]
extruder init <src-dir> [--yes] [--stub-output-dir DIR] [--config-path PATH]
extruder --emit-replacement-stub CONTRACT SOL_FILE [-o OUTPUT]
```

`python3 -m transpiler ...` supports the same commands from a source checkout.

| Flag | Purpose |
|---|---|
| `input` *(positional)* | File or directory to transpile. |
| `-o`, `--output` | Output directory (default: `ts-output/`). |
| `-d`, `--discover` *(repeatable)* | Root(s) to scan for type discovery. Pass every source root you need cross-file resolution across. |
| `--stdout` | Print a single file to stdout instead of writing (debugging). |
| `--emit-metadata` | Also emit `factories.ts`. |
| `--overrides` | Path to `transpiler-config.json`. Defaults to the one bundled with the package. |
| `--emit-replacement-stub CONTRACT SOL_FILE` | Emit a TypeScript scaffold for a runtime replacement. Body = `throw new Error('Not implemented')`. See [`docs/runtime-replacements.md`](docs/runtime-replacements.md). |
| `init <src-dir>` | Scan a tree and scaffold a starter `transpiler-config.json` + runtime-replacement stubs. See [`docs/init.md`](docs/init.md). |

## Docs

- [Quickstart](docs/quickstart.md) — Foundry project → working harness in
  five steps.
- [`init` guide](docs/init.md) — walkthrough of the bootstrap command,
  classification rules, and re-run behavior.
- [Configuration reference](docs/configuration.md) — every
  `transpiler-config.json` field.
- [Runtime API](docs/runtime.md) — `Contract`, `ContractContainer`,
  `globalEventStream`, helpers.
- [Runtime replacements](docs/runtime-replacements.md) — when to reach for
  one, how to author one.
- [Semantics](docs/semantics.md) — what's lost in translation. Required
  reading before shipping.
- [Extending](docs/extending.md) — contributor-facing; closing gaps in the
  transpiler itself.

## Testing

```bash
python3 -m transpiler.test_transpiler
```

Python unit tests cover the lexer, parser, codegen (Yul, type casts,
diagnostics, ABI encoding, interface generation, mappings), the dependency
resolver, and the `init` scan.

## License

AGPL-3.0.
