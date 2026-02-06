#!/usr/bin/env python3
"""
Unit tests for the sol2ts transpiler.

Run with: python3 -m pytest transpiler/test_transpiler.py
   or: cd .. && python3 transpiler/test_transpiler.py
"""

import sys
import os
# Add parent directory to path for proper imports - MUST be before other imports
# to avoid conflict with local 'types' package and Python's built-in 'types' module
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import unittest
from transpiler.lexer import Lexer
from transpiler.parser import Parser
from transpiler.codegen import TypeScriptCodeGenerator
from transpiler.type_system import TypeRegistry


class TestAbiEncodeFunctionReturnTypes(unittest.TestCase):
    """Test that abi.encode correctly infers types from function return values."""

    def test_abi_encode_with_string_returning_function(self):
        """Test that abi.encode with a string-returning function uses string type."""
        source = '''
        contract TestContract {
            function name() public pure returns (string memory) {
                return "Test";
            }

            function getKey(uint256 id) internal view returns (bytes32) {
                return keccak256(abi.encode(id, name()));
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        # The output should contain {type: 'string'} for the name() call
        self.assertIn("{type: 'string'}", output,
            "abi.encode should use string type for function returning string")
        # It should NOT use uint256 for the name() return value
        self.assertNotIn("[{type: 'uint256'}, {type: 'uint256'}]", output,
            "abi.encode should not use uint256 for string-returning function")

    def test_abi_encode_with_uint_returning_function(self):
        """Test that abi.encode with a uint-returning function uses uint type."""
        source = '''
        contract TestContract {
            function getValue() public pure returns (uint256) {
                return 42;
            }

            function getKey() internal view returns (bytes32) {
                return keccak256(abi.encode(getValue()));
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        # The output should contain {type: 'uint256'} for the getValue() call
        self.assertIn("{type: 'uint256'}", output,
            "abi.encode should use uint256 type for function returning uint256")

    def test_abi_encode_with_address_returning_function(self):
        """Test that abi.encode with an address-returning function uses address type."""
        source = '''
        contract TestContract {
            function getOwner() public pure returns (address) {
                return address(0);
            }

            function getKey() internal view returns (bytes32) {
                return keccak256(abi.encode(getOwner()));
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        # The output should contain {type: 'address'} for the getOwner() call
        self.assertIn("{type: 'address'}", output,
            "abi.encode should use address type for function returning address")

    def test_abi_encode_mixed_types(self):
        """Test that abi.encode correctly infers types for mixed arguments."""
        source = '''
        contract TestContract {
            function name() public pure returns (string memory) {
                return "Test";
            }

            function getKey(uint256 playerIndex, uint256 monIndex) internal view returns (bytes32) {
                return keccak256(abi.encode(playerIndex, monIndex, name()));
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        # The output should have uint256 for the first two args and string for name()
        self.assertIn("{type: 'uint256'}", output)
        self.assertIn("{type: 'string'}", output)
        # Check the specific pattern
        self.assertIn("[{type: 'uint256'}, {type: 'uint256'}, {type: 'string'}]", output,
            "abi.encode should correctly order types: uint256, uint256, string")


class TestAbiEncodeBasicTypes(unittest.TestCase):
    """Test that abi.encode correctly handles basic literal types."""

    def test_abi_encode_string_literal(self):
        """Test that abi.encode with a string literal uses string type."""
        source = '''
        contract TestContract {
            function getKey() internal view returns (bytes32) {
                return keccak256(abi.encode("hello"));
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn("{type: 'string'}", output,
            "abi.encode should use string type for string literals")

    def test_abi_encode_number_literal(self):
        """Test that abi.encode with a number literal uses uint256 type."""
        source = '''
        contract TestContract {
            function getKey() internal view returns (bytes32) {
                return keccak256(abi.encode(42));
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn("{type: 'uint256'}", output,
            "abi.encode should use uint256 type for number literals")


class TestContractTypeImports(unittest.TestCase):
    """Test that contracts used as types generate proper imports."""

    def test_contract_type_in_state_variable_generates_import(self):
        """Test that contract types used in state variables generate imports."""
        source = '''
        contract OtherContract {
            function doSomething() public {}
        }

        contract TestContract {
            OtherContract immutable OTHER;

            constructor(OtherContract _other) {
                OTHER = _other;
            }
        }
        '''

        # First, build a type registry that knows about OtherContract
        registry = TypeRegistry()
        registry.discover_from_source(source)

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        # Filter to just the TestContract for generation
        ast.contracts = [c for c in ast.contracts if c.name == 'TestContract']

        generator = TypeScriptCodeGenerator(registry)
        output = generator.generate(ast)

        # The output should import OtherContract
        self.assertIn("import { OtherContract }", output,
            "Contract types used in state variables should generate imports")

    def test_contract_type_in_constructor_param_generates_import(self):
        """Test that contract types in constructor params generate imports."""
        source = '''
        contract Dependency {
            function getValue() public returns (uint256) { return 42; }
        }

        contract TestContract {
            Dependency dep;

            constructor(Dependency _dep) {
                dep = _dep;
            }
        }
        '''

        registry = TypeRegistry()
        registry.discover_from_source(source)

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        ast.contracts = [c for c in ast.contracts if c.name == 'TestContract']

        generator = TypeScriptCodeGenerator(registry)
        output = generator.generate(ast)

        self.assertIn("import { Dependency }", output,
            "Contract types in constructor params should generate imports")


class TestYulTranspiler(unittest.TestCase):
    """Test the Yul/inline assembly transpiler."""

    def setUp(self):
        from transpiler.codegen.yul import YulTranspiler
        self.transpiler = YulTranspiler()

    def test_simple_sload_sstore(self):
        """Test basic storage read/write via .slot access."""
        yul_code = '''
            let slot := myVar.slot
            if sload(slot) {
                sstore(slot, 0)
            }
        '''
        result = self.transpiler.transpile(yul_code)
        self.assertIn('_getStorageKey(myVar', result)
        self.assertIn('_storageRead(myVar', result)
        self.assertIn('_storageWrite(myVar', result)

    def test_arithmetic_operations(self):
        """Test add, sub, mul, div, mod transpilation."""
        yul_code = 'let x := add(1, 2)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('+', result)

        yul_code = 'let x := sub(10, 3)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('-', result)

        yul_code = 'let x := mul(4, 5)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('*', result)

        yul_code = 'let x := div(10, 2)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('/', result)

        yul_code = 'let x := mod(10, 3)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('%', result)

    def test_bitwise_operations(self):
        """Test and, or, xor, shl, shr transpilation."""
        yul_code = 'let x := and(0xff, 0x0f)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('&', result)

        yul_code = 'let x := or(0xf0, 0x0f)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('|', result)

        yul_code = 'let x := shl(8, 1)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('<<', result)

        yul_code = 'let x := shr(8, 256)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('>>', result)

    def test_comparison_operations(self):
        """Test eq, lt, gt, iszero transpilation."""
        yul_code = 'let x := eq(1, 1)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('===', result)
        self.assertIn('1n', result)
        self.assertIn('0n', result)

        yul_code = 'let x := iszero(0)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('=== 0n', result)

    def test_nested_function_calls(self):
        """Test deeply nested Yul function calls."""
        yul_code = 'let x := add(mul(2, 3), shr(8, 0xff00))'
        result = self.transpiler.transpile(yul_code)
        # Should contain both * (from mul) and >> (from shr) and + (from add)
        self.assertIn('*', result)
        self.assertIn('>>', result)
        self.assertIn('+', result)

    def test_if_statement(self):
        """Test Yul if statement transpilation."""
        yul_code = '''
            if iszero(x) {
                sstore(slot, 42)
            }
        '''
        result = self.transpiler.transpile(yul_code)
        self.assertIn('if (', result)

    def test_for_loop(self):
        """Test Yul for loop transpilation."""
        yul_code = '''
            for { let i := 0 } lt(i, 10) { i := add(i, 1) } {
                sstore(i, i)
            }
        '''
        result = self.transpiler.transpile(yul_code)
        self.assertIn('while (', result)
        self.assertIn('let i =', result)

    def test_switch_case(self):
        """Test Yul switch/case transpilation."""
        yul_code = '''
            switch x
            case 0 { sstore(0, 1) }
            case 1 { sstore(0, 2) }
            default { sstore(0, 3) }
        '''
        result = self.transpiler.transpile(yul_code)
        self.assertIn('if (', result)
        self.assertIn('else', result)

    def test_mstore_mload_noop(self):
        """Test that mstore/mload are no-ops for simulation."""
        yul_code = 'mstore(0x00, 42)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('no-op', result.lower() if 'no-op' in result else result)

    def test_hex_literals(self):
        """Test hex literal parsing and generation."""
        yul_code = 'let x := 0xff'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('BigInt("0xff")', result)

    def test_let_without_value(self):
        """Test let declaration without initial value."""
        yul_code = 'let x'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('let x = 0n', result)

    def test_assignment(self):
        """Test variable reassignment."""
        yul_code = '''
            let x := 0
            x := add(x, 1)
        '''
        result = self.transpiler.transpile(yul_code)
        self.assertIn('x = ', result)

    def test_context_functions(self):
        """Test caller, callvalue, address transpilation."""
        yul_code = 'let sender := caller()'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('_msgSender()', result)

    def test_revert_generates_throw(self):
        """Test that revert() generates throw."""
        yul_code = 'revert(0, 0)'
        result = self.transpiler.transpile(yul_code)
        self.assertIn('throw new Error', result)

    def test_break_continue(self):
        """Test break and continue statements."""
        yul_code = '''
            for { let i := 0 } lt(i, 10) { i := add(i, 1) } {
                if eq(i, 5) { break }
                if eq(i, 3) { continue }
            }
        '''
        result = self.transpiler.transpile(yul_code)
        self.assertIn('break;', result)
        self.assertIn('continue;', result)

    def test_known_constants_prefix(self):
        """Test that known constants get Constants. prefix."""
        transpiler_with_constants = type(self.transpiler)(known_constants={'MY_CONST'})
        yul_code = 'let x := MY_CONST'
        result = transpiler_with_constants.transpile(yul_code)
        self.assertIn('Constants.MY_CONST', result)


class TestYulTokenizer(unittest.TestCase):
    """Test the Yul tokenizer."""

    def test_tokenize_basic(self):
        from transpiler.codegen.yul import YulTokenizer
        tokenizer = YulTokenizer('let x := 42')
        tokens = tokenizer.tokenize()
        self.assertEqual(len(tokens), 4)
        self.assertEqual(tokens[0].value, 'let')
        self.assertEqual(tokens[0].type, 'keyword')
        self.assertEqual(tokens[1].value, 'x')
        self.assertEqual(tokens[1].type, 'identifier')
        self.assertEqual(tokens[2].value, ':=')
        self.assertEqual(tokens[2].type, 'symbol')
        self.assertEqual(tokens[3].value, '42')
        self.assertEqual(tokens[3].type, 'number')

    def test_tokenize_hex(self):
        from transpiler.codegen.yul import YulTokenizer
        tokenizer = YulTokenizer('0xFF')
        tokens = tokenizer.tokenize()
        self.assertEqual(tokens[0].type, 'hex')
        self.assertEqual(tokens[0].value, '0xFF')

    def test_tokenize_function_call(self):
        from transpiler.codegen.yul import YulTokenizer
        tokenizer = YulTokenizer('add(1, 2)')
        tokens = tokenizer.tokenize()
        self.assertEqual(len(tokens), 6)  # add ( 1 , 2 )
        self.assertEqual(tokens[0].value, 'add')
        self.assertEqual(tokens[0].type, 'identifier')

    def test_tokenize_dot_access(self):
        from transpiler.codegen.yul import YulTokenizer
        tokenizer = YulTokenizer('x.slot')
        tokens = tokenizer.tokenize()
        self.assertEqual(len(tokens), 3)  # x . slot
        self.assertEqual(tokens[1].value, '.')

    def test_tokenize_comments(self):
        from transpiler.codegen.yul import YulTokenizer
        tokenizer = YulTokenizer('let x := 1 // comment\nlet y := 2')
        tokens = tokenizer.tokenize()
        # Comments should be skipped: let x := 1 let y := 2
        self.assertEqual(tokens[0].value, 'let')
        self.assertEqual(tokens[4].value, 'let')  # tokens: let(0) x(1) :=(2) 1(3) let(4)

    def test_tokenize_hex_string(self):
        from transpiler.codegen.yul import YulTokenizer
        tokenizer = YulTokenizer('hex"3d_60_2d"')
        tokens = tokenizer.tokenize()
        self.assertEqual(len(tokens), 1)
        self.assertEqual(tokens[0].type, 'hex')
        self.assertIn('3d602d', tokens[0].value)


class TestYulParser(unittest.TestCase):
    """Test the Yul parser."""

    def test_parse_let_with_slot(self):
        from transpiler.codegen.yul import YulTokenizer, YulParser, YulLet, YulSlotAccess
        tokens = YulTokenizer('let slot := myVar.slot').tokenize()
        ast = YulParser(tokens).parse()
        self.assertEqual(len(ast.statements), 1)
        self.assertIsInstance(ast.statements[0], YulLet)
        self.assertEqual(ast.statements[0].name, 'slot')
        self.assertIsInstance(ast.statements[0].value, YulSlotAccess)

    def test_parse_nested_calls(self):
        from transpiler.codegen.yul import YulTokenizer, YulParser, YulLet, YulFunctionCall
        tokens = YulTokenizer('let x := add(mul(1, 2), 3)').tokenize()
        ast = YulParser(tokens).parse()
        self.assertEqual(len(ast.statements), 1)
        let_stmt = ast.statements[0]
        self.assertIsInstance(let_stmt, YulLet)
        call = let_stmt.value
        self.assertIsInstance(call, YulFunctionCall)
        self.assertEqual(call.name, 'add')
        self.assertEqual(len(call.arguments), 2)
        self.assertIsInstance(call.arguments[0], YulFunctionCall)
        self.assertEqual(call.arguments[0].name, 'mul')

    def test_parse_if(self):
        from transpiler.codegen.yul import YulTokenizer, YulParser, YulIf
        tokens = YulTokenizer('if iszero(x) { sstore(0, 1) }').tokenize()
        ast = YulParser(tokens).parse()
        self.assertEqual(len(ast.statements), 1)
        self.assertIsInstance(ast.statements[0], YulIf)

    def test_parse_for(self):
        from transpiler.codegen.yul import YulTokenizer, YulParser, YulFor
        tokens = YulTokenizer('for { let i := 0 } lt(i, 10) { i := add(i, 1) } { }').tokenize()
        ast = YulParser(tokens).parse()
        self.assertEqual(len(ast.statements), 1)
        self.assertIsInstance(ast.statements[0], YulFor)

    def test_parse_switch(self):
        from transpiler.codegen.yul import YulTokenizer, YulParser, YulSwitch
        tokens = YulTokenizer('switch x case 0 { } case 1 { } default { }').tokenize()
        ast = YulParser(tokens).parse()
        self.assertEqual(len(ast.statements), 1)
        switch = ast.statements[0]
        self.assertIsInstance(switch, YulSwitch)
        self.assertEqual(len(switch.cases), 3)


class TestInterfaceTypeGeneration(unittest.TestCase):
    """Test that Solidity interfaces generate TypeScript interfaces with method signatures."""

    def test_interface_generates_ts_interface(self):
        """Test that a Solidity interface produces a TypeScript interface."""
        source = '''
        interface IFoo {
            function bar(uint256 x) external returns (uint256);
            function baz() external view returns (address);
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn('export interface IFoo', output)
        self.assertIn('bar(', output)
        self.assertIn('baz(', output)

    def test_interface_type_not_any(self):
        """Test that interface types don't collapse to 'any'."""
        source = '''
        interface IToken {
            function transfer(address to, uint256 amount) external returns (bool);
        }

        contract Wallet {
            IToken token;

            function doTransfer(address to, uint256 amount) public {
                token.transfer(to, amount);
            }
        }
        '''

        registry = TypeRegistry()
        registry.discover_from_source(source)

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        ast.contracts = [c for c in ast.contracts if c.name == 'Wallet']

        generator = TypeScriptCodeGenerator(registry)
        output = generator.generate(ast)

        # Interface type should NOT be 'any'
        self.assertNotIn(': any', output,
            "Interface types should not collapse to 'any'")
        # Should reference the actual interface name
        self.assertIn('IToken', output)


class TestMappingDetection(unittest.TestCase):
    """Test that mapping detection uses type information instead of name heuristics."""

    def test_mapping_type_detected_from_registry(self):
        """Test mapping detection from type registry."""
        source = '''
        contract TestContract {
            mapping(address => uint256) public balances;

            function getBalance(address user) public view returns (uint256) {
                return balances[user];
            }
        }
        '''

        registry = TypeRegistry()
        registry.discover_from_source(source)

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator(registry)
        output = generator.generate(ast)

        # Should compile without errors and handle mapping access
        self.assertIn('balances[', output)

    def test_non_mapping_variable_not_treated_as_mapping(self):
        """Test that non-mapping variables aren't incorrectly treated as mappings."""
        source = '''
        contract TestContract {
            uint256[] public myArray;

            function getValue(uint256 index) public view returns (uint256) {
                return myArray[index];
            }
        }
        '''

        registry = TypeRegistry()
        registry.discover_from_source(source)

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator(registry)
        output = generator.generate(ast)

        self.assertIn('myArray[', output)


class TestDiagnostics(unittest.TestCase):
    """Test the diagnostics/warning system."""

    def test_diagnostics_collect_warnings(self):
        from transpiler.codegen.diagnostics import TranspilerDiagnostics
        diag = TranspilerDiagnostics()
        diag.warn_modifier_stripped('onlyOwner', 'test.sol', line=10)
        diag.warn_try_catch_skipped('test.sol', line=20)

        self.assertEqual(diag.count, 2)
        self.assertEqual(len(diag.warnings), 2)

    def test_diagnostics_summary(self):
        from transpiler.codegen.diagnostics import TranspilerDiagnostics
        diag = TranspilerDiagnostics()
        diag.warn_modifier_stripped('onlyOwner', 'test.sol')
        diag.warn_modifier_stripped('nonReentrant', 'test.sol')
        diag.warn_try_catch_skipped('test.sol')

        summary = diag.get_summary()
        self.assertIn('modifier', summary)
        self.assertIn('try/catch', summary)

    def test_diagnostics_clear(self):
        from transpiler.codegen.diagnostics import TranspilerDiagnostics
        diag = TranspilerDiagnostics()
        diag.warn_modifier_stripped('test', 'test.sol')
        self.assertEqual(diag.count, 1)
        diag.clear()
        self.assertEqual(diag.count, 0)

    def test_diagnostics_no_warnings(self):
        from transpiler.codegen.diagnostics import TranspilerDiagnostics
        diag = TranspilerDiagnostics()
        summary = diag.get_summary()
        self.assertIn('No transpiler warnings', summary)

    def test_diagnostics_severity_levels(self):
        from transpiler.codegen.diagnostics import TranspilerDiagnostics, DiagnosticSeverity
        diag = TranspilerDiagnostics()
        diag.warn_modifier_stripped('test', 'test.sol')
        diag.info_runtime_replacement('test.sol', 'runtime/test.ts')

        warnings = [d for d in diag.diagnostics if d.severity == DiagnosticSeverity.WARNING]
        infos = [d for d in diag.diagnostics if d.severity == DiagnosticSeverity.INFO]
        self.assertEqual(len(warnings), 1)
        self.assertEqual(len(infos), 1)


class TestStructDefaultValues(unittest.TestCase):
    """Test struct default value generation."""

    def test_struct_generates_factory(self):
        """Test that structs generate createDefault factory functions."""
        source = '''
        struct MyStruct {
            uint256 value;
            address owner;
            bool active;
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn('export interface MyStruct', output)
        self.assertIn('createDefaultMyStruct', output)
        self.assertIn('value:', output)
        self.assertIn('owner:', output)
        self.assertIn('active:', output)


class TestTypeRegistryInterfaceMethods(unittest.TestCase):
    """Test that the type registry correctly tracks interface method signatures."""

    def test_interface_methods_tracked(self):
        """Test that interface method signatures are recorded in the registry."""
        source = '''
        interface IFoo {
            function bar(uint256 x) external returns (uint256);
            function baz(address a, bool b) external returns (bool);
        }
        '''

        registry = TypeRegistry()
        registry.discover_from_source(source)

        self.assertIn('IFoo', registry.interfaces)
        self.assertIn('IFoo', registry.interface_methods)

        methods = registry.interface_methods['IFoo']
        self.assertEqual(len(methods), 2)

        bar = next(m for m in methods if m['name'] == 'bar')
        self.assertEqual(bar['params'], [('x', 'uint256')])
        self.assertEqual(bar['returns'], ['uint256'])

        baz = next(m for m in methods if m['name'] == 'baz')
        self.assertEqual(baz['params'], [('a', 'address'), ('b', 'bool')])
        self.assertEqual(baz['returns'], ['bool'])


class TestOperatorPrecedence(unittest.TestCase):
    """Test that operator precedence is correctly maintained in transpiled output."""

    def test_binary_operations(self):
        """Test basic binary operations are transpiled."""
        source = '''
        contract TestContract {
            function calc(uint256 a, uint256 b) public pure returns (uint256) {
                return a + b * 2;
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn('+', output)
        self.assertIn('*', output)

    def test_ternary_operation(self):
        """Test ternary operator transpilation."""
        source = '''
        contract TestContract {
            function maxVal(uint256 a, uint256 b) public pure returns (uint256) {
                return a > b ? a : b;
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn('?', output)
        self.assertIn(':', output)

    def test_shift_operations(self):
        """Test bitwise shift operations."""
        source = '''
        contract TestContract {
            function shift(uint256 a) public pure returns (uint256) {
                return (a << 8) >> 4;
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn('<<', output)
        self.assertIn('>>', output)


class TestTypeCastGeneration(unittest.TestCase):
    """Test that type casts generate correct TypeScript."""

    def test_uint256_cast(self):
        """Test uint256 type cast."""
        source = '''
        contract TestContract {
            function cast(int256 x) public pure returns (uint256) {
                return uint256(x);
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        # Should have BigInt wrapping for numeric type casts
        self.assertIn('BigInt', output)

    def test_address_cast(self):
        """Test address type cast."""
        source = '''
        contract TestContract {
            function getAddr(uint256 x) public pure returns (address) {
                return address(uint160(x));
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        # Should produce something for the address cast
        self.assertIn('getAddr', output)


if __name__ == '__main__':
    # Run tests with verbosity
    unittest.main(verbosity=2)
