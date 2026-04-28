# extruder Optimization Plan

This plan tracks larger internal cleanups for making `transpiler/` easier to
ship as a standalone package while keeping the public API stable.

Public API to preserve:

- CLI shape: `python3 -m transpiler ...`
- `SolidityToTypeScriptTranspiler(...)`
- `transpile_file()`, `transpile_directory()`, `write_output()`,
  `discover_types()`, `emit_replacement_stub()`
- `TypeScriptCodeGenerator` imports and compatibility shim methods
- Generated TypeScript class/runtime API

## Phase 0: Current Cleanup Baseline

Status: in progress on the current branch.

Done:

- Document module-based execution and remove direct-script instructions.
- Remove `--metadata-only`.
- Remove duplicate directory discovery call in CLI directory mode.
- Avoid rediscovering AST types for files already covered by discovery roots.
- Route primitive cast call lowering through `TypeConverter`.
- Generate best-effort Solidity-style `delete` default assignments.
- Fix stale docs around W002/W004, FAQ, enum output, runtime replacements, and
  `delete` behavior.
- Fix bundled `transpiler-config.json` strict JSON syntax.

Completed follow-up checks:

- Added focused regression tests for `delete` default assignment.
- Added focused regression tests for config loading and `--overrides` behavior.
- Runtime replacements now win over `skipFiles`/`skipDirs`; this is documented
  and covered by a regression test.

## Phase 1: Parse Once, Reuse ASTs

Status: initial implementation complete.

Goal: stop lexing/parsing the same Solidity files in separate type-discovery,
metadata, and generation paths.

Keep public API by introducing an internal session object, for example
`TranspileSession` or `ProjectCompilation`, owned by
`SolidityToTypeScriptTranspiler`.

Internal responsibilities:

- Discover source files once.
- Read file contents once.
- Parse each file into an AST once.
- Cache ASTs by resolved path.
- Build `TypeRegistry` from cached ASTs.
- Feed cached ASTs into codegen and metadata extraction.

Likely steps:

1. Add a private source-file collection helper that applies `skipFiles` and
   `skipDirs`.
2. Add a private `_parse_file_cached(path)` helper. **Done.**
3. Change discovery to build the registry from cached ASTs when possible.
   **Done.**
4. Change `transpile_directory()` to use the same cached ASTs. **Done.**
5. Keep `transpile_file()` behavior unchanged for callers that invoke it
   directly.

Current notes:

- `SolidityToTypeScriptTranspiler` now owns an `_ast_cache`.
- Type discovery through the transpiler uses cached ASTs instead of
  `TypeRegistry.discover_from_directory()`.
- `transpile_file()` reuses cached ASTs and remains callable directly.
- Regression coverage verifies directory transpilation parses each file once.
- A source-file collection helper is still worth adding before or during the
  config-loader phase so skip/replacement precedence has one path.

Success criteria:

- Existing tests pass.
- Direct `transpile_file()` still works without a prior directory scan.
- Directory transpilation parses each included file once in the normal path.

## Phase 2: Single Config Loader

Status: initial implementation complete.

Goal: make config behavior explicit and centralized.

Create a `TranspilerConfig` dataclass/module that loads and normalizes:

- `runtimeReplacements`
- runtime replacement classes/mixins/methods
- `dependencyOverrides`
- `interfaceAliases`
- `skipFiles`
- `skipDirs`

It should answer questions like:

- `should_skip_file(rel_path) -> bool`
- `should_skip_dir(rel_path) -> bool`
- `runtime_replacement_for(rel_path) -> Optional[Replacement]`
- `dependency_override(contract, param) -> ...`
- `interface_alias(name) -> ...`

Likely steps:

1. Move strict JSON loading and validation out of `sol2ts.py`. **Done.**
2. Reuse the same loader in `DependencyResolver`. **Done.**
3. Reuse the same loader in `init.py` merge/read paths. **Partially done:
   config reads now use the shared loader; write/merge logic remains in
   `init.py`.**
