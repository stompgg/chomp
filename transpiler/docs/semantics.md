# Semantics

extruder is a source-to-source transpiler, not an EVM. Some things are NOT supported.

## What it supports

- **Parse → AST → emit TS.** Not bytecode, not an EVM. Semantics match Solidity
  only to a narrow degree (integer behavior, storage slotting via a simulated
  `Storage` class, inheritance as mixins, events).
- `uint*` / `int*` → `bigint`. `address` / `bytes*` → `string`.
  `mapping(K => V)` → `Record<string, V>` with factory-initialized defaults.
  Structs → interfaces + factory. Enums → TypeScript `enum`s.
- Contracts become ES classes extending a runtime `Contract` base that carries
  `_contractAddress`, `_storage`, `_msg`, an event emitter, and a
  transient-storage reset hook. Inter-contract references are plain object
  references; there's no address-based dispatch unless you opt into it.
- Inline Yul is supported for common cases
  (`sload`/`sstore`/arithmetic/bitwise/if/for/switch/nested calls, no-op
  `mstore`/`mload`). Anything more exotic is routed through a runtime
  replacement (see [`runtime-replacements.md`](runtime-replacements.md)).
- Events go to a shared `globalEventStream` you can drain per call.

## Codegen gaps

- No EVM execution, no storage-layout compatibility with on-chain.
- **Modifiers are stripped, not inlined.** Access control and `require` logic
  inside modifiers disappears. Diagnostic `W001` flags every occurrence so you
  can hand-audit.
- `try`/`catch` compiles to an empty block. `receive`/`fallback` are skipped
  (`W003`). User-defined operators are unrecognized.

## EVM semantics it does not preserve

These are runtime-behavior gaps rather than codegen gaps. Know them before you
trust a transpiled contract to behave like its on-chain counterpart:

- **Arithmetic overflow is not checked.** Solidity 0.8+ reverts on `a + b`
  overflowing a `uint8`; transpiled `bigint` grows unbounded. Explicit casts
  *are* masked — `uint8(x)` becomes `x & 0xff`, signed casts get two's-
  complement treatment at codegen time via `TypeConverter` — but there is no
  implicit bounds check after every arithmetic op. If you relied on
  revert-on-overflow as a safety net, add explicit casts or masks.
- **`require` and `revert` are plain `throw`.** `require(cond, "msg")` becomes
  `if (!cond) throw new Error("msg")`; bare `require(cond)` throws
  `"Require failed"`. `revert("msg")` and `revert CustomError(...)` throw
  generic `Error`s rather than Solidity-encoded revert data, and — per the
  codegen gap above — `try/catch` can't recover from them.
- **Division / modulo by zero** throws `RangeError`, not a Solidity panic.
  Still halts, different error type.
- **Out-of-bounds array access** returns `undefined` rather than reverting.
  Read-then-use code that relied on Solidity's bounds check will hit
  `TypeError` or silently operate on bogus values.
- **No gas.** `gasleft()`, gas-limited external calls, gas-based DoS
  mitigations, and `.gas()` modifiers are no-ops or unsupported. Contracts that
  rely on gas metering for correctness (not just cost) behave differently.
- **No ETH accounting.** `payable` is stripped. `msg.value` is tracked on the
  instance's `_msg` field so reads compile, but no value actually transfers
  and no balance accumulates.
- **No low-level dispatch.** `call`, `delegatecall`, `staticcall`, and
  `create2` emit placeholder constants — running code that depends on their
  return values behaves silently wrongly. `selfdestruct` and `ecrecover` now
  throw loudly with messages pointing at runtime replacements. Contract-to-
  contract invocation goes through ordinary method calls on the resolved
  instance — see [`runtime.md`](runtime.md#contract-addresses) for how
  `IFoo(addr)` lookups work.
- **Storage references don't auto-persist.** Solidity `storage` references
  write through automatically; plain TypeScript object references don't.
  Codegen emits `??=` where it detects the pattern, but hand-check anything
  with nested-mapping `storage` locals.
- **`delete` emits a best-effort default assignment** when the target type is
  known, so `delete arr[i]` becomes a zero/default write instead of a sparse
  JavaScript array hole. Unknown delete targets fall back to JavaScript
  `delete`. `arr.push(value)` returns JavaScript's new array length, and
  Solidity's storage-reference form `arr.push()` is not modeled.
- **Addresses are lowercased strings**, not EIP-55 checksummed. String
  equality works, but anything that validates EIP-55 needs explicit
  normalization.

## Solidity → TypeScript quick reference

| Solidity | TypeScript |
|---|---|
| `uint256 x = 5;` | `let x: bigint = 5n;` |
| `mapping(address => uint)` | `Record<string, bigint>` (factory-initialized) |
| `address(this)` | `this._contractAddress` |
| `IFoo(address(this))` | `this` |
| `msg.sender` | `this._msg.sender` |
| `keccak256(abi.encode(...))` | `keccak256(encodeAbiParameters(...))` (viem) |
| `type(uint256).max` | `(1n << 256n) - 1n` |

## Supported feature reference

- Contracts, libraries, interfaces, single and multiple inheritance (via mixins).
- State variables, constructors, functions, events.
- Enums, structs, constants, nested structs in mappings.
- All integer types, `address`, `bytes*`, `bool`, arrays, mappings.
- All operators; `abi.encode` / `abi.encodePacked` / `abi.decode` via viem;
  `keccak256`, `sha256`, `blockhash`.
- `msg.sender`, `msg.value`, `block.timestamp`, `tx.origin`.
- `type(T).max`, `type(T).min`.
- Transient storage (`TLOAD` / `TSTORE`), reset per call.
- Basic inline Yul.

## Lifecycle

```
src/*.sol ─► [Type Discovery] ─► [Lex] ─► [Parse] ─► [Codegen] ─► ts-output/*.ts
                   │                                      │
                   │                                      ├─► factories.ts    (--emit-metadata)
                   │                                      └─► [Dependency Resolver]
                   │
                   └─► TypeRegistry: enums, structs, constants, contracts
```

1. **Type discovery** — scan every `-d` root, build a cross-file registry so
   codegen can resolve qualified names in O(1).
2. **Runtime replacement check** — files listed in `transpiler-config.json`
   emit a re-export stub instead of parsed/generated output.
3. **Lex / Parse** — recursive-descent parser, one cached AST per generated
   file.
4. **Codegen** — `TypeScriptCodeGenerator` orchestrates specialized emitters:
   `TypeService` / `TypeConverter`, `ExpressionGenerator`, `StatementGenerator`,
   `FunctionGenerator`, `DefinitionGenerator`, `ContractGenerator`,
   `ImportGenerator`, `YulTranspiler`, `AbiTypeInferer`.
5. **Metadata + factories** (optional) — `MetadataExtractor` records each
   contract's constructor parameter types, `DependencyResolver` maps interface
   params to concrete implementations (via config overrides and naming
   heuristics), and `FactoryGenerator` emits `factories.ts`.
