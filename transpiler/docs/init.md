# `extruder init` — project bootstrap

`extruder init <src-dir>` walks your Solidity tree, figures out what config you
need, and writes a starter `transpiler-config.json`.

```bash
cd /path/to/extruder
python3 -m transpiler init /path/to/your/foundry/project/src
# or non-interactive:
python3 -m transpiler init /path/to/your/foundry/project/src --yes
```

## What it produces

- **`transpiler-config.json`** at `./transpiler-config.json` (override with
  `--config-path`). Populated with `skipFiles`, `interfaceAliases`,
  `dependencyOverrides`, and `runtimeReplacements` entries derived from the
  scan.
- **Scaffolded runtime-replacement stubs** under `./runtime-replacements/`
  (override with `--stub-output-dir`) — one `.ts` file per contract that
  needs hand-written TypeScript. Fill in the bodies; see
  [`runtime-replacements.md`](runtime-replacements.md).
- **`.extruder-init-report.md`** — decisions made, decisions punted, and
  everything classified OK or MAYBE. Commit alongside the config.

## How classification works

Each `.sol` file under the source root gets one of four verdicts:

| Verdict | What triggers it | What happens |
|---|---|---|
| `OK` | No red flags, no degraded-fidelity warnings. | Transpile normally. |
| `SKIP` | Path matches `test/`, `script/`, `foundry-test/`, `*.t.sol`, `*.s.sol`, or nested `mocks/`. Checked before parse — no AST walk needed. | Added to `skipFiles`. |
| `REPLACE` | File either fails to parse, or its AST contains a semantic pattern the runtime can't model (see [red flags](#red-flags-that-force-replace) below). | Stub scaffolded; `runtimeReplacements` entry added. |
| `MAYBE` | Transpiles cleanly, but emits degraded-fidelity warnings: stripped modifiers (W001) or skipped receive/fallback (W003). | Listed in report; no config change. You decide whether to hand-audit or accept the drift. |

### Red flags that force `REPLACE`

The scan conservatively flags patterns the runtime cannot model accurately:

- **`ecrecover` calls** — the runtime helper throws rather than pretend-
  recover. Write a replacement that wraps real secp256k1 recovery (viem's
  `recoverAddress` or `@noble/curves`).
- **Low-level `.call()` / `.delegatecall()` / `.staticcall()` used as
  dispatch** — no ABI dispatch model in the runtime.
- **Yul `keccak256(...)` over memory** — no memory model, so these return
  `0n`. Any code that uses `keccak` for computed storage slots or hashing
  dynamic data needs a hand-written replacement.
- **EVM precompile calls via `staticcall(gas(), 1, ...)`** (ecrecover at 1,
  sha256 at 2, ripemd160 at 3, identity at 4). Same issue as `ecrecover`
  above.
- **Yul `create` / `create2`** — no bytecode model.
- **Solidity `new Foo(...)`** that deploys a contract (array allocations
  like `new bytes(n)` are fine; only contract deployment is flagged).

## How interface aliases are inferred

For every `interface I…`, `init` counts concrete implementers in the source
tree:

| Implementers | What init does |
|---|---|
| 0 | Ignored (probably an external ABI). |
| 1 | Auto-map: adds `interfaceAliases[IFoo] = FooImpl`. |
| 2 – 5 | Prompt the user to pick one; record the choice in the config. Under `--yes`, punted and listed in the report. |
| 6+ | Tag interface — too many implementers to alias meaningfully. No entry added; listed in the report. |

The threshold for "tag interface" lives in
`transpiler/init.py::TAG_INTERFACE_THRESHOLD` (default 6). Change it in code
if your project's conventions differ.

## How dependency overrides are filled in

After classifying files and picking aliases, `init` runs the real
`DependencyResolver` against every concrete contract's constructor. For each
`IType` parameter:

1. If the resolver maps it via existing rules (manual override, name
   inference like `_FROSTBITE_STATUS → FrostbiteStatus`, or the aliases
   just chosen), it's silently resolved — no config entry needed.
2. Otherwise, `init` looks up the interface's implementers. If there's
   exactly one, it auto-fills `dependencyOverrides[Contract][_param] =
   Impl`. Multiple implementers → prompt (or punt under `--yes`).
3. No implementers at all → punt; you'll need to add the override by hand.

## Re-running against an existing config

`init` merges non-destructively into whatever `transpiler-config.json`
already exists:

- `skipFiles` — union of existing + new.
- `interfaceAliases` — existing wins on conflict. Under interactive mode, a
  conflict prompts you to keep the existing value or accept the scan's new
  suggestion. Under `--yes`, existing silently wins and the conflict is
  logged in the report.
- `dependencyOverrides` — existing wins on conflict, same rules.
- `runtimeReplacements` — entries are added only if `source` is not already
  present.

Safe to run repeatedly. After adding a new Solidity file to your tree,
re-running `init` picks up any new flags without clobbering your manual
config edits.

## Flags

| Flag | Purpose |
|---|---|
| `--yes` | Non-interactive. Accepts all auto-classifiable decisions, punts anything ambiguous (multi-implementer aliases, dep-override conflicts, MAYBE files). Preserves existing config values on any conflict. |
| `--stub-output-dir DIR` | Where scaffolded runtime-replacement stubs land. Default: `./runtime-replacements`. |
| `--config-path PATH` | Where to write the config. Default: `./transpiler-config.json`. |

## When to re-run vs. edit by hand

Re-run `init` when:
- You've added new `.sol` files or a whole new library.
- You've added a new implementer of an existing interface (the scan will
  suggest the alias next time).
- You want to check whether any new red flags have crept into the tree.

Edit `transpiler-config.json` by hand when:
- You know the alias you want and the scan would prompt you anyway.
- You need a `dependencyOverrides` entry for a parameter with no
  implementers in the source tree (e.g., wired at runtime via
  `ContractContainer.registerSingleton`).
- You need to tweak `runtimeReplacements` metadata (the `reason` field, the
  `runtimeModule` path) — `init` scaffolds with `TODO` placeholders.
