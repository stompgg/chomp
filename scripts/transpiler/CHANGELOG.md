# Solidity to TypeScript Transpiler - Changelog

## Current Version

### What the Transpiler Supports

#### Core Language Features
- **Contracts, Libraries, Interfaces**: Full class generation with proper inheritance (`extends`)
- **State Variables**: Instance and static (`readonly`) properties with correct visibility
- **Functions**: Methods with parameters, return types, visibility modifiers (`public`, `private`, `protected`)
- **Constructors**: Including base constructor argument passing via `super(...)`
- **Enums**: Converted to TypeScript enums with numeric values
- **Structs**: Converted to TypeScript interfaces
- **Constants**: File-level and contract-level constants with proper prefixes

#### Type System
- **Integer Types**: `uint256`, `int32`, etc. → `bigint` with proper wrapping
- **Address Types**: → `string` (hex addresses)
- **Bytes/Bytes32**: → `string` (hex strings)
- **Booleans**: Direct mapping
- **Strings**: Direct mapping
- **Arrays**: Fixed and dynamic arrays with proper indexing (`Number()` conversion)
- **Mappings**: → `Record<string, T>` with proper key handling

#### Expressions & Statements
- **Binary/Unary Operations**: Arithmetic, bitwise, logical operators
- **Ternary Operator**: Conditional expressions
- **Function Calls**: Regular calls, type casts, struct constructors with named arguments
- **Member Access**: Property and method access with proper `this.` prefixes
- **Index Access**: Array and mapping indexing
- **Tuple Destructuring**: `const [a, b] = func()` pattern
- **Control Flow**: `if/else`, `for`, `while`, `do-while`, `break`, `continue`
- **Return Statements**: Single and tuple returns

#### Solidity-Specific Features
- **Enum Type Casts**: `Type(value)` → `Number(value) as Enums.Type`
- **Struct Literals**: `ATTACK_PARAMS({NAME: "x", ...})` → `{ NAME: "x", ... } as Structs.ATTACK_PARAMS`
- **Address Literals**: `address(0)` → `"0x0000...0000"`
- **Bytes32 Literals**: `bytes32(0)` → 64-char hex string
- **Type Max/Min**: `type(uint256).max` → computed BigInt value
- **ABI Encoding**: `abi.encode`, `abi.encodePacked`, `abi.decode` via viem
- **Hash Functions**: `keccak256`, `sha256` support

#### Import & Module System
- **Auto-Discovery**: Scans `src/` directory to discover types before transpilation
- **Smart Imports**: Generates imports for `Structs`, `Enums`, `Constants`, base classes, libraries
- **Library Detection**: Libraries generate static methods and proper imports

#### Code Quality
- **Qualified Names**: Automatic `Structs.`, `Enums.`, `Constants.` prefixes where needed
- **Class-Local Priority**: Class constants use `ClassName.CONST` over `Constants.CONST`
- **Internal Method Calls**: Functions starting with `_` get `this.` prefix automatically
- **Optional Base Parameters**: Base class constructors have optional params for inheritance

### Test Coverage

#### Unit Tests (`test/run.ts`)
- Battle key computation
- Turn order by speed
- Multi-turn battles
- Storage operations

#### E2E Tests (`test/e2e.ts`)
- **Status Effects**: ZapStatus (skip turn), BurnStatus (damage over time)
- **Forced Switches**: User switch (HitAndDip), opponent switch (PistolSquat)
- **Abilities**: UpOnly (attack boost on damage), ability activation on switch-in
- **Complex Scenarios**: Effect interactions, multi-turn battles with switches

#### Engine E2E Tests (`test/engine-e2e.ts`)
- **Core Engine**: Instantiation, method availability, battle key computation
- **Matchmaker Authorization**: Adding/removing matchmakers
- **Battle State**: Initialization, team setup, mon state management
- **Damage System**: dealDamage, HP reduction, KO detection
- **Storage**: setGlobalKV/getGlobalKV roundtrip, updateMonState

---

## Future Work

### High Priority

1. **Parser Improvements**
   - Support function pointers and callbacks
   - Parse complex Yul/assembly blocks (currently skipped with warnings)

2. **Missing Base Classes**
   - Create proper `IAbility` interface implementation

3. **Engine Integration** ✅ (Partially Complete)
   - ✅ Engine.ts transpiled and working with test suite
   - ✅ MappingAllocator.ts transpiled with proper defaults
   - Implement `StatBoosts` contract for stat modification
   - Add `TypeCalculator` for type effectiveness

### Medium Priority

4. **Advanced Features**
   - Modifier support (currently stripped, logic not inlined)
   - Event emission (currently logs to console)
   - Error types with custom error classes
   - Receive/fallback functions

5. **Type Improvements**
   - Better mapping key type inference
   - Fixed-point math support (`ufixed`, `fixed`)
   - User-defined value types
   - Function type variables

6. **Code Generation**
   - Inline modifier logic into functions
   - Generate proper TypeScript interfaces from Solidity interfaces
   - Support function overloading disambiguation

### Low Priority

7. **Tooling**
   - Watch mode for automatic re-transpilation
   - Source maps for debugging
   - Integration with existing TypeScript build pipelines
   - VSCode extension for inline preview