4. Normalize paths once, using POSIX-style relative paths. **Done for loader
   consumers.**
5. Make replacement-vs-skip precedence explicit.

Current notes:

- Added `transpiler/config.py` with `TranspilerConfig`.
- `sol2ts.py` keeps its historical public attributes while sourcing them from
  `TranspilerConfig`.
- `DependencyResolver` now loads dependency overrides and interface aliases
  through the shared loader, including legacy top-level `overrides`.
- `init.py` config reads and non-destructive write merges now go through the
  shared config module.
- Runtime replacements now take precedence over `skipFiles`/`skipDirs` and
  avoid parsing the replaced Solidity file.
- Added focused config-loader tests for normalization, resolver integration,
  config merges, `--overrides` skip behavior, and replacement precedence.

Remaining work:

- Consider exporting structured replacement entries instead of raw dicts once
  call sites are smaller.

Success criteria:

- No duplicated config parsing logic.
- Invalid config produces one clear warning/error path.
- `--overrides` semantics are no longer split between codegen and factories.

## Phase 3: Type Service

Status: complete.

Goal: consolidate type reasoning that was spread across generators.

`TypeConverter` is the single class for Solidity-to-TypeScript type
conversion, defaults, type-cast emission, and the higher-level semantic
decisions (expression type resolution, mapping/index handling, ABI type
mapping) that the generators rely on.

Success criteria:

- Generated output stays behaviorally equivalent.
- `delete`, cast, mapping, and ABI behavior all use one source of type truth.
- Generator classes lose type-analysis helper code.

Current notes:

- `TypeConverter` owns conversion, defaults, semantic access resolution,
  delete/mapping defaults, index conversion, and ABI type mapping. There is no
  separate `TypeService` class; the earlier inheritance shim has been removed
  and its methods absorbed into `TypeConverter`.
- `ExpressionGenerator` and `StatementGenerator` delegate type-driven
  decisions to the converter instead of carrying local helper implementations.
- `BaseGenerator` only owns indentation, qualified-name lookup, and padding
  formatters.
- `AbiTypeInferer` accepts an optional `type_converter` for shared
  Solidity-to-ABI string mapping while remaining usable standalone.
- `replacement_stub.py` instantiates `TypeConverter` directly for stub
  scaffolding.

## Phase 4: Shared AST Visitor

Goal: reduce repeated AST traversal code.

Registry discovery, metadata extraction, diagnostics, init red-flag scanning,
and future lint passes all walk similar AST shapes. Add a small visitor utility
that supports:

- SourceUnit
- ContractDefinition
- FunctionDefinition
- Statement trees
- Expression trees

Likely steps:

1. Add a minimal visitor in `parser/visitor.py` or `analysis/visitor.py`.
2. Port diagnostics scanning first; it is small and low risk.
3. Port `MetadataExtractor`.
4. Port init red-flag/MAYBE scanning.
5. Consider porting `TypeRegistry.discover_from_ast` last.

Success criteria:

- Traversal logic is shared.
- Each analysis pass contains only its own decisions.
- No AST node API changes required.

Current notes:

- Added `parser/visitor.py` with `ASTVisitor` and `iter_child_nodes`.
- Added traversal regression coverage for nested statements and expressions.
- Ported transpiler diagnostics to `AstDiagnosticVisitor`.
- Ported `MetadataExtractor` to `ASTVisitor` dispatch.
- Ported `extruder init` red-flag scanning to a visitor instead of a local
  child-iterator implementation.

Remaining work:

- Consider porting `TypeRegistry.discover_from_ast` after a real-world
  transpile comparison; it is broader and currently stable.

## Phase 5: Lowering Layer

Goal: simplify TypeScript emission by normalizing Solidity semantic constructs
before codegen.

This is the largest change and should wait until parse caching, config, and
type service are stable.

