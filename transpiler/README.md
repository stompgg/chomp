# extruder

Feed Solidity in one end, get a shaped TypeScript mirror out the other.

**extruder** is a source-to-source transpiler that compiles Solidity contracts
into TypeScript you can run in Node or the browser. Point it at a Solidity
tree; get back a TypeScript module with one class per contract, a
dependency-injection container, and a runtime library that models storage,
events, and inter-contract calls.

> **Alpha warning.** No package releases yet — clone the repo and pin a git
> tag. Breaking changes may land between tags; read `MIGRATION.md` before
> bumping.

## Why

Running contracts under an EVM simulator gives you bytecode fidelity but
makes stepping through logic, hydrating mid-execution state, and writing
expressive tests painful. extruder produces plain TypeScript, so you can set
a breakpoint, patch a storage slot, or drive a turn loop at the speed of
regular JS — with Solidity semantics preserved where it matters (integer
types, storage slotting, events, inheritance).

Consumers have used it to build client-side game simulators, fuzz harnesses,
and differential-testing rigs against the real chain.

## Should I use this?

**Good fit** if you want:

- A TypeScript mirror of your contracts you can step through in a debugger,
  mutate freely, and run thousands of times per second.
- Expressive tests that read like business logic rather than EVM
  cheatcodes.
- Differential testing: compare TS output against an on-chain call and flag
  drift.
- A client-side simulator for a game or protocol so users can preview
  outcomes before signing.

**Bad fit** if you need:

- Bytecode-level or gas-exact accuracy.
- Storage-layout compatibility with a deployed contract (we do not model
  slots on-chain-compatible).
- To port complex `delegatecall` or proxy patterns — those don't survive
  translation.
- Production-grade safety. This is a simulation tool, not an execution
  environment. If the semantics gaps in [`docs/semantics.md`](docs/semantics.md)
  make you nervous, use the real EVM.

## Install

```bash
git clone <REPO_URL> ~/tools/extruder
cd ~/tools/extruder && pip install -r requirements.txt

# In your own Foundry project:
npm install -D viem vitest
```

## Quickstart

Bootstrap the config and scaffolded runtime-replacement stubs with one
command:

```bash
python3 ~/tools/extruder/sol2ts.py init src/ --yes
```

Then transpile:

```bash
python3 ~/tools/extruder/sol2ts.py src/ -o ts-output -d src --emit-metadata
```

See [`docs/quickstart.md`](docs/quickstart.md) for the full walkthrough.

## What it is, exactly

- **Parse → AST → emit TS.** Not bytecode, not an EVM.
- `uint*` / `int*` → `bigint`. `address` / `bytes*` → `string`. Mappings →
  `Record`. Structs → interfaces + factory. Enums → `as const` objects.
- Contracts become ES classes extending a runtime `Contract` base that
  carries `_contractAddress`, `_storage`, `_msg`, an event emitter, and a
  transient-storage reset hook.
- Inter-contract references are plain object references. There's no
  address-based dispatch unless you opt into it.

## What it is not

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

| Flag | Purpose |
|---|---|
| `input` *(positional)* | File or directory to transpile. |
| `-o`, `--output` | Output directory (default: `ts-output/`). |
| `-d`, `--discover` *(repeatable)* | Root(s) to scan for type discovery. Pass every source root you need cross-file resolution across. |
| `--stdout` | Print a single file to stdout instead of writing (debugging). |
| `--emit-metadata` | Also emit `factories.ts`. |
| `--metadata-only` | Skip TS generation, only write `factories.ts`. |
| `--overrides` | Path to `transpiler-config.json`. Defaults to the one next to `sol2ts.py`. |
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
- [FAQ](docs/faq.md) — currently empty; grows as real questions come in.

## Testing

```bash
python3 transpiler/test_transpiler.py
```

Python unit tests cover the lexer, parser, codegen (Yul, type casts,
diagnostics, ABI encoding, interface generation, mappings), the dependency
resolver, and the `init` scan. End-to-end verification of transpiled output
against a specific Solidity project is a consumer-side concern — write it
against your own `ts-output/` with whatever JS test runner you prefer (vitest
is a reasonable default; see the [quickstart](docs/quickstart.md)).

## License

AGPL-3.0.

## Origin

extruder started life as the internal tooling for
[CHOMP](https://github.com/owenshen/chomp), an on-chain battle game. The
transpiler was general-purpose from the beginning but wasn't extracted until
the scaffolding stabilized. Contributors: see CONTRIBUTORS (TBD).