---

## Known Issues & Bugs to Investigate

### Parser Limitations

All previously known parser failures have been resolved. Files now transpiling correctly:
- ✅ `Ownable.sol` - Fixed Yul `if` statement handling
- ✅ `Strings.sol` - Fixed `unchecked` block parsing
- ✅ `DefaultMonRegistry.sol` - Fixed qualified type names and storage pointers
- ✅ `DefaultValidator.sol` - Fixed array literal parsing
- ✅ `StatBoosts.sol` - Fixed tuple patterns with leading commas
- ✅ `GachaRegistry.sol` - Fixed `using` directives with qualified names
- ✅ `BattleHistory.sol` - Fixed `using` directives with qualified names

Remaining parser limitations:
| Issue | Description |
|-------|-------------|
| Function pointers | Callback/function pointer syntax not yet supported |
| Complex Yul blocks | Some assembly patterns still skipped with warnings |

### Potential Runtime Issues

1. **`this` in Super Arguments**
   - `super(this._msg.sender, ...)` may fail if `_msg` isn't initialized before `super()`
   - Workaround: Ensure base `Contract` class initializes `_msg` synchronously

2. **Integer Division Semantics**
   - BigInt division truncates toward zero (same as Solidity)
   - Burn damage `hp / 16` becomes 0 when `hp < 16`, preventing KO from burn alone

3. **Mapping Key Types**
   - Non-string mapping keys need proper serialization
   - `bytes32` keys work but complex struct keys may not

4. **Array Length Mutation**
   - Solidity `array.push()` returns new length, TypeScript doesn't
   - `delete array[i]` semantics differ (Solidity zeros, TS removes)

5. **Storage vs Memory**
   - All TypeScript objects are reference types
   - Solidity `memory` copy semantics not enforced
   - Could cause unexpected aliasing bugs

### Tests to Add

- [ ] Negative number handling (signed integers)
- [ ] Overflow behavior verification
- [ ] Complex nested struct construction
- [ ] Multi-level inheritance chains (3+ levels)
- [ ] Effect removal during iteration
- [ ] Concurrent effect modifications
- [ ] Burn degree stacking mechanics
- [ ] Multiple status effects on same mon

---

## Version History

### 2026-01-21 (Current)
**Mapping Semantics (General-purpose transpiler fixes):**
- Nested mapping writes now auto-initialize parent objects (`mapping[a] ??= {};` before nested writes)
- Compound assignment on mappings now auto-initializes (`mapping[a] ??= 0n;` before `+=`)
- Mapping reads add default values for variable declarations (`?? defaultValue`)
- Fixed `bytes32` default to proper zero hex string (`0x0000...0000` not `""`)
- Fixed `address` default to proper zero address (`0x0000...0000` not `""`)

**Type Casting Fixes:**
- uint type casts now properly mask bits (e.g., `uint192(x)` masks to 192 bits)
- Prevents overflow issues when casting larger values to smaller uint types

**Engine Integration Tests:**
- Added comprehensive `engine-e2e.ts` test suite (17 tests)
- Tests cover: battle key computation, matchmaker authorization, battle initialization
- Tests cover: mon state management, damage dealing, KO detection, global KV storage
- Created `TestableEngine` class for proper test initialization

**Runtime Library Additions:**
- Added `mappingGet()` helper for mapping reads with default values
- Added `mappingGetBigInt()` for common bigint mapping pattern
- Added `mappingEnsure()` for nested mapping initialization

**Parser Fixes:**
- Added `UNCHECKED`, `TRY`, `CATCH` tokens and keyword handling
- Handle qualified library names in `using` directives (e.g., `EnumerableSetLib.Uint256Set`)
- Parse `unchecked` blocks as regular blocks (overflow checks not simulated)
- Skip `try/catch` statements (return empty block placeholder)
- Added `ArrayLiteral` AST node for `[val1, val2, ...]` syntax
- Fixed tuple declaration detection for leading commas (skipped elements like `(, , uint8 x)`)
- Handle qualified type names in variable declarations (e.g., `Library.StructName`)

**Yul Transpiler Fixes:**
- Added `_split_yul_args` helper for nested parentheses in function arguments
- Handle `caller()`, `timestamp()`, `origin()` built-in functions
- Added bounds checking for binary operation parsing

**Base Classes:**
- Successfully transpiling `BasicEffect.sol` - base class for all effects
- Successfully transpiling `StatusEffect.sol` - base class for status effects
- Successfully transpiling `BurnStatus.sol`, `ZapStatus.sol` and other status implementations

### 2026-01-20
- Added comprehensive e2e tests for status effects, forced switches, abilities
- Fixed base constructor argument passing in inheritance
- Fixed struct literals with named arguments
- Fixed class-local static constant references
- Added `this.` prefix heuristic for internal methods (`_` prefix)
- Implemented `TypeRegistry` for auto-discovery of types from source files
- Added `get_qualified_name()` helper for consistent type prefixing
- Removed unused `known_events` tracking

### Previous
- Initial transpiler with core Solidity to TypeScript conversion
- Basic lexer, parser, and code generator
- Runtime library with Storage, Contract base class, and utilities
