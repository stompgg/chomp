# Solidity → TypeScript Transpiler
## AUTHOR: CLAUDE

Source-to-source transpiler that compiles Solidity contracts into TypeScript you can run in Node or the browser. Built to drive deterministic off-chain simulations of CHOMP battles, but the transpiler itself is project-agnostic — point it at any Solidity tree and it will produce a DI-ready TypeScript mirror.

### How you normally use it

A two-step loop:

1. **Transpile**: run `sol2ts.py` over your Solidity sources to (re)generate `ts-output/`. Re-run whenever `.sol` changes. The output is deterministic and idempotent, so it's safe in pre-commit hooks, watch loops, and agent pipelines.
2. **Drive**: in your consumer code, create a `ContractContainer`, have the generated `factories.ts` populate it, optionally override a few registrations for constructors the resolver can't guess, optionally stamp on-chain addresses onto the resolved instances, then call into them.

---

## Overview

### What it supports

- **Parse → AST → emit TS.** Not bytecode, not an EVM. Semantics match Solidity where it matters (integer behavior, storage slotting via a simulated `Storage` class, inheritance as mixins, events).
- `uint*`/`int*` → `bigint`. `address`/`bytes*` → `string`. `mapping(K => V)` → `Record<string, V>` with factory-initialized defaults. Structs → interfaces + factory. Enums → `as const` objects.
- Contracts become ES classes extending a runtime `Contract` base that carries `_contractAddress`, `_storage`, `_msg`, an event emitter, and a transient-storage reset hook. Inter-contract references are plain object references; there's no address-based dispatch unless you opt into it.
- Inline Yul is supported for common cases (sload/sstore/arith/bitwise/if/for/switch/nested calls, no-op `mstore`/`mload`). Anything more exotic is routed through a runtime replacement (see below).
- Events go to a shared `globalEventStream` you can drain per call.

### Codegen gaps

- No EVM execution, no storage-layout compatibility with on-chain.
- **Modifiers are stripped, not inlined.** Access control and `require` logic inside modifiers disappears. Diagnostic `W001` flags every occurrence so you can hand-audit.
- `try`/`catch` compiles to an empty block (`W002`). `receive`/`fallback` are skipped (`W003`). Function pointers are coerced to `any` (`W004`). User-defined operators are unrecognized.

### EVM semantics it does not preserve

These are runtime-behavior gaps rather than codegen gaps. Know them before you trust a transpiled contract to behave like its on-chain counterpart:

