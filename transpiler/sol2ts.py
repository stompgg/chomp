#!/usr/bin/env python3
"""
Solidity to TypeScript Transpiler (Refactored)

This transpiler converts Solidity contracts to TypeScript for local simulation.
It's specifically designed for the Chomp game engine but can be extended for general use.

Key features:
- BigInt for 256-bit integer operations
- Storage simulation via objects/maps
- Bit manipulation helpers
- Yul/inline assembly support
- Interface and contract inheritance

Usage:
    python transpiler/sol2ts_refactored.py src/

This refactored version uses a modular architecture with separate packages for:
- lexer: Tokenization (tokens.py, lexer.py)
- parser: AST nodes and parsing (ast_nodes.py, parser.py)
- types: Type registry and mappings (registry.py, mappings.py)
- codegen: Code generation (generator.py + specialized generators)
"""

import json
from pathlib import Path
from typing import Optional, List, Dict, Set

# Import from refactored modules
from .lexer import Lexer
from .parser import Parser, SourceUnit
from .type_system import TypeRegistry
from .codegen import TypeScriptCodeGenerator
from .codegen.metadata import MetadataExtractor, FactoryGenerator


class SolidityToTypeScriptTranspiler:
    """Main transpiler class that orchestrates the conversion process."""

    def __init__(
        self,
        source_dir: str = '.',
        output_dir: str = './ts-output',
        discovery_dirs: Optional[List[str]] = None,
        stubbed_contracts: Optional[List[str]] = None,
        emit_metadata: bool = False
    ):
        self.source_dir = Path(source_dir)
        self.output_dir = Path(output_dir)
        self.parsed_files: Dict[str, SourceUnit] = {}
        self.registry = TypeRegistry()
        self.stubbed_contracts = set(stubbed_contracts or [])
        self.emit_metadata = emit_metadata

        # Metadata extraction for factory generation
        self.metadata_extractor = MetadataExtractor() if emit_metadata else None

        # Load runtime replacements configuration
        self.runtime_replacements: Dict[str, dict] = {}
        self.runtime_replacement_classes: Set[str] = set()
        self.runtime_replacement_mixins: Dict[str, str] = {}
        self.runtime_replacement_methods: Dict[str, Set[str]] = {}
        self._load_runtime_replacements()

        # Run type discovery on specified directories
        if discovery_dirs:
            for dir_path in discovery_dirs:
                self.registry.discover_from_directory(dir_path)

    def _load_runtime_replacements(self) -> None:
        """Load the runtime-replacements.json configuration file."""
        script_dir = Path(__file__).parent
        replacements_file = script_dir / 'runtime-replacements.json'

        if replacements_file.exists():
            try:
                with open(replacements_file, 'r') as f:
                    config = json.load(f)
                for replacement in config.get('replacements', []):
                    source_path = replacement.get('source', '')
                    if source_path:
                        self.runtime_replacements[source_path] = replacement
                        for export in replacement.get('exports', []):
                            self.runtime_replacement_classes.add(export)
                        interface = replacement.get('interface', {})
                        class_name = interface.get('class', '')
                        mixin_code = interface.get('mixin', '')
                        if class_name and mixin_code:
                            self.runtime_replacement_mixins[class_name] = mixin_code
                        methods = interface.get('methods', [])
                        if class_name and methods:
                            method_names = set(m.get('name', '') for m in methods if m.get('name'))
                            self.runtime_replacement_methods[class_name] = method_names
            except (json.JSONDecodeError, KeyError) as e:
                print(f"Warning: Failed to load runtime-replacements.json: {e}")

    def discover_types(self, directory: str, pattern: str = '**/*.sol') -> None:
        """Run type discovery on a directory of Solidity files."""
        self.registry.discover_from_directory(directory, pattern)

    def transpile_file(self, filepath: str, use_registry: bool = True) -> str:
        """Transpile a single Solidity file to TypeScript."""
        with open(filepath, 'r') as f:
            source = f.read()

        # Tokenize using the lexer module
        lexer = Lexer(source)
        tokens = lexer.tokenize()

        # Parse using the parser module
        parser = Parser(tokens)
        ast = parser.parse()

        self.parsed_files[filepath] = ast
        self.registry.discover_from_ast(ast)

        # Extract metadata for factory generation
        if self.metadata_extractor:
            try:
                resolved_filepath = Path(filepath).resolve()
                resolved_source_dir = self.source_dir.resolve()
                if resolved_filepath.is_relative_to(resolved_source_dir):
                    rel_path = resolved_filepath.relative_to(resolved_source_dir)
                    file_path_no_ext = str(rel_path.with_suffix(''))
                else:
                    file_path_no_ext = Path(filepath).stem
                self.metadata_extractor.extract_from_ast(ast, file_path_no_ext)
            except (ValueError, TypeError, AttributeError):
                pass

        # Calculate file depth for imports
        file_depth = 0
        current_file_path = ''
        try:
            resolved_filepath = Path(filepath).resolve()
            resolved_source_dir = self.source_dir.resolve()
            if resolved_filepath.is_relative_to(resolved_source_dir):
                rel_path = resolved_filepath.relative_to(resolved_source_dir)
                file_depth = len(rel_path.parent.parts)
                current_file_path = str(rel_path.with_suffix(''))
        except (ValueError, TypeError, AttributeError):
            pass

        # Check for runtime replacement
        replacement = self._get_runtime_replacement(filepath)
        if replacement:
            return self._generate_runtime_reexport(replacement, file_depth)

        # Generate TypeScript using the modular code generator
        generator = TypeScriptCodeGenerator(
            self.registry if use_registry else None,
            file_depth=file_depth,
            current_file_path=current_file_path,
            runtime_replacement_classes=self.runtime_replacement_classes,
            runtime_replacement_mixins=self.runtime_replacement_mixins,
            runtime_replacement_methods=self.runtime_replacement_methods
        )
        return generator.generate(ast)

    def _get_runtime_replacement(self, filepath: str) -> Optional[dict]:
        """Check if a file should be replaced with a runtime implementation."""
        try:
            rel_path = Path(filepath).relative_to(self.source_dir)
            rel_str = str(rel_path).replace('\\', '/')
        except ValueError:
            rel_str = str(Path(filepath)).replace('\\', '/')

        for source_pattern, replacement in self.runtime_replacements.items():
            if rel_str.endswith(source_pattern) or rel_str == source_pattern:
                return replacement
        return None

    def _generate_runtime_reexport(self, replacement: dict, file_depth: int) -> str:
        """Generate a re-export file for a runtime replacement."""
        runtime_module = replacement.get('runtimeModule', '../runtime')
        exports = replacement.get('exports', [])
        reason = replacement.get('reason', 'Complex Yul assembly')

        runtime_path = '../' * file_depth + 'runtime' if file_depth > 0 else runtime_module

        lines = [
            "// Auto-generated by sol2ts transpiler",
            f"// Runtime replacement: {reason}",
            "",
        ]

        if exports:
            export_list = ', '.join(exports)
            lines.append(f"export {{ {export_list} }} from '{runtime_path}';")
        else:
            lines.append(f"export * from '{runtime_path}';")

        return '\n'.join(lines) + '\n'

    def transpile_directory(self, pattern: str = '**/*.sol') -> Dict[str, str]:
        """Transpile all Solidity files matching the pattern."""
        results = {}
        for sol_file in self.source_dir.glob(pattern):
            try:
                ts_code = self.transpile_file(str(sol_file))
                rel_path = sol_file.relative_to(self.source_dir)
                ts_path = self.output_dir / rel_path.with_suffix('.ts')
                results[str(ts_path)] = ts_code
            except Exception as e:
                print(f"Error transpiling {sol_file}: {e}")
        return results

    def write_output(self, results: Dict[str, str]) -> None:
        """Write transpiled TypeScript files to disk."""
        for filepath, content in results.items():
            path = Path(filepath)
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, 'w') as f:
                f.write(content)
            print(f"Written: {filepath}")

        # Generate and write factories.ts if metadata emission is enabled
        if self.emit_metadata and self.metadata_extractor:
            self.write_factories()

    def write_factories(self) -> None:
        """Generate and write the factories.ts file for dependency injection."""
        if not self.metadata_extractor:
            return

        generator = FactoryGenerator(self.metadata_extractor)
        factories_content = generator.generate()

        factories_path = self.output_dir / 'factories.ts'
        factories_path.parent.mkdir(parents=True, exist_ok=True)
        with open(factories_path, 'w') as f:
            f.write(factories_content)
        print(f"Written: {factories_path}")


