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

---

## Future Work

### High Priority

1. **Parser Improvements**
   - Handle `unchecked { ... }` blocks (currently causes parse errors)
   - Support function pointers and callbacks
   - Parse complex Yul/assembly blocks (currently skipped with warnings)
   - Handle `using ... for ...` directives
   - Support `try/catch` statements

2. **Missing Base Classes**
   - Transpile `BasicEffect.sol` for effect inheritance
   - Transpile `StatusEffect.sol` for status effect base
   - Create proper `IAbility` interface implementation

3. **Engine Integration**
   - Create full `Engine.ts` mock that matches Solidity `IEngine` interface
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

| File | Error | Cause |
|------|-------|-------|
| `Ownable.sol` | "Expected SEMICOLON but got LBRACE" | Complex Yul `if` statements in assembly |
| `StatBoosts.sol` | "Expected RPAREN but got MEMORY" | Function pointer syntax |
| `DefaultValidator.sol` | "Expected RBRACKET but got COMMA" | Multi-dimensional array syntax |
| `Strings.sol` | "Expected SEMICOLON but got LBRACE" | Unchecked blocks with complex assembly |
| `DefaultMonRegistry.sol` | "Expected SEMICOLON but got STORAGE" | Storage pointer declarations |

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
- [ ] Multi-level inheritance chains
- [ ] Library function calls with `using for`
- [ ] Effect removal during iteration
- [ ] Concurrent effect modifications

---

## Version History

### 2024-01-21 (Current)
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