Candidate lowerings:

- `delete target` -> typed default assignment when resolvable.
- `require` / `assert` / `revert` -> explicit throw nodes.
- Primitive casts -> normalized cast nodes.
- Interface/address casts -> registry lookup nodes.
- Low-level calls -> explicit placeholder/fallback nodes.
- Mapping default reads and nested mapping initialization.

Public API stays the same; this is an internal AST-to-lowered-AST step between
parse and codegen.

Success criteria:

- Codegen modules become mostly straightforward TypeScript string emission.
- Unsupported/degraded semantics are easier to diagnose before emission.
- The lowering step can be tested independently on small AST snippets.

Current notes:

- Added `lowering.py` with an in-place AST transformer.
- `TypeScriptCodeGenerator.generate()` runs the lowering pass before emission.
- Primitive cast-style function calls such as `uint256(x)` and `address(x)`
  lower to explicit `TypeCast` nodes. The fallback path in
  `_handle_type_cast_call` was removed: primitive casts are *only* handled via
  the `TypeCast` node path, so the lowering pass is now load-bearing rather
  than opportunistic.
- Added focused lowering-layer regression coverage.

Deferred candidates (require IR work, not yet started):

- `delete` and mapping-default lowerings need typed semantic context; they
  remain in `TypeConverter` for now.
- `require` / `assert` / low-level call lowerings need dedicated lowered AST
  nodes or a clearer statement IR before they can be moved off the codegen
  path.
- Interface/address casts and registry lookup nodes likewise.

These deferred items are the bulk of what Phase 5 originally promised; only
primitive cast normalization has actually shipped. Picking them up requires
introducing new AST node types (e.g. `Throw`, `InterfaceCast`,
`MappingRead`) so the lowering pass has somewhere to lower *to*.

## Phase 6: Standalone Packaging

Goal: make `extruder` installable without changing current module execution.

Likely steps:

1. Add a package-specific `pyproject.toml` or root package metadata for
   `extruder`.
2. Add a console script entry point:

   ```toml
   [project.scripts]
   extruder = "transpiler.sol2ts:main"
   ```

3. Ensure package data includes:
   - `runtime/*.ts`
   - `docs/*.md`
   - default `transpiler-config.json`
4. Keep `python3 -m transpiler` working.
5. Update docs to say both `extruder ...` and `python3 -m transpiler ...` are
   supported once the console script exists.

Success criteria:

- Fresh checkout can run module CLI.
- Installed package can run `extruder`.
- Runtime files are present in built distributions.

Current notes:

- Added `transpiler/pyproject.toml` for the standalone `extruder` package
  without changing the root project metadata.
- Declared the `extruder = "transpiler.sol2ts:main"` console script.
- Included runtime TS files, docs, `transpiler-config.json`, and `tsconfig.json`
  as package data.
- Updated README and quickstart docs to show both installed `extruder ...` and
  source-checkout `python3 -m transpiler ...` usage.
- Added packaging metadata regression coverage.

## Implementation Order

Recommended order:

1. Phase 1: Parse once, reuse ASTs.
2. Phase 2: Single config loader.
3. Phase 3: Type service.
4. Phase 4: Shared AST visitor.
5. Phase 6: Standalone packaging.
6. Phase 5: Lowering layer.

The lowering layer is deliberately last: it has the biggest upside, but it is
easier and safer after type/config/traversal logic has one home.

## Test Strategy

Keep the current Python suite as the fast baseline, then add focused tests as
each phase lands:

- Parse-cache tests: count or instrument parse calls for directory transpile.
- Config-loader tests: valid config, invalid JSON, path normalization,
  replacement-vs-skip precedence.
- Type-service tests: defaults, casts, array indexes, mapping indexes, delete.
- Visitor tests: traversal hits nested statements/expressions exactly once.
- Packaging tests: `python3 -m transpiler --help`, console script help once
  packaging exists, and runtime package-data presence.
