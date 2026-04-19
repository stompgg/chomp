# Migration Plan — Extracting `extruder` as a Standalone Library

## 7. Milestones

Proposed ordering. Each is a PR-sized chunk.

### M0 — Repo split (physical)
- [ ] Create `extruder` repo with a copy of `transpiler/`.
- [ ] Strip Chomp-specific `skipFiles`, `skipDirs`, `dependencyOverrides` from the
      library's `transpiler-config.json`. Chomp keeps its own config.
- [x] ~~Delete `runtime/battle-harness.ts` from the library. (Move to Chomp.)~~
      Moved to `chomp/simulator/battle-harness.ts`.
- [x] ~~Move Chomp-specific vitest tests out of the transpiler tree.~~ All 30
      Chomp-specific vitest tests + `fixtures/mocks.ts` removed. Extruder
      doesn't ship a JS test suite: `package.json`, `package-lock.json`,
      `bun.lock`, `vitest.config.ts`, and `node_modules/` are all deleted.
      Extruder is a Python tool; regression coverage lives in
      `test_transpiler.py`. Consumer-side runtime behavior verification is
      the consumer's job, run against their own `ts-output/` with whatever
      JS test runner they prefer.
- [ ] Move `runtime/Ownable.ts`, `runtime/EIP712.ts`,
      `runtime/EnumerableSetLib.ts` into `examples/runtime-replacements/`.
      Also move `runtime/ECDSA.ts` into examples.
      Drop their `runtimeReplacements` entries from the library's shipped config.
      Chomp copies them into its own repo and re-adds its config entries.
- [ ] Chomp continues to use its vendored `transpiler/` directory — no consumer
      switchover yet.

### M1 — Core decontamination
- [x] ~~Remove `_DEFAULT_INTERFACE_ALIASES` hardcoded map.~~ **Done.**
      `DependencyResolver` now reads `interfaceAliases` from config. Chomp's
      `transpiler-config.json` re-adds the aliases Chomp needs (IEngine →
      Engine, etc.). Transpile output byte-identical.
- [x] ~~Remove `hashBattle`, `hashBattleOffer` from `codegen/expression.py:889`.~~
      Done via `TypeRegistry` return-type lookup instead of a config field — see §2b.
- [x] ~~Rewrite `sol2ts.py` docstring, `package.json` description.~~ **Done.**
      Docstring now leads with the extruder framing; `package.json` renamed to
      `extruder` at `0.1.0-alpha`.
- [x] ~~Chomp's `transpiler-config.json` adds its interface aliases back in.~~
      **Done.** Included above in the alias removal task.

### M2 — Clone-and-run hygiene
- [ ] Write `requirements.txt` pinning Python deps (currently managed via `uv`).
- [ ] Add a one-line install check in `extruder.py` that errors helpfully if deps are
      missing (e.g. pexpect, pillow, numpy).
- [ ] Confirm `python3 extruder.py --help` works from a fresh clone.

### M2.5 — Runtime-replacement stub flow (§2f)
- [x] ~~Remove or repurpose the dead `--stub <ContractName>` flag.~~ **Done.** Flag
      and `stubbed_contracts` plumbing removed from `sol2ts.py` (also removed from
      `SolidityToTypeScriptTranspiler.__init__`).
- [x] ~~Add `--emit-replacement-stub <ContractName> <path/to/file.sol>`.~~ **Done.**
      Implemented in `transpiler/codegen/replacement_stub.py` and wired through
      `sol2ts.py`. Emits a TypeScript class with mapped method signatures,
      `throw new Error('Not implemented')` bodies, default state-variable values,
      constants rendered as `static readonly` with literal values when the parser
      can extract them, local struct fields rendered as sibling TS interfaces, and
      Solidity overloads disambiguated with `_overloadN` suffixes + a TODO comment.
      Prints the ready-to-paste `runtimeReplacements` entry (including a
      registry-derived `interface` block) to stdout.
- [x] ~~Validate end-to-end~~ **Done.** Regenerated `Ownable.ts` / `ECDSA.ts` /
      `EIP712.ts` / `EnumerableSetLib.ts` from `src/lib/*.sol`; each stub
      type-checks cleanly against `runtime/base.ts` under `tsc --strict`. Chomp's
      normal transpile is byte-identical; full Python test suite stays green.
- [ ] Document the flow in `docs/runtime-replacements.md` with ECDSA as the worked
      example. (Follow-up in M3.)

### M2.75 — `extruder init` bootstrap command (§2g)
- [x] Scan phase (`transpiler/init.py::scan()`) — pure, returns `InitReport`.
- [x] Unit tests covering every verdict path, including false-positive guards
      (magic-number `sstore` → OK, not REPLACE; `new bytes(n)` → OK).
- [x] `build_plan` + `apply` split, with `Prompter` behind a mockable seam.
- [x] CLI wiring: `extruder init <src> [--yes] [--stub-output-dir] [--config-path]`.
- [x] Integrated with `--emit-replacement-stub` via an injected `stub_emitter`
      callable (keeps the module acyclic).
- [x] Dependency-resolver dry-run phase — `MetadataExtractor` + `DependencyResolver`
      walk every constructor; unresolved entries become prompts (or auto-mapped
      when a single implementer exists, or punted in `--yes` mode).
- [x] Dog-fooded against Chomp: 112 OK, 8 REPLACE (all legitimate), 0 false
      positives. Auto-maps 12 single-impl interfaces, flags `IAbility` +
      `IMoveSet` as tag interfaces, resolves 8 of 9 dep-dry-run entries via
      aliases, punts `GachaRegistry._MON_REGISTRY` (multi-impl).
- [x] Config merge-conflict prompts — plan consults the existing config and
      prompts on conflicting alias/override entries; under `--yes` the
      existing value wins silently and the conflict is logged.
- [x] AST-level MAYBE detection — files with modifiers (W001) or
      `receive`/`fallback` (W003) surface as MAYBE with specific reasons.
      Receive/fallback is detected via a source-text regex because the
      parser drops those tokens before the AST.
- [ ] Follow-up: trial-transpile-based MAYBE detection for W002 (try/catch)
      and W004 (function pointers). Would require running the generator;
      deferred until we see real user demand.

### M3 — Docs (see §6)
- [x] `README.md` rewritten (~160 lines, down from 370). Leads with the
      extruder framing and `extruder init`; full TOC links into `docs/`.
- [x] `docs/quickstart.md`, `docs/init.md`, `docs/configuration.md`,
      `docs/runtime-replacements.md`, `docs/runtime.md`,
      `docs/semantics.md`, `docs/extending.md` — all written.
- [x] `docs/faq.md` seeded with the common starter-question pointers;
      kept deliberately empty until real user questions arrive.

### M4 — Examples + tests
- [ ] `examples/erc20/` runnable example.
- [ ] Transpiler integration tests against the fixtures (`minimal`, `inheritance`,
      `yul`, `mappings`).

---

