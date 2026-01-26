#!/usr/bin/env python3
"""
Unit tests for the sol2ts transpiler.

Run with: python3 test_transpiler.py
"""

import unittest
import sys
from sol2ts import Lexer, Parser, TypeScriptCodeGenerator, TypeRegistry


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


if __name__ == '__main__':
    # Run tests with verbosity
    unittest.main(verbosity=2)
