# Runtime library reference

The runtime library provides the scaffolding every transpiled contract depends
on: the `Contract` base class, the DI container, storage simulation, event
emission, bigint and address helpers. It lives in `transpiler/runtime/` and is
copied into your project's `ts-output/runtime/` at transpile time — consumer
code imports from that local path, not from an npm package.

## What's in `ts-output/`

- **`runtime/`** — the base classes and helpers documented here. Copied in on
  every transpile.
- **Transpiled contracts** — one `.ts` per `.sol`, each exporting a class
  that extends `Contract`. Folder structure mirrors your Solidity source.
- **`factories.ts`** (from `--emit-metadata`) — a registry of every contract
  with its constructor dependencies plus a `setupContainer()` helper.

## `Contract` base class

Every transpiled class extends `Contract`. It provides:

| Field / method | Purpose |
|---|---|
| `_contractAddress: string` | Synthetic address assigned at construction (or stamped manually — see below). Setter updates the static address registry. |
| `_storage: Storage` | Key-value store used by Yul `sload`/`sstore` and by any hand-written state that wants slot semantics. |
| `_msg: { sender, value, data }` | Mutable — set before calling a method to spoof `msg.sender` / `msg.value`. |
| `_emitEvent(name, payload)` | Pushes a log entry onto `globalEventStream`. |
| `Contract.at(address)` *(static)* | Look up an instance by address. Throws if unregistered. Used by transpiled `IFoo(addr).bar()` calls. |
| `Contract.clearRegistry()` *(static)* | Wipe the address registry, transient storage state, and call-depth counter. Call between test runs. |
| `Contract._turnCallLog`, `Contract._stateChangeLog` *(static)* | Optional. Assign empty arrays before a call and read them back to capture method-level invocations and raw storage writes. |

### Contract addresses

Solidity code constantly resolves interfaces by address: `IFoo(addr).bar()`.
The transpiler preserves this via a static registry on the `Contract` base
class.

When a contract is constructed, the base class:

1. Assigns it a synthetic unique address if the constructor didn't receive
   one as its first argument.
2. Registers the instance in `Contract._addressRegistry` (a static
   `Map<string, Contract>`) keyed by that address.

Assigning `instance._contractAddress = newAddr` is a setter: it unregisters
the old address and re-registers under the new one. This is why you can
stamp an on-chain address onto an already-constructed instance and have it
"become" that address for dispatch purposes.

When transpiled code hits `IFoo(addr).bar()`, it lowers to
`(Contract.at(addr) as IFoo).bar()` — a registry lookup. If no instance is
registered at that address, the call throws.

Two common cases:

1. **Pure in-memory harness.** Leave addresses alone. Every resolved
   instance still has its auto-assigned synthetic address; anything passed
   around via return values, events, or constructor args lands in the
   registry automatically.
2. **Hybrid harness driven from on-chain state.** If you're hydrating from a
   deployed system, stamp real addresses onto resolved instances:

   ```ts
   for (const [name, address] of Object.entries(onchainAddresses)) {
     const instance = container.tryResolve(name);
     if (instance) (instance as any)._contractAddress = address;
   }
   ```

   Do this after `setupContainer` and after any manual `registerLazySingleton`
   overrides. The setter handles the registry update.

## `ContractContainer` — dependency injection

A small DI container. Methods:

| Method | Purpose |
|---|---|
| `registerSingleton(name, instance)` | Store an already-constructed instance. |
| `registerLazySingleton(name, deps, factory)` | Factory runs on first `resolve`; subsequent `resolve` calls return the cached instance. `deps` is an array of names the container resolves and passes to `factory` in order. |
| `registerFactory(name, deps, factory)` | Like `registerLazySingleton` but factory runs on every resolve — returns fresh instances. |
| `registerAlias(alias, target)` | Make `resolve(alias)` return the same object as `resolve(target)`. |
| `resolve(name)` | Get the instance. Throws on miss. |
| `tryResolve(name)` | Returns `undefined` on miss. |

Circular dependencies throw immediately with a trace.

## `factories.ts`