- **Arithmetic overflow is not checked.** Solidity 0.8+ reverts on `a + b` overflowing a `uint8`; transpiled `bigint` grows unbounded. Explicit casts *are* masked — `uint8(x)` becomes `x & 0xff`, signed casts get two's-complement treatment at codegen time via `TypeConverter` — but there is no implicit bounds check after every arithmetic op. If you relied on revert-on-overflow as a safety net, add explicit casts or masks.
- **`require` and `revert` are plain `throw`.** `require(cond, "msg")` becomes `if (!cond) throw new Error("Require failed")`; `revert("msg")` and `revert CustomError(...)` both become `throw new Error("Revert")`. Revert reasons and custom error data are not propagated, and — per the codegen gap above — `try/catch` can't recover from them.
- **Division / modulo by zero** throws `RangeError`, not a Solidity panic. Still halts, different error type.
- **Out-of-bounds array access** returns `undefined` rather than reverting. Read-then-use code that relied on Solidity's bounds check will hit `TypeError` or silently operate on bogus values.
- **No gas.** `gasleft()`, gas-limited external calls, gas-based DoS mitigations, and `.gas()` modifiers are no-ops or unsupported. Contracts that rely on gas metering for correctness (not just cost) behave differently.
- **No ETH accounting.** `payable` is stripped. `msg.value` is tracked on the instance's `_msg` field so reads compile, but no value actually transfers and no balance accumulates.
- **No low-level dispatch.** `call`, `delegatecall`, `staticcall`, `selfdestruct`, and `create2` are not supported. Contract-to-contract invocation goes through ordinary method calls on the resolved instance (see [Contract addresses](#contract-addresses) for how `IFoo(addr)` lookups work).
- **Storage references don't auto-persist.** Solidity `storage` references write through automatically; plain TypeScript object references don't. Codegen emits `??=` where it detects the pattern, but hand-check anything with nested-mapping `storage` locals.
- **`delete arr[i]` splices**, not zero-writes. `arr.push()` returns `undefined`, not the new length. Both differ from Solidity by enough to bite rarely-tested code paths.
- **Addresses are lowercased strings,** not EIP-55 checksummed. String equality works, but anything that validates EIP-55 needs explicit normalization.

### Lifecycle

```
src/*.sol ─► [Type Discovery] ─► [Lex] ─► [Parse] ─► [Codegen] ─► ts-output/*.ts
                   │                                      │
                   │                                      ├─► factories.ts    (--emit-metadata)
                   │                                      └─► [Dependency Resolver]
                   │
                   └─► TypeRegistry: enums, structs, constants, contracts
```

1. **Type discovery** — scan every `-d` root, build a cross-file registry so codegen can resolve qualified names in O(1).
2. **Lex / Parse** — recursive-descent parser, one AST per file.
3. **Codegen** — `TypeScriptCodeGenerator` orchestrates specialized emitters: `TypeConverter`, `ExpressionGenerator`, `StatementGenerator`, `FunctionGenerator`, `DefinitionGenerator`, `ContractGenerator`, `ImportGenerator`, `YulTranspiler`, `AbiTypeInferer`.
4. **Runtime replacement check** — files listed in `transpiler-config.json` emit a re-export stub instead of transpiled output.
5. **Metadata + factories** (optional) — `MetadataExtractor` records each contract's constructor parameter types, `DependencyResolver` maps interface params to concrete implementations (via config overrides and naming heuristics), and `FactoryGenerator` emits `factories.ts`.

### Module layout

```
transpiler/
├── sol2ts.py              # Entry point (SolidityToTypeScriptTranspiler)
├── transpiler-config.json # Runtime replacements, dep overrides, skip lists
├── lexer/                 # Tokenizer
├── parser/                # AST nodes + recursive-descent parser
├── type_system/           # TypeRegistry (cross-file type discovery)
├── codegen/               # Modular generators (contract, function, expression,
│                          #   statement, definition, imports, yul, abi, metadata)
├── dependency_resolver/   # Interface → concrete impl resolution for factories
├── runtime/               # TypeScript runtime library (Contract, Storage,
│                          #   ContractContainer, globalEventStream, plus the
│                          #   runtime-replacement implementations)
├── test/                  # Vitest integration suites
└── test_transpiler.py     # Python unit tests
```

---

## Using the transpiler in a Solidity project

The transpiler is a standalone Python package; it doesn't care which project it's pointed at as long as the sources parse. Usage is one command:

```bash
python3 /path/to/transpiler/sol2ts.py \
  solidity-src/ \
  -o ts-output \
  -d src \
  --emit-metadata
```

### Flags

| Flag | Purpose |
|---|---|
| `input` *(positional)* | File or directory to transpile. |
| `-o`, `--output` | Output directory (default: `transpiler/ts-output`). |
| `-d`, `--discover` *(repeatable)* | Root(s) to scan for type discovery. Pass every source root you need cross-file resolution across. |
| `--stdout` | Print a single file to stdout instead of writing (debugging). |
| `--emit-metadata` | Also emit `factories.ts`. |
| `--metadata-only` | Skip TS generation, only write `factories.ts`. |
| `--stub` *(repeatable)* | Generate a minimal stub for the named contract instead of its full body. |
| `--overrides` | Path to a config file. Defaults to `transpiler-config.json` next to `sol2ts.py`. |

### `transpiler-config.json`

One config file handles:

- **`runtimeReplacements`** — array of `{ source, runtimeModule, exports, reason, interface }`. The transpiler emits a stub re-exporting from `runtimeModule` instead of transpiling `source`. The `interface` block describes the replacement's public shape so downstream typechecking works. Use this for anything with Yul that the `YulTranspiler` can't handle.
- **`dependencyOverrides`** — `{ ContractName: { paramName: ImplName } }`. Forces a specific concrete type when `DependencyResolver` can't infer one (e.g. `DefaultRuleset._effects → [StaminaRegen]`).
- **`skipContracts`** — contracts excluded from output and from the factory registry.
- **`skipFiles`** / **`skipDirs`** — skipped at the filesystem level. Use for files the parser can't handle or anything you don't need in simulation.

### Dependency resolution

When `--emit-metadata` is set, the `DependencyResolver` has to turn each interface-typed constructor parameter (`IEngine _engine`) into a concrete name the DI container can resolve. It walks a fixed chain and takes the first hit:

1. **`dependencyOverrides`** in `transpiler-config.json` — explicit, per-contract, per-parameter. Always wins.
2. **Parameter-name inference** — conventions like `_FROSTBITE_STATUS` → `FrostbiteStatus`, validated against the set of known contracts.
3. **Default interface aliases** — a hardcoded map (`IEngine → Engine`, `IValidator → DefaultValidator`, etc.), with a final fallback that strips a leading `I` if the result is a known class.
4. **Fail** — unresolved entries are written to `unresolved-dependencies.json` and omitted from the factory. Fix them with an override or register the contract manually at runtime.

Anything the inference and alias steps can't resolve should end up in `dependencyOverrides`.

### Adding a new Solidity file

Most files need no config changes — just re-run the transpiler. You only need to touch `transpiler-config.json` if the new file:

- Uses Yul the `YulTranspiler` can't handle → add a `runtimeReplacements` entry with a TypeScript implementation.
- Takes an interface in its constructor the resolver can't map → add a `dependencyOverrides` entry.
- Shouldn't be in the simulator → `skipContracts` or `skipFiles`.

### Solidity → TypeScript quick reference

| Solidity | TypeScript |
|---|---|
| `uint256 x = 5;` | `let x: bigint = 5n;` |
| `mapping(address => uint)` | `Record<string, bigint>` (factory-initialized) |
| `address(this)` | `this._contractAddress` |
| `IFoo(address(this))` | `this` |
| `msg.sender` | `this._msg.sender` |
| `keccak256(abi.encode(...))` | `keccak256(encodeAbiParameters(...))` (viem) |
| `type(uint256).max` | `(1n << 256n) - 1n` |

---

## Wiring it up locally

The generated `ts-output/` is self-contained, but you still need to tell the runtime **which contracts exist** and **how to instantiate them**. `factories.ts` does most of that; the rest is a small amount of project-specific glue.

### What's in `ts-output/`

- **`runtime/`** — the `Contract` base class, `Storage`, the `ContractContainer` DI container, `globalEventStream`, and helpers (integer clamping, bit pack/unpack, address utilities, viem ABI re-exports). Copied in from `transpiler/runtime/` on every build.
- **Transpiled contracts** — one `.ts` per `.sol`, each exporting a class that extends `Contract`. Folder structure mirrors your Solidity source.
- **`factories.ts`** (from `--emit-metadata`) — a registry of every contract with its constructor dependencies, the interface-to-concrete alias map, and a `setupContainer()` function that wires them into a container. Details below.

### Dependency injection

`factories.ts` exports three things:

```ts
export const contracts: Record<string, { cls: new (...args: any[]) => any; deps: string[] }> = {
  Engine: { cls: Engine, deps: [] },
  DefaultValidator: { cls: DefaultValidator, deps: ['Engine'] },
  Tinderclaws: { cls: Tinderclaws, deps: ['BurnStatus', 'StatBoosts'] },
  // ...
};

export const interfaceAliases: Record<string, string> = {
  IEngine: 'Engine',
  IValidator: 'DefaultValidator',
  // ...
};

export function setupContainer(container: ContractContainer): void { /* ... */ }
```

`setupContainer(container)` iterates `contracts` and, for each entry, calls `container.registerLazySingleton(name, deps, (...args) => new cls(...args))`, then calls `registerAlias(iface, impl)` for every entry in `interfaceAliases`.

**Lazy singletons** mean the factory is not called until the first `container.resolve(name)` — at which point the container recursively resolves each declared dep, passes the resolved instances to the factory in order, caches the result, and returns it. Subsequent resolves return the cached instance. Circular dependencies throw immediately with a trace.

**Aliases** are not separate instances: `container.resolve('IEngine')` returns the same object as `container.resolve('Engine')`. This is how transpiled code written against interfaces gets a concrete implementation at runtime without knowing which one.

The container exposes the full set you'd expect: `registerSingleton` (already-constructed instance), `registerFactory` (non-singleton), `registerLazySingleton`, `registerAlias`, `resolve` (throws on miss), and `tryResolve` (returns `undefined` on miss).

**What `setupContainer` cannot do** is guess constructor arguments that aren't other contracts. If your `Engine` takes `new Engine(monsPerTeam, movesPerMon, timeout)`, its `deps` array is `[]` and the default factory call is `new Engine()` — wrong. Re-register it yourself, after `setupContainer`:

```ts
container.registerLazySingleton('Engine', [], () =>
  new contracts.Engine.cls(MONS_PER_TEAM, MOVES_PER_MON, TIMEOUT),
);
```

Re-registering a name replaces the previous entry. Order matters only in that your overrides come after `setupContainer`.

### Contract addresses

Solidity code constantly resolves interfaces by address: `IFoo(addr).bar()`. The transpiler preserves this via a static registry on the `Contract` base class.

Every `Contract` subclass has a `_contractAddress: string` field. When a contract is constructed, the base class:

1. Assigns it a synthetic unique address if the constructor didn't receive one as its first argument.
2. Registers the instance in `Contract._addressRegistry` (a static `Map<string, Contract>`) keyed by that address.

Assigning `instance._contractAddress = newAddr` is a setter: it unregisters the old address and re-registers under the new one. This is why you can stamp an on-chain address onto an already-constructed instance and have it "become" that address for dispatch purposes.

When transpiled code hits `IFoo(addr).bar()`, it lowers to `(Contract.at(addr) as IFoo).bar()`, which just does a registry lookup. If no instance is registered at that address, the call throws.

Two cases to care about:

1. **Pure in-memory harness.** Leave addresses alone. Every resolved instance still has its auto-assigned synthetic address, and any contract whose address is passed around via normal channels (return values, emitted events, constructor args) will be in the registry. This is enough for most local simulation.

2. **Hybrid harness driven from on-chain state.** If you're hydrating from a deployed system — for example, an engine returning a move contract's address that your UI matches against the on-chain deployment — you need the harness's addresses to match the chain's. Walk your address book and stamp each one onto the resolved instance:

   ```ts
   for (const [name, address] of Object.entries(onchainAddresses)) {
     const instance = container.tryResolve(name);
     if (instance) (instance as any)._contractAddress = address;
   }
   ```

   Do this after `setupContainer` and after any manual `registerLazySingleton` overrides. The setter handles the registry update.

Between test runs, call `Contract.clearRegistry()` to wipe the address registry, transient-instance tracking, and call-depth counter.

### Putting it together

```ts
import { ContractContainer } from './ts-output/runtime';
import { contracts, setupContainer } from './ts-output/factories';

// 1. Container with defaults from factories.ts
const container = new ContractContainer();
setupContainer(container);

// 2. Override contracts whose constructors take non-interface arguments
container.registerLazySingleton('MyEntryContract', [], () =>
  new contracts.MyEntryContract.cls(ARG_1, ARG_2),
);

// 3. (Optional) stamp on-chain addresses for hybrid harnesses
for (const [name, address] of Object.entries(onchainAddresses)) {
  const instance = container.tryResolve(name);
  if (instance) (instance as any)._contractAddress = address;
}

// 4. Resolve and drive
const entry = container.resolve('MyEntryContract') as any;
entry.someMethod(/* ... */);
```

### Driver responsibilities

Transpiled contracts are just classes — nothing forces a turn-based loop or any specific entry contract. The things your harness typically cares about:

- **Event draining**: `globalEventStream.clear()` before a logical operation, `globalEventStream.getEvents()` after. Transient storage auto-resets on external-call depth 0→1 transitions via the `Contract` call proxy — you don't need to reset it yourself.
- **Call tracing**: the `Contract` base exposes two static arrays, `Contract._turnCallLog` and `Contract._stateChangeLog`. Assign empty arrays before a call and read them back afterwards to capture method-level calls and raw storage writes. Useful for mapping low-level activity onto higher-level semantic events.
- **Sender spoofing**: every `Contract` instance has a public `_msg: { sender, value, data }`. Assign to it before invoking a method to control what `msg.sender` looks like inside the transpiled code.
- **State hydration**: to fast-forward to a mid-execution state, write directly into the instance's `_storage` — transpiled contracts treat it as the source of truth for reads.
- **Mutators**: methods whose names start with `__mutate*` are preserved verbatim. Add them in Solidity as back-door setters and call them from your harness to bypass access checks during tests.

For a complete worked example of this pattern applied to a specific engine, see `runtime/battle-harness.ts` — it's CHOMP-specific, but the container setup, address stamping, event draining, and call logging are all mechanics any consumer can mirror.

---

## Runtime replacements

Files whose Yul the transpiler can't handle are substituted at generation time. Current replacements (see `transpiler-config.json`):

| Source | Replacement | Reason |
|---|---|---|
| `lib/Ownable.sol` | `runtime/Ownable.ts` | Storage-slot manipulation + event logging in Yul; implemented as a mixin. |
| `lib/EnumerableSetLib.sol` | `runtime/EnumerableSetLib.ts` | Gas-optimized sets with inline slot arithmetic. |
| `lib/ECDSA.sol` | `runtime/ECDSA.ts` | Signature recovery via viem. |
| `lib/EIP712.sol` | `runtime/EIP712.ts` | Typed-data hashing; `chainId` pinned to 31337. |

To add a new replacement:

1. Implement it under `transpiler/runtime/<Name>.ts`.
2. Re-export it from `runtime/index.ts`.
3. Add a `runtimeReplacements` entry in `transpiler-config.json` with an `interface` block describing the public shape.

---

## Extending the transpiler

If a gap in the [EVM semantics](#evm-semantics-it-does-not-preserve) list blocks your use case, here's how to close it. Most additions follow the same shape: pick a layer, add a helper, wire it into codegen, add a test.

### Pick a layer

- **Runtime only** — cheapest. If the new behavior can live as a helper the generated code already calls (or could call with one minor tweak), add it to `runtime/` and export it from `runtime/index.ts`. No codegen changes.
- **Codegen + runtime** — needed when you have to change *how* a Solidity construct lowers. Add the helper to `runtime/`, then modify the relevant `codegen/` module to emit calls to it, and register the identifier in `ImportGenerator` so generated files pull it in.
- **Runtime replacement** — if the Solidity source is too gnarly to codegen at all, hand-write the module and add a `runtimeReplacements` entry. This is the standard escape hatch for complex Yul libraries.

### Where things live

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
| Storage, events, DI container, `Contract.at`, call proxy, BigInt helpers | `runtime/base.ts`, `runtime/index.ts` |

### Two examples

**Revert reason propagation** (small codegen tweak, runtime helper):

1. In `runtime/base.ts`, define `SolidityRevertError extends Error` carrying `reason: string` and `data: string`.
2. In `codegen/expression.py`, change the `require` lowering from `throw new Error("Require failed")` to `throw new SolidityRevertError(<message>)`. Do the same for `RevertStatement` in `codegen/statement.py`, and for `revert CustomError(...)` encode the error selector + args into `data`.
3. Register `SolidityRevertError` in `ImportGenerator`'s runtime imports so generated files see the type.
4. Add a vitest case that catches the error and asserts `reason` matches the Solidity source.

**Overflow-checked arithmetic** (larger codegen change):

1. Add `checkedAdd(a: bigint, b: bigint, bits: number, signed: boolean)` (and friends) to `runtime/index.ts` that masks and throws on over/underflow. Export them.
2. In `codegen/expression.py`, find the binary-op lowering. For `+`/`-`/`*` on typed integer operands, emit `checkedAdd(a, b, w, s)` instead of `(a + b)`. This requires the generator to know the static type of each operand — check whether `ExpressionGenerator` already carries that and plumb it through from `TypeRegistry` if not.
3. Register the helpers in `ImportGenerator` so generated files import them by default.
4. Consider gating behind a CLI flag or `transpiler-config.json` key so existing projects don't break, with a diagnostic (`W005`) when the check is disabled.
5. Add Python tests in `test_transpiler.py` asserting the generator emits `checkedAdd(...)` for typed arithmetic, plus vitest cases that trigger overflow and expect a throw.

### Practical advice

- **Don't add what you don't need.** Every preserved semantic is code to maintain and a slowdown on every simulated call. The design goal is "fast and accurate enough for the simulation you need," not "a second EVM."
- **Prefer runtime fixes to codegen fixes.** Runtime code is easier to review, test, and roll back. Reach for codegen changes only when the construct's lowering itself is wrong.
- **Check `unresolved-dependencies.json` before suspecting codegen.** Missing factory entries are the most common symptom people misdiagnose as a transpilation bug; they're usually fixed with a `dependencyOverrides` entry, not a codegen change.
- **Measure before theorizing.** Transpile a one-file reproduction, diff the output, and look at the actual generated TypeScript. Debugging Solidity semantics by reading the codegen Python is harder than reading one file of TS output.

---

## Supported feature reference

- Contracts, libraries, interfaces, single and multiple inheritance (via mixins).
- State variables, constructors, functions, events.
- Enums, structs, constants, nested structs in mappings.
- All integer types, `address`, `bytes*`, `bool`, arrays, mappings.
- All operators; `abi.encode` / `abi.encodePacked` / `abi.decode` via viem; `keccak256`, `sha256`, `blockhash`.
- `msg.sender`, `msg.value`, `block.timestamp`, `tx.origin`.
- `type(T).max`, `type(T).min`.
- Transient storage (`TLOAD`/`TSTORE`), reset per call.
- Basic inline Yul.

For what's **not** supported, see [Codegen gaps](#codegen-gaps) and [EVM semantics it does not preserve](#evm-semantics-it-does-not-preserve) near the top.

---

## Testing

```bash
# TypeScript integration suites (vitest)
cd transpiler
npm install
npx vitest run              # once
npx vitest                  # watch mode
npx vitest run test/integration.test.ts   # single file

# Python unit tests
python3 transpiler/test_transpiler.py
```

Vitest suites cover the transpiled Engine against mocked dependencies, inline move and ability behavior, mutator methods, and module-level type conversions. The Python suite covers ABI type inference, contract-type imports, Yul transpilation, lexer/parser behavior, interface and mapping type detection, diagnostics, and operator handling.