# =============================================================================
# CLI INTERFACE
# =============================================================================

def main():
    import argparse

    parser = argparse.ArgumentParser(description='Solidity to TypeScript Transpiler (Refactored)')
    parser.add_argument('input', help='Input Solidity file or directory')
    parser.add_argument('-o', '--output', default='transpiler/ts-output', help='Output directory')
    parser.add_argument('--stdout', action='store_true', help='Print to stdout instead of file')
    parser.add_argument('-d', '--discover', action='append', metavar='DIR',
                        help='Directory to scan for type discovery')
    parser.add_argument('--stub', action='append', metavar='CONTRACT',
                        help='Contract name to generate as minimal stub')
    parser.add_argument('--emit-metadata', action='store_true',
                        help='Emit dependency manifest and factory functions')
    parser.add_argument('--metadata-only', action='store_true',
                        help='Only emit metadata, skip TypeScript generation')

    args = parser.parse_args()

    input_path = Path(args.input)
    discovery_dirs = args.discover or ([str(input_path)] if input_path.is_dir() else [str(input_path.parent)])
    stubbed_contracts = args.stub or []
    emit_metadata = args.emit_metadata or args.metadata_only

    if input_path.is_file():
        # Use first discovery dir as source_dir for correct import path calculation
        source_dir = discovery_dirs[0] if discovery_dirs else str(input_path.parent)
        transpiler = SolidityToTypeScriptTranspiler(
            source_dir=source_dir,
            output_dir=args.output,
            discovery_dirs=discovery_dirs,
            stubbed_contracts=stubbed_contracts,
            emit_metadata=emit_metadata
        )

        ts_code = transpiler.transpile_file(str(input_path))

        if args.metadata_only:
            pass  # Output metadata only
        elif args.stdout:
            print(ts_code)
        else:
            output_path = Path(args.output) / input_path.with_suffix('.ts').name
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, 'w') as f:
                f.write(ts_code)
            print(f"Written: {output_path}")

    elif input_path.is_dir():
        transpiler = SolidityToTypeScriptTranspiler(
            str(input_path), args.output, discovery_dirs, stubbed_contracts,
            emit_metadata=emit_metadata
        )
        transpiler.discover_types(str(input_path))

        if not args.metadata_only:
            results = transpiler.transpile_directory()
            transpiler.write_output(results)
    else:
        print(f"Error: {args.input} is not a valid file or directory")
        exit(1)


if __name__ == '__main__':
    main()