When you transpile with `--emit-metadata`, the tool generates:

```ts
export const contracts: Record<string, { cls: new (...args: any[]) => any; deps: string[] }> = {
  Engine: { cls: Engine, deps: [] },
  DefaultValidator: { cls: DefaultValidator, deps: ['Engine'] },
  // ...
};

export const interfaceAliases: Record<string, string> = {
  IEngine: 'Engine',
  IValidator: 'DefaultValidator',
  // ...
};

export function setupContainer(container: ContractContainer): void { /* ... */ }
```

`setupContainer(container)` iterates `contracts` and calls
`container.registerLazySingleton(name, deps, (...args) => new cls(...args))`,
then calls `registerAlias(iface, impl)` for every entry in `interfaceAliases`.

**What `setupContainer` can't do**: guess constructor arguments that aren't
other contracts. If your `Engine` takes
`new Engine(monsPerTeam, movesPerMon, timeout)`, its `deps` array is `[]` and
the default factory call is `new Engine()` — wrong. Re-register it yourself,
after `setupContainer`:

```ts
container.registerLazySingleton('Engine', [], () =>
  new contracts.Engine.cls(MONS_PER_TEAM, MOVES_PER_MON, TIMEOUT),
);
```

Re-registering a name replaces the previous entry. Order matters only in
that your overrides come after `setupContainer`.

## Putting it together

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

## Driver responsibilities

Transpiled contracts are just classes — nothing forces a turn-based loop or a
specific entry contract. Two audiences:

### Test harnesses

- **Event draining.** `globalEventStream.clear()` before a logical operation,
  `globalEventStream.getEvents()` after. Transient storage auto-resets on
  external-call depth 0→1 transitions via the `Contract` call proxy — you
  don't need to reset it yourself.
- **Call tracing.** Assign empty arrays to `Contract._turnCallLog` and
  `Contract._stateChangeLog` before a call; read them back afterwards.
  Useful for mapping low-level activity onto higher-level semantic events.
- **Sender spoofing.** Every `Contract` has a public `_msg`. Assign to it
  before invoking a method.
- **Mutators.** Methods whose names start with `__mutate*` are preserved
  verbatim through codegen. Add them in Solidity as back-door setters and
  call them to bypass access checks during tests.

### Client-side simulators

- **State hydration.** Write directly into an instance's `_storage` to
  fast-forward to mid-execution state; transpiled contracts treat `_storage`
  as the source of truth for reads.
- **Address stamping.** See [Contract addresses](#contract-addresses) above.
- **Registry cleanup.** Call `Contract.clearRegistry()` between runs.

## Helpers exported from `runtime/index.ts`

Numeric and address utilities:

- `uint8` … `uint256`, `int8` … `int256` — clamp a bigint or number to the
  appropriate Solidity width (matching `TypeConverter` at codegen time).
- `mask(value, bits)`, `toUnsigned(value, bits)`, `toSigned(value, bits)` —
  underlying primitives.
- `extractBits`, `insertBits`, `packBits`, `unpackBits` — bit-range helpers.
- `isZeroAddress`, `addressToUint`, `ADDRESS_ZERO`, `TOMBSTONE_ADDRESS`.

Hashing:

- `sha256(data)`, `sha256String(str)` — via viem.
- `blockhash(n)` — deterministic pseudo-hash for simulation.
- `ecrecover(...)` — throws with a pointer to runtime replacements; real
  recovery isn't modeled.
- `selfdestruct(_recipient)` — throws rather than silently no-op.

ABI encoding (re-exported from viem):

- `encodePacked`, `encodeAbiParameters`, `parseAbiParameters`.

Event plumbing:

- `globalEventStream` — shared `EventStream` instance. Call `.clear()` before
  a logical operation and `.getEvents()` after.

## Runtime replacements

The runtime ships reference replacements such as `Ownable.ts` and
`EnumerableSetLib.ts`. See [`runtime-replacements.md`](runtime-replacements.md)
for the full authoring workflow; the short version is that you scaffold via
`--emit-replacement-stub`, fill in bodies, and register in
`transpiler-config.json`.
