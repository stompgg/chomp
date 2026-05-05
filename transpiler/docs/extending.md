# Extending extruder

If a gap in the [semantics](semantics.md) list blocks your use case, here's how
to close it. Most additions follow the same shape: pick a layer, add a helper,
wire it into codegen, add a test.

## Pick a layer

- **Runtime only** — cheapest. If the new behavior can live as a helper the
  generated code already calls (or could call with one minor tweak), add it to
  `runtime/` and export it from `runtime/index.ts`. No codegen changes.
- **Codegen + runtime** — needed when you have to change *how* a Solidity
  construct lowers. Add the helper to `runtime/`, then modify the relevant
  `codegen/` module to emit calls to it, and register the identifier in
  `ImportGenerator` so generated files pull it in.
- **Runtime replacement** — if the Solidity source is too gnarly to codegen at
  all, hand-write the module and add a `runtimeReplacements` entry. See
  [`runtime-replacements.md`](runtime-replacements.md). The
  `--emit-replacement-stub` CLI scaffolds the skeleton for you.

## Where things live

| Change | File |
|---|---|
| Operators, function calls, member/index access, literals, type casts at call sites | `codegen/expression.py` |
| Blocks, assignments, `if`/`for`/`while`, `emit`, `revert`, `delete` | `codegen/statement.py` |
| Type casts and numeric masking (`uint8(x)`, `address(x)`) | `codegen/type_converter.py` |
| Function bodies, modifiers, return shape | `codegen/function.py` |
| Contract classes, state vars, inheritance, mixins | `codegen/contract.py` |
| Structs, enums, constants | `codegen/definition.py` |
| Inline Yul | `codegen/yul.py` |
| `abi.encode` / `abi.decode` type inference | `codegen/abi.py` |
| Default import list for generated files | `codegen/imports.py` |
| Warnings emitted during transpilation | `codegen/diagnostics.py` (accessed via `CodeGenerationContext`) |
| `init` scan heuristics (red flags, MAYBE signals, interface inference) | `transpiler/init.py` |
| Storage, events, DI container, `Contract.at`, call proxy, BigInt helpers | `runtime/base.ts`, `runtime/index.ts` |

## Two examples

**Revert reason propagation** (small codegen tweak, runtime helper):

1. In `runtime/base.ts`, define `SolidityRevertError extends Error` carrying
   `reason: string` and `data: string`.
2. In `codegen/expression.py`, change the `require` lowering from
   `throw new Error(...)` to `throw new SolidityRevertError(<message>)`.
   Do the same for `RevertStatement` in `codegen/statement.py`, and for
   `revert CustomError(...)` encode the error selector + args into `data`.
3. Register `SolidityRevertError` in `ImportGenerator`'s runtime imports so
   generated files see the type.
4. Add a Python case in `test_transpiler.py` asserting the generator emits
   `throw new SolidityRevertError(...)` for `require` / `revert` statements.
   Runtime-behavior verification (catching the error, asserting `reason`)
   lives on the consumer side — there's no JS test suite in extruder itself.

**Overflow-checked arithmetic** (larger codegen change):

1. Add `checkedAdd(a: bigint, b: bigint, bits: number, signed: boolean)` (and
   friends) to `runtime/index.ts` that masks and throws on over/underflow.
   Export them.
2. In `codegen/expression.py`, find the binary-op lowering. For `+`/`-`/`*` on
   typed integer operands, emit `checkedAdd(a, b, w, s)` instead of `(a + b)`.
   This requires the generator to know the static type of each operand — check
   whether `ExpressionGenerator` already carries that and plumb it through
   from `TypeRegistry` if not.
3. Register the helpers in `ImportGenerator` so generated files import them by
   default.
4. Consider gating behind a CLI flag or `transpiler-config.json` key so
   existing projects don't break, with a diagnostic (`W005`) when the check
   is disabled.
5. Add Python tests in `test_transpiler.py` asserting the generator emits
   `checkedAdd(...)` for typed arithmetic operands. Runtime-level overflow
   testing belongs on the consumer side (their harness against their own
   `ts-output/`).

## Practical advice

- **Don't add what you don't need.** Every preserved semantic is code to
  maintain and a slowdown on every simulated call. The design goal is "fast
  and accurate enough for the simulation you need," not "a second EVM."
- **Prefer runtime fixes to codegen fixes.** Runtime code is easier to
  review, test, and roll back. Reach for codegen changes only when the
  construct's lowering itself is wrong.
- **Check `unresolved-dependencies.json` before suspecting codegen.** Missing
  factory entries are the most common symptom people misdiagnose as a
  transpilation bug; they're usually fixed with a `dependencyOverrides` entry,
  not a codegen change.
- **Measure before theorizing.** Transpile a one-file reproduction, diff the
  output, and look at the actual generated TypeScript. Debugging Solidity
  semantics by reading the codegen Python is harder than reading one file of
  TS output.
