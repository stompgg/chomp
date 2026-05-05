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

    def test_ast_diagnostics_visitor_collects_modifier_warnings(self):
        from transpiler.codegen.diagnostics import TranspilerDiagnostics, emit_ast_diagnostics

        source = '''
        contract TestContract {
            modifier onlyOwner() { _; }

            function guarded() public onlyOwner {
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        diag = TranspilerDiagnostics()
        emit_ast_diagnostics(ast, diag, 'TestContract.sol')

        self.assertEqual(len(diag.warnings), 2)
        self.assertTrue(all(w.code == 'W001' for w in diag.warnings))


class TestAstVisitor(unittest.TestCase):
    """Test generic AST visitor traversal."""

    def test_visitor_reaches_nested_statements_and_expressions(self):
        from transpiler.parser.visitor import ASTVisitor
        from transpiler.parser.ast_nodes import BinaryOperation, FunctionCall, Identifier

        source = '''
        contract TestContract {
            function run(uint256 x) public {
                if (x > 0) {
                    ping(x + 1);
                }
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        class RecordingVisitor(ASTVisitor):
            def __init__(self):
                self.binary_ops = []
                self.calls = []

            def visit_BinaryOperation(self, node: BinaryOperation):
                self.binary_ops.append(node.operator)
                return self.generic_visit(node)

            def visit_FunctionCall(self, node: FunctionCall):
                if isinstance(node.function, Identifier):
                    self.calls.append(node.function.name)
                return self.generic_visit(node)

        visitor = RecordingVisitor()
        visitor.visit(ast)

        self.assertIn('>', visitor.binary_ops)
        self.assertIn('+', visitor.binary_ops)
        self.assertIn('ping', visitor.calls)


class TestTranspilerConfig(unittest.TestCase):
    """Test the shared transpiler-config loader."""

    def test_config_loader_normalizes_runtime_and_dependency_fields(self):
        from transpiler.config import TranspilerConfig

        cfg = TranspilerConfig.from_dict({
            'runtimeReplacements': [{
                'source': 'lib\\Ownable.sol',
                'exports': ['Ownable'],
                'interface': {
                    'class': 'Ownable',
                    'methods': [{'name': 'owner'}],
                    'mixin': 'mixin code',
                },
            }],
            'skipFiles': ['test\\Fixture.sol'],
            'skipDirs': ['script\\deploy'],
            'dependencyOverrides': {'UsesFoo': {'_foo': 'Foo'}},
            'interfaceAliases': {'IFoo': 'Foo'},
        })

        self.assertTrue(cfg.runtime_replacement_for('src/lib/Ownable.sol'))
        self.assertTrue(cfg.should_skip_file('test/Fixture.sol'))
        self.assertTrue(cfg.should_skip_dir('script/deploy/Deploy.sol'))
        self.assertEqual(cfg.dependency_overrides['UsesFoo']['_foo'], 'Foo')
        self.assertEqual(cfg.interface_aliases['IFoo'], 'Foo')
        self.assertIn('Ownable', cfg.runtime_replacement_classes)
        self.assertEqual(cfg.runtime_replacement_methods['Ownable'], {'owner'})
        self.assertEqual(cfg.runtime_replacement_mixins['Ownable'], 'mixin code')

    def test_merge_config_preserves_existing_conflicts_and_adds_new_entries(self):
        from transpiler.config import merge_config_updates

        merged = merge_config_updates(
            {
                'skipFiles': ['legacy\\A.sol'],
                'interfaceAliases': {'IFoo': 'Foo'},
                'dependencyOverrides': {'UsesFoo': {'_foo': 'OldFoo'}},
                'runtimeReplacements': [{
                    'source': 'legacy\\Replacement.sol',
                    'exports': ['OldReplacement'],
                }],
            },
            skip_files=['new\\B.sol', 'legacy/A.sol'],
            interface_aliases={'IFoo': 'NewFoo', 'IBar': 'Bar'},
            dependency_overrides={
                'UsesFoo': {'_foo': 'NewFoo', '_bar': 'Bar'},
                'UsesBaz': {'_baz': ['Baz']},
            },
            runtime_replacements=[
                {'source': 'legacy/Replacement.sol', 'exports': ['Duplicate']},
                {'source': 'new/Replacement.sol', 'exports': ['NewReplacement']},
            ],
        )

        self.assertEqual(merged['skipFiles'], ['legacy/A.sol', 'new/B.sol'])
        self.assertEqual(merged['interfaceAliases']['IFoo'], 'Foo')
        self.assertEqual(merged['interfaceAliases']['IBar'], 'Bar')
        self.assertEqual(merged['dependencyOverrides']['UsesFoo']['_foo'], 'OldFoo')
        self.assertEqual(merged['dependencyOverrides']['UsesFoo']['_bar'], 'Bar')
        self.assertEqual(merged['dependencyOverrides']['UsesBaz']['_baz'], ['Baz'])
        self.assertEqual(len(merged['runtimeReplacements']), 2)
        self.assertEqual(
            merged['runtimeReplacements'][1]['source'],
            'new/Replacement.sol',
        )

    def test_dependency_resolver_uses_shared_config_loader(self):
        import tempfile
        from pathlib import Path
        from transpiler.dependency_resolver import DependencyResolver

        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'transpiler-config.json'
            path.write_text('''{
              "dependencyOverrides": {"UsesFoo": {"_foo": "Foo"}},
              "interfaceAliases": {"IBar": "Bar"}
            }''')

            resolver = DependencyResolver(
                overrides_path=str(path),
                known_classes={'Foo', 'Bar'},
            )

        self.assertEqual(resolver.overrides['UsesFoo']['_foo'], 'Foo')
        self.assertEqual(resolver.interface_aliases['IBar'], 'Bar')

    def test_transpiler_uses_override_config_for_skip_files(self):
        import tempfile
        from pathlib import Path
        from transpiler.sol2ts import SolidityToTypeScriptTranspiler

        with tempfile.TemporaryDirectory() as td:
            tree = Path(td)
            (tree / 'A.sol').write_text('contract A { function a() public {} }')
            (tree / 'B.sol').write_text('contract B { function b() public {} }')
            config_path = tree / 'transpiler-config.json'
            config_path.write_text('{"skipFiles": ["B.sol"]}')

            transpiler = SolidityToTypeScriptTranspiler(
                source_dir=str(tree),
                output_dir=str(tree / 'out'),
                discovery_dirs=[str(tree)],
                overrides_path=str(config_path),
            )
            results = transpiler.transpile_directory()

        self.assertEqual(len(results), 1)
        self.assertTrue(any(path.endswith('A.ts') for path in results))
        self.assertFalse(any(path.endswith('B.ts') for path in results))

    def test_runtime_replacement_wins_over_skip_file_and_avoids_parse(self):
        import tempfile
        from pathlib import Path
        from transpiler.sol2ts import SolidityToTypeScriptTranspiler

        with tempfile.TemporaryDirectory() as td:
            tree = Path(td)
            (tree / 'Replaced.sol').write_text('contract Replaced {')
            config_path = tree / 'transpiler-config.json'
            config_path.write_text('''{
              "runtimeReplacements": [{
                "source": "Replaced.sol",
                "runtimeModule": "../runtime-replacements",
                "exports": ["Replaced"],
                "reason": "test replacement"
              }],
              "skipFiles": ["Replaced.sol"]
            }''')

            transpiler = SolidityToTypeScriptTranspiler(
                source_dir=str(tree),
                output_dir=str(tree / 'out'),
                overrides_path=str(config_path),
            )
            results = transpiler.transpile_directory()

        self.assertEqual(len(results), 1)
        output = next(iter(results.values()))
        self.assertIn("export { Replaced } from '../runtime-replacements';", output)


class TestPackaging(unittest.TestCase):
    """Test standalone package metadata."""

    def test_pyproject_declares_console_script_and_package_data(self):
        import tomllib
        from pathlib import Path

        project_root = Path(__file__).parent
        pyproject = tomllib.loads((project_root / 'pyproject.toml').read_text())

        self.assertEqual(
            pyproject['project']['scripts']['extruder'],
            'transpiler.sol2ts:main',
        )

        package_data = set(pyproject['tool']['setuptools']['package-data']['transpiler'])
        self.assertIn('runtime/*.ts', package_data)
        self.assertIn('docs/*.md', package_data)
        self.assertIn('transpiler-config.json', package_data)

        self.assertTrue((project_root / 'runtime' / 'index.ts').exists())
        self.assertTrue((project_root / 'docs' / 'quickstart.md').exists())
        self.assertTrue((project_root / 'transpiler-config.json').exists())


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


class TestDeleteGeneration(unittest.TestCase):
    """Test Solidity delete semantics in generated TypeScript."""

    def test_delete_array_element_zero_writes(self):
        source = '''
        contract TestContract {
            uint256[] values;

            function clear(uint256 index) public {
                delete values[index];
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn('this.values[Number(index)] = 0n;', output)
        self.assertNotIn('delete this.values', output)

    def test_delete_state_variable_zero_writes(self):
        source = '''
        contract TestContract {
            bool enabled;

            function clear() public {
                delete enabled;
            }
        }
        '''

        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        generator = TypeScriptCodeGenerator()
        output = generator.generate(ast)

        self.assertIn('this.enabled = false;', output)
        self.assertNotIn('delete this.enabled', output)


class TestTranspileDirectoryCaching(unittest.TestCase):
    """Test that directory transpilation reuses parsed ASTs after discovery."""

    def test_directory_transpile_parses_each_file_once(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        from transpiler.sol2ts import SolidityToTypeScriptTranspiler, Parser as Sol2TsParser

        with tempfile.TemporaryDirectory() as td:
            tree = Path(td)
            (tree / 'A.sol').write_text('contract A { function a() public {} }')
            (tree / 'B.sol').write_text('contract B { function b() public {} }')

            parse_count = [0]
            original_parse = Sol2TsParser.parse

            def counted_parse(parser_self):
                parse_count[0] += 1
                return original_parse(parser_self)

            with patch.object(Sol2TsParser, 'parse', counted_parse):
                transpiler = SolidityToTypeScriptTranspiler(
                    source_dir=str(tree),
                    output_dir=str(tree / 'out'),
                    discovery_dirs=[str(tree)],
                )
                results = transpiler.transpile_directory()

        self.assertEqual(parse_count[0], 2)
        self.assertEqual(len(results), 2)


# =============================================================================
# extruder init — scan phase
# =============================================================================

class TestInitScan(unittest.TestCase):
    """Unit tests for `extruder init`'s file classification heuristics.

    These are the tests that let us change heuristics without regressing.
    Each case boils down to: "given this Solidity source, does the scan
    produce the expected verdict?"
    """

    def _classify(self, source: str, rel_path: str = 'Test.sol'):
        """Write a temp file with `source`, classify it, return the verdict."""
        import tempfile
        from pathlib import Path
        from transpiler.init import _classify_file
        with tempfile.NamedTemporaryFile(
            mode='w', suffix='.sol', delete=False
        ) as f:
            f.write(source)
            path = Path(f.name)
        try:
            verdict, _ast = _classify_file(path, rel_path)
            return verdict
        finally:
            path.unlink()

    def test_plain_contract_is_ok(self):
        source = '''
        contract Plain {
            uint256 x;
            function set(uint256 v) external { x = v; }
            function get() external view returns (uint256) { return x; }
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'OK')

    def test_path_under_test_dir_is_skip(self):
        from transpiler.init import _classify_file
        from pathlib import Path
        import tempfile
        with tempfile.NamedTemporaryFile(
            mode='w', suffix='.sol', delete=False
        ) as f:
            f.write('contract X {}')
            path = Path(f.name)
        try:
            v, _ = _classify_file(path, 'test/Foo.sol')
            self.assertEqual(v.verdict, 'SKIP')
        finally:
            path.unlink()

    def test_foundry_t_sol_is_skip(self):
        from transpiler.init import _classify_file
        from pathlib import Path
        import tempfile
        with tempfile.NamedTemporaryFile(
            mode='w', suffix='.sol', delete=False
        ) as f:
            f.write('contract X {}')
            path = Path(f.name)
        try:
            v, _ = _classify_file(path, 'Foo.t.sol')
            self.assertEqual(v.verdict, 'SKIP')
        finally:
            path.unlink()

    def test_array_allocation_is_not_flagged(self):
        """`new bytes(n)` and `new uint[](n)` are memory allocation, not
        contract deployment — should NOT trip the REPLACE flag."""
        source = '''
        contract AllocsArrays {
            function alloc(uint256 n) external pure returns (bytes memory, uint256[] memory) {
                bytes memory b = new bytes(n);
                uint256[] memory arr = new uint256[](n);
                return (b, arr);
            }
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'OK', f'reasons={v.reasons}')

    def test_contract_deployment_is_replace(self):
        """`new Foo()` actually deploys; we don't have a bytecode model."""
        source = '''
        contract Foo { constructor(uint256) {} }
        contract Factory {
            function make() external returns (Foo) { return new Foo(42); }
        }
        '''
        # Note: _classify walks both contracts; Factory has the new expression.
        v = self._classify(source)
        self.assertEqual(v.verdict, 'REPLACE')
        self.assertTrue(any('new Foo' in r for r in v.reasons))

    def test_ecrecover_call_is_replace(self):
        source = '''
        contract Verifies {
            function check(bytes32 h, uint8 v, bytes32 r, bytes32 s)
                external pure returns (address) {
                return ecrecover(h, v, r, s);
            }
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'REPLACE')
        self.assertTrue(any('ecrecover' in r for r in v.reasons))

    def test_low_level_call_is_replace(self):
        source = '''
        contract Forwarder {
            function fwd(address target, bytes calldata data) external
                returns (bool, bytes memory) {
                return target.call(data);
            }
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'REPLACE')
        self.assertTrue(any('.call()' in r for r in v.reasons))

    def test_yul_sload_sstore_alone_is_ok(self):
        """Magic-number slot constants + sload/sstore are now handled by the
        transpiler (bigint `_yulStorageKey` fix). No red flag expected."""
        source = '''
        contract UsesMagicSlot {
            uint256 private constant _OWNER_SLOT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927;
            function setOwner(address newOwner) external {
                assembly {
                    sstore(_OWNER_SLOT, newOwner)
                }
            }
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'OK', f'reasons={v.reasons}')

    def test_yul_keccak_for_slot_is_replace(self):
        """`sstore(keccak256(...), v)` collapses to slot 0 under the current
        no-memory-model scheme."""
        source = '''
        contract PerUserSlot {
            function set(uint256 v) external {
                assembly {
                    mstore(0x00, caller())
                    sstore(keccak256(0x00, 0x20), v)
                }
            }
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'REPLACE')
        self.assertTrue(any('keccak256' in r for r in v.reasons))

    def test_precompile_staticcall_is_replace(self):
        """`staticcall(gas(), 1, ...)` is ecrecover via the precompile."""
        source = '''
        contract UsesPrecompile {
            function recover(bytes32 h) external view returns (address r) {
                assembly {
                    mstore(0x00, h)
                    let ok := staticcall(gas(), 1, 0x00, 0x20, 0x00, 0x20)
                    r := mload(0x00)
                }
            }
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'REPLACE')
        self.assertTrue(any('precompile' in r for r in v.reasons))

    def test_interface_inference_single_impl(self):
        """Single implementer → IFACE_AUTO classification."""
        from transpiler.type_system import TypeRegistry
        from transpiler.init import _infer_interfaces, IFACE_AUTO
        src = '''
        interface IFoo { function bar() external; }
        contract FooImpl is IFoo { function bar() external {} }
        '''
        reg = TypeRegistry()
        reg.discover_from_source(src)
        mappings = _infer_interfaces(reg)
        m = next(m for m in mappings if m.interface_name == 'IFoo')
        self.assertEqual(m.classification, IFACE_AUTO)
        self.assertEqual(m.implementers, ['FooImpl'])

    def test_interface_inference_multi_impl_prompts(self):
        from transpiler.type_system import TypeRegistry
        from transpiler.init import _infer_interfaces, IFACE_PROMPT
        src = '''
        interface IFoo { function bar() external; }
        contract A is IFoo { function bar() external {} }
        contract B is IFoo { function bar() external {} }
        '''
        reg = TypeRegistry()
        reg.discover_from_source(src)
        mappings = _infer_interfaces(reg)
        m = next(m for m in mappings if m.interface_name == 'IFoo')
        self.assertEqual(m.classification, IFACE_PROMPT)
        self.assertEqual(sorted(m.implementers), ['A', 'B'])

    def test_interface_inference_many_impls_is_tag(self):
        from transpiler.type_system import TypeRegistry
        from transpiler.init import (
            _infer_interfaces, IFACE_TAG, TAG_INTERFACE_THRESHOLD,
        )
        # Build a source with TAG_INTERFACE_THRESHOLD implementers.
        n = TAG_INTERFACE_THRESHOLD
        src = 'interface IFoo { function bar() external; }\n'
        for i in range(n):
            src += f'contract C{i} is IFoo {{ function bar() external {{}} }}\n'
        reg = TypeRegistry()
        reg.discover_from_source(src)
        mappings = _infer_interfaces(reg)
        m = next(m for m in mappings if m.interface_name == 'IFoo')
        self.assertEqual(m.classification, IFACE_TAG)

    def test_dependency_resolver_dry_run_reports_ambiguous(self):
        """Constructor param whose interface has two implementers and no
        override should surface in unresolved_deps with both implementers as
        candidates."""
        import tempfile
        from pathlib import Path
        from transpiler.init import scan
        from transpiler.type_system import TypeRegistry

        src = '''
        interface IFoo { function bar() external; }
        contract FooA is IFoo { function bar() external {} }
        contract FooB is IFoo { function bar() external {} }
        contract UsesFoo {
            IFoo _foo;
            constructor(IFoo foo) { _foo = foo; }
        }
        '''
        with tempfile.TemporaryDirectory() as td:
            tree = Path(td)
            (tree / 'Sample.sol').write_text(src)
            reg = TypeRegistry()
            reg.discover_from_directory(str(tree))
            report = scan(tree, reg)

        deps = [d for d in report.unresolved_deps if d.contract_name == 'UsesFoo']
        self.assertEqual(len(deps), 1)
        d = deps[0]
        self.assertEqual(d.param_name, 'foo')
        self.assertEqual(d.type_name, 'IFoo')
        self.assertEqual(sorted(d.implementers), ['FooA', 'FooB'])

    def test_modifier_use_is_maybe_not_ok(self):
        """A contract whose functions apply modifiers transpiles fine but
        silently drops the access-control check — should surface as MAYBE."""
        source = '''
        contract HasModifier {
            address owner;
            modifier onlyOwner() { require(msg.sender == owner); _; }
            function setOwner(address newOwner) external onlyOwner {
                owner = newOwner;
            }
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'MAYBE')
        self.assertTrue(any('W001' in r for r in v.reasons))

    def test_receive_function_is_maybe(self):
        source = '''
        contract AcceptsEth {
            receive() external payable {}
            function foo() external {}
        }
        '''
        v = self._classify(source)
        self.assertEqual(v.verdict, 'MAYBE')
        self.assertTrue(any('W003' in r for r in v.reasons))

    def test_build_plan_skips_matching_existing_alias(self):
        """If existing config already has the alias set to the same value
        the scan suggests, the plan should not re-add it."""
        import tempfile
        from pathlib import Path
        from transpiler.init import scan, build_plan
        from transpiler.type_system import TypeRegistry

        src = '''
        interface IFoo { function bar() external; }
        contract Foo is IFoo { function bar() external {} }
        '''
        with tempfile.TemporaryDirectory() as td:
            tree = Path(td)
            (tree / 'Sample.sol').write_text(src)
            reg = TypeRegistry()
            reg.discover_from_directory(str(tree))
            report = scan(tree, reg)
        existing = {'interfaceAliases': {'IFoo': 'Foo'}}
        plan = build_plan(report, yes_all=True, existing_config=existing)
        self.assertNotIn('IFoo', plan.interface_aliases,
            'matching existing alias should be a silent no-op')

    def test_build_plan_preserves_existing_alias_on_conflict_under_yes(self):
        """Under --yes, a conflicting existing alias wins silently — the
        plan should not schedule an overwrite."""
        import tempfile
        from pathlib import Path
        from transpiler.init import scan, build_plan
        from transpiler.type_system import TypeRegistry

        src = '''
        interface IFoo { function bar() external; }
        contract Foo is IFoo { function bar() external {} }
        '''
        with tempfile.TemporaryDirectory() as td:
            tree = Path(td)
            (tree / 'Sample.sol').write_text(src)
            reg = TypeRegistry()
            reg.discover_from_directory(str(tree))
            report = scan(tree, reg)
        existing = {'interfaceAliases': {'IFoo': 'SomethingElse'}}
        plan = build_plan(report, yes_all=True, existing_config=existing)
        # Plan should NOT contain IFoo — existing value wins. Apply then
        # merges and preserves the existing entry.
        self.assertNotIn('IFoo', plan.interface_aliases)

    def test_dependency_resolver_dry_run_skips_resolved(self):
        """Single-implementer interfaces are resolved via the `I`-prefix-strip
        fallback path and should NOT appear in unresolved_deps."""
        import tempfile
        from pathlib import Path
        from transpiler.init import scan
        from transpiler.type_system import TypeRegistry

        src = '''
        interface IFoo { function bar() external; }
        contract Foo is IFoo { function bar() external {} }
        contract UsesFoo {
            IFoo _foo;
            constructor(IFoo foo) { _foo = foo; }
        }
        '''
        with tempfile.TemporaryDirectory() as td:
            tree = Path(td)
            (tree / 'Sample.sol').write_text(src)
            reg = TypeRegistry()
            reg.discover_from_directory(str(tree))
            report = scan(tree, reg)

        deps = [d for d in report.unresolved_deps if d.contract_name == 'UsesFoo']
        self.assertEqual(len(deps), 0, f'expected auto-resolution, got {deps}')


if __name__ == '__main__':
    # Run tests with verbosity
    unittest.main(verbosity=2)
