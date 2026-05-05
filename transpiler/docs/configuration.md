# `transpiler-config.json` reference

[`extruder init`](init.md) writes most of what you need. This doc is for
understanding and editing the fields by hand.

## Full schema

```jsonc
{
  "runtimeReplacements": [
    {
      "source": "lib/Ownable.sol",
      "reason": "Complex Yul for storage slot manipulation",
      "runtimeModule": "../runtime-replacements",
      "exports": ["Ownable"],
      "interface": { /* optional, describes the TS shape for downstream typecheck */ }
    }
  ],
  "interfaceAliases": {
    "IEngine": "Engine",
    "ICPURNG": null
  },
  "dependencyOverrides": {
    "DefaultRuleset": { "_effects": ["StaminaRegen"] }
  },
  "skipContracts": ["SpecificContract"],
  "skipFiles": ["path/relative/to/source-root.sol"],
  "skipDirs": ["some-dir"]
}
```

## Field: `runtimeReplacements`

An array of entries. Each tells the transpiler: "instead of generating TS for
this Solidity source, emit a stub that re-exports from this runtime module."
Use for Solidity whose Yul the generator can't handle, or whose semantics
need hand-written TypeScript.

Runtime replacements are explicit and take precedence over `skipFiles` and
`skipDirs`. If a file appears in both places, the transpiler still emits the
runtime re-export and does not parse that Solidity file.

| Field | Purpose |
|---|---|
| `source` | Path to the `.sol` file, relative to the source root. |
| `reason` | Free-form. Shows up in diagnostics and serves as a sticky note for future you. |
| `runtimeModule` | Relative path the generated stub imports from (e.g. `../runtime-replacements` → `import { Ownable } from '../runtime-replacements'`). |
| `exports` | Array of symbol names to re-export. |
| `interface` *(optional)* | Describes the replacement's public shape (class, methods, constants) so downstream typechecking works. Emitted automatically by `--emit-replacement-stub`. |

See [`runtime-replacements.md`](runtime-replacements.md) for the full
scaffolding + authoring workflow.

## Field: `interfaceAliases`

Map from interface name to concrete implementation class name. Used by the
`DependencyResolver` when a contract's constructor takes an interface — we
need a concrete class to instantiate.

```json
{
  "interfaceAliases": {
    "IEngine": "Engine",
    "IValidator": "DefaultValidator",
    "ICPURNG": null
  }
}
```

`null` is a signal, not a value: it means the interface is self-referential
or gets wired at runtime (passed as `address(0)` at deploy time). The
resolver uses the `"@self"` sentinel internally so factory generation can
skip the parameter.

`init` fills this in automatically for every interface with exactly one
implementer; you can edit by hand when there are multiple implementers or
when the real implementation lives outside the source tree.

## Field: `dependencyOverrides`

Per-contract, per-parameter manual mappings. Highest priority — always
wins over aliases, name inference, and heuristics.

```json
{
  "dependencyOverrides": {
    "DefaultRuleset": {
      "_effects": ["StaminaRegen"]
    }
  }
}
```

Use when:
- The alias doesn't apply to this specific usage (e.g., the contract wants
  a specific `StaminaRegen`, not any `IEffect`).
- The resolver's name-inference heuristic makes the wrong guess.
- The parameter accepts an array — the JSON value is a list of concrete
  class names, one per array element.

## Field: `skipContracts`

Contracts listed here are excluded from code generation and the factory
registry. The file is still parsed, and other contracts in the same file
still transpile. Use for contracts that would otherwise be transpiled but
you don't want in your simulator (e.g., legacy migration contracts).

## Field: `skipFiles`

Files listed here are skipped at the filesystem level — never parsed,
never transpiled, unless the same file has a `runtimeReplacements` entry.
Nothing from the file is available for cross-file type discovery. Use for
files that can't be parsed, files your simulator
doesn't need, or files that transpile incorrectly but also aren't worth
a runtime replacement.

Paths are relative to the source root passed to the CLI (or to the first
`-d` directory if multiple are given).

## Field: `skipDirs`

Whole directories to skip, same semantics as `skipFiles`. Use for big
domain-specific subtrees that don't belong in your simulator (e.g., a
`cpu/` or `gacha/` directory used only in production).

## Precedence rules

File-level transpilation:

1. `runtimeReplacements[source]` — emits a TypeScript re-export and avoids
   parsing the Solidity file.
2. `skipFiles` / `skipDirs` — skips files with no runtime replacement.
3. Normal parse + code generation.

Dependency resolution:

When multiple sources could decide a dependency:

1. `dependencyOverrides[Contract][param]` — always wins.
2. Parameter name inference (e.g. `_FROSTBITE_STATUS` → `FrostbiteStatus` if
   `FrostbiteStatus` is a known concrete class).
3. `interfaceAliases[InterfaceType]`.
4. Mechanical `I`-prefix strip (`IFoo` → `Foo` if `Foo` is a known concrete
   class).
5. Unresolved — logged to `unresolved-dependencies.json`.

`extruder init` runs exactly this chain dry at bootstrap time and prompts
for anything step 5 would catch.
