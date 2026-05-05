#!/usr/bin/env python3
"""
extruder — source-to-source transpiler from Solidity to TypeScript.

Feed Solidity in one end, get a shaped TypeScript mirror out the other. Produces
one ES class per contract, a dependency-injection container, and a runtime
library modelling storage, events, and inter-contract calls — suitable for
driving client-side simulations, differential testing, and fast unit tests.

Key features:
- BigInt for 256-bit integer operations
- Storage simulation via objects/maps
- Bit manipulation helpers
- Yul/inline assembly support
- Interface and contract inheritance

Usage:
    python3 -m transpiler src/
    python3 -m transpiler --emit-replacement-stub <Name> <file.sol>

Module layout:
- lexer: Tokenization (tokens.py, lexer.py)
- parser: AST nodes and parsing (ast_nodes.py, parser.py)
- type_system: Type registry and mappings (registry.py, mappings.py)
- codegen: Code generation (generator.py + specialized generators)
- dependency_resolver: Interface → concrete implementation resolution
"""

import shutil
from pathlib import Path
from typing import Optional, List, Dict

# Import from refactored modules
from .lexer import Lexer
from .parser import Parser, SourceUnit
from .type_system import TypeRegistry
from .codegen import TypeScriptCodeGenerator
from .codegen.metadata import MetadataExtractor, FactoryGenerator
from .codegen.diagnostics import TranspilerDiagnostics, emit_ast_diagnostics
from .config import TranspilerConfig, normalize_config_path
from .dependency_resolver import DependencyResolver


class SolidityToTypeScriptTranspiler:
    """Main transpiler class that orchestrates the conversion process."""

    def __init__(
        self,
        source_dir: str = '.',
        output_dir: str = './ts-output',
        discovery_dirs: Optional[List[str]] = None,
        emit_metadata: bool = False,
        overrides_path: Optional[str] = None,
    ):
        self.source_dir = Path(source_dir)
        self.output_dir = Path(output_dir)
        self.parsed_files: Dict[str, SourceUnit] = {}
        self._ast_cache: Dict[str, SourceUnit] = {}
        self.registry = TypeRegistry()
        self.emit_metadata = emit_metadata
        self.overrides_path = overrides_path
        self._discovery_roots: List[Path] = []

        # Metadata extraction for factory generation
        self.metadata_extractor = MetadataExtractor() if emit_metadata else None

        # Diagnostics collector
        self.diagnostics = TranspilerDiagnostics()

        # Load consolidated transpiler configuration
        config_path = self.overrides_path or TranspilerConfig.default_path()
        self.config = TranspilerConfig.load(config_path, warn_missing=True)

        # Run type discovery on specified directories
        if discovery_dirs:
            for dir_path in discovery_dirs:
                self._discover_from_directory_cached(dir_path)

    def discover_types(self, directory: str, pattern: str = '**/*.sol') -> None:
        """Run type discovery on a directory of Solidity files."""
        self._discover_from_directory_cached(directory, pattern)

    def _discover_from_directory_cached(self, directory: str, pattern: str = '**/*.sol') -> None:
        """Discover types from Solidity files while reusing parsed ASTs."""
        base_dir = Path(directory)
        for sol_file in base_dir.glob(pattern):
            try:
                rel_path = sol_file.relative_to(base_dir).with_suffix('')
                ast = self._parse_file_cached(sol_file)
                self.registry.discover_from_ast(ast, str(rel_path))
            except Exception as e:
                print(f"Warning: Could not parse {sol_file} for type discovery: {e}")
        self._remember_discovery_root(directory)

    def _remember_discovery_root(self, directory: str) -> None:
        """Track discovery roots so transpile_file can avoid redundant discovery."""
        try:
            root = Path(directory).resolve()
        except (OSError, RuntimeError):
            return
        if root not in self._discovery_roots:
            self._discovery_roots.append(root)

    def _is_covered_by_discovery(self, filepath: str) -> bool:
        """Return True if a file lives under a root already type-discovered."""
        if not self._discovery_roots:
            return False
        try:
            resolved = Path(filepath).resolve()
        except (OSError, RuntimeError):
            return False
        return any(resolved == root or resolved.is_relative_to(root) for root in self._discovery_roots)

    def _cache_key(self, filepath: str | Path) -> str:
        """Stable key for source/AST caches."""
        try:
            return str(Path(filepath).resolve())
        except (OSError, RuntimeError):
            return str(Path(filepath))

    def _parse_file_cached(self, filepath: str | Path) -> SourceUnit:
        """Read, lex, and parse a Solidity file once per transpiler instance."""
        cache_key = self._cache_key(filepath)
        if cache_key in self._ast_cache:
            return self._ast_cache[cache_key]

        source = Path(filepath).read_text()
        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()

        self._ast_cache[cache_key] = ast
        self.parsed_files[str(filepath)] = ast
        return ast

    def transpile_file(self, filepath: str, use_registry: bool = True) -> str:
        """Transpile a single Solidity file to TypeScript."""
        # Calculate file depth for imports before parsing so runtime
        # replacements can stand in for files the parser cannot handle.
        file_depth = 0
        current_file_path = ''
        rel_path: Optional[Path] = None
        try:
            resolved_filepath = Path(filepath).resolve()
            resolved_source_dir = self.source_dir.resolve()
            if resolved_filepath.is_relative_to(resolved_source_dir):
                rel_path = resolved_filepath.relative_to(resolved_source_dir)
                file_depth = len(rel_path.parent.parts)
                current_file_path = str(rel_path.with_suffix(''))
        except (ValueError, TypeError, AttributeError):
            pass

        replacement = self._get_runtime_replacement(filepath)
        if replacement:
            runtime_module = replacement.get('runtimeModule', replacement.get('runtime', ''))
            self.diagnostics.info_runtime_replacement(filepath, runtime_module)
            return self._generate_runtime_reexport(replacement, file_depth)

        ast = self._parse_file_cached(filepath)
        self.parsed_files[filepath] = ast
        if not self._is_covered_by_discovery(filepath):
            self.registry.discover_from_ast(ast)

        # Extract metadata for factory generation
        if self.metadata_extractor:
            try:
                if rel_path is not None:
                    file_path_no_ext = str(rel_path.with_suffix(''))
                else:
                    file_path_no_ext = Path(filepath).stem
                self.metadata_extractor.extract_from_ast(ast, file_path_no_ext)
            except (ValueError, TypeError, AttributeError):
                pass

        # Emit diagnostics for skipped constructs in the AST
        self._emit_ast_diagnostics(ast, filepath)

        # Generate TypeScript using the modular code generator
        generator = TypeScriptCodeGenerator(
            self.registry if use_registry else None,
            file_depth=file_depth,
            current_file_path=current_file_path,
            runtime_replacement_classes=self.config.runtime_replacement_classes,
            runtime_replacement_mixins=self.config.runtime_replacement_mixins,
            runtime_replacement_methods=self.config.runtime_replacement_methods,
        )
        return generator.generate(ast)

    def _emit_ast_diagnostics(self, ast: SourceUnit, filepath: str) -> None:
        """Scan the AST and emit diagnostics for skipped/unsupported constructs."""
        emit_ast_diagnostics(ast, self.diagnostics, filepath)

    def _get_runtime_replacement(self, filepath: str) -> Optional[dict]:
        """Check if a file should be replaced with a runtime implementation."""
        try:
            rel_path = Path(filepath).relative_to(self.source_dir)
            rel_str = normalize_config_path(str(rel_path))
        except ValueError:
            rel_str = normalize_config_path(str(Path(filepath)))

        return self.config.runtime_replacement_for(rel_str)

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
            # Check if file or directory should be skipped
            rel = sol_file.relative_to(self.source_dir)
            rel_str = normalize_config_path(str(rel))
            has_replacement = self.config.runtime_replacement_for(rel_str) is not None
            if not has_replacement and self.config.should_skip_file(rel_str):
                continue
            if not has_replacement and self.config.should_skip_dir(rel_str):
                continue

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

        # Print diagnostics summary
        self.diagnostics.print_summary()

        # Copy hand-maintained runtime/ into the output so tests and rsync consumers
        # see a single canonical version. transpiler/runtime/ is the git-tracked
        # source of truth; ts-output/runtime/ is an ephemeral mirror.
        self._sync_runtime()

        # Generate and write factories.ts if metadata emission is enabled
        if self.emit_metadata and self.metadata_extractor:
            self.write_factories()

    def _sync_runtime(self) -> None:
        """Mirror transpiler/runtime/ into {output_dir}/runtime/."""
        src = Path(__file__).parent / 'runtime'
        if not src.is_dir():
            return
        dst = self.output_dir / 'runtime'
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)

    def write_factories(self) -> None:
        """Generate and write the factories.ts file for dependency injection."""
        if not self.metadata_extractor:
            return

        # Create dependency resolver with known classes from metadata
        known_classes = set(self.metadata_extractor.contracts.keys())
        resolver = DependencyResolver(
            overrides_path=self.overrides_path,
            known_classes=known_classes,
        )

        generator = FactoryGenerator(self.metadata_extractor, resolver)
        factories_content = generator.generate()

        factories_path = self.output_dir / 'factories.ts'
        factories_path.parent.mkdir(parents=True, exist_ok=True)
        with open(factories_path, 'w') as f:
            f.write(factories_content)
        print(f"Written: {factories_path}")

        # Export unresolved dependencies if any
        if resolver.has_unresolved():
            unresolved_path = self.output_dir / 'unresolved-dependencies.json'
            resolver.export_unresolved(str(unresolved_path))
            print(f"Warning: Some dependencies could not be resolved. See: {unresolved_path}")
            print("Add the missing mappings to dependency-overrides.json and re-run.")


# =============================================================================
# REPLACEMENT STUB EMISSION
# =============================================================================

def emit_replacement_stub(
    contract_name: str,
    source_file: str,
    output_file: str,
    discovery_dirs: Optional[List[str]] = None,
) -> None:
    """Emit a TypeScript scaffold + JSON config snippet for a runtime replacement.

    The scaffold has every function signature mapped to TypeScript types, bodies
    that throw `Error('Not implemented')`, and sensible defaults for state
    variables and constants. Fill in the bodies, then register the file under
    `transpiler-config.json -> runtimeReplacements` using the snippet printed to
    stdout.
    """
    from .codegen.replacement_stub import ReplacementStubGenerator, format_config_snippet

    source_path = Path(source_file)
    try:
        source = source_path.read_text()
    except FileNotFoundError:
        print(f"Error: source file not found: {source_file}")
        raise SystemExit(1)

    registry = TypeRegistry()
    for d in (discovery_dirs or [str(source_path.parent)]):
        if Path(d).is_dir():
            registry.discover_from_directory(d)

    ast = Parser(Lexer(source).tokenize()).parse()

    contract = next((c for c in ast.contracts if c.name == contract_name), None)
    if contract is None:
        names = [c.name for c in ast.contracts]
        print(
            f"Error: no contract named '{contract_name}' in {source_file}. "
            f"Found: {names}"
        )
        raise SystemExit(1)

    generator = ReplacementStubGenerator(registry)
    ts_source, config_entry = generator.emit(contract, source_file)

    out_path = Path(output_file)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, 'w') as f:
        f.write(ts_source)
    print(f"Written: {out_path}")
    print()
    print("Add this entry to your transpiler-config.json `runtimeReplacements` array:")
    print()
    print(format_config_snippet(config_entry))


# =============================================================================
# CLI INTERFACE
# =============================================================================

def main():
    import argparse
    import sys

    # Fast-path the `init` subcommand. Mixing argparse subparsers with the
    # top-level positional `input` is awkward (any non-`init` first argument
    # fails subcommand validation), so we dispatch init manually.
    if len(sys.argv) > 1 and sys.argv[1] == 'init':
        init_parser = argparse.ArgumentParser(
            prog='python3 -m transpiler init',
            description=(
                'Scan a Solidity source tree and scaffold a starter '
                'transpiler-config.json. Classifies each file '
                '(OK/SKIP/REPLACE/MAYBE), infers interface aliases, and '
                'emits runtime-replacement stubs for files that need them.'
            ),
        )
        init_parser.add_argument('source_root', help='Solidity source directory to scan')
        init_parser.add_argument('--yes', action='store_true',
                                 help='Non-interactive: accept auto-classifications, punt ambiguous decisions')
        init_parser.add_argument('--stub-output-dir',
                                 help='Where to write scaffolded stubs (default: ./runtime-replacements)')
        init_parser.add_argument('--config-path',
                                 help='Where to write the config (default: ./transpiler-config.json)')
        init_args = init_parser.parse_args(sys.argv[2:])
        from .init import run_init
        run_init(
            source_root=init_args.source_root,
            yes=init_args.yes,
            stub_output_dir=init_args.stub_output_dir,
            config_path=init_args.config_path,
        )
        return

    parser = argparse.ArgumentParser(
        prog='python3 -m transpiler',
        description='extruder — source-to-source Solidity → TypeScript transpiler',
        epilog='Subcommands: `python3 -m transpiler init <src>` to scaffold a config for a new project.',
    )
    parser.add_argument('input', nargs='?', help='Input Solidity file or directory')
    parser.add_argument('-o', '--output', default='transpiler/ts-output', help='Output directory (or output file for --emit-replacement-stub)')
    parser.add_argument('--stdout', action='store_true', help='Print to stdout instead of file')
    parser.add_argument('-d', '--discover', action='append', metavar='DIR',
                        help='Directory to scan for type discovery')
    parser.add_argument('--emit-metadata', action='store_true',
                        help='Emit dependency manifest and factory functions')
    parser.add_argument('--overrides', metavar='FILE',
                        help='Path to transpiler-config.json for manual dependency mappings')
    parser.add_argument('--emit-replacement-stub', nargs=2, metavar=('CONTRACT', 'SOL_FILE'),
                        help='Emit a TypeScript scaffold for a runtime replacement. '
                             'Pass the contract name and the .sol path. '
                             'Use -o to choose the output .ts path.')

    args = parser.parse_args()

    # Mode: emit replacement stub
    if args.emit_replacement_stub:
        contract_name, sol_file = args.emit_replacement_stub
        out_path = args.output
        # If -o was left at the default directory, write into that dir by contract name.
        if out_path == 'transpiler/ts-output':
            out_path = f'{contract_name}.ts'
        emit_replacement_stub(
            contract_name=contract_name,
            source_file=sol_file,
            output_file=out_path,
            discovery_dirs=args.discover,
        )
        return

    # Normal transpilation requires an input.
    if not args.input:
        parser.error('input is required unless --emit-replacement-stub is used')

    input_path = Path(args.input)
    discovery_dirs = args.discover or ([str(input_path)] if input_path.is_dir() else [str(input_path.parent)])
    emit_metadata = args.emit_metadata

    overrides_path = args.overrides

    # Default overrides path to transpiler-config.json if not specified
    if not overrides_path:
        default_overrides = Path(__file__).parent / 'transpiler-config.json'
        if default_overrides.exists():
            overrides_path = str(default_overrides)

    if input_path.is_file():
        # Use first discovery dir as source_dir for correct import path calculation
        source_dir = discovery_dirs[0] if discovery_dirs else str(input_path.parent)
        transpiler = SolidityToTypeScriptTranspiler(
            source_dir=source_dir,
            output_dir=args.output,
            discovery_dirs=discovery_dirs,
            emit_metadata=emit_metadata,
            overrides_path=overrides_path,
        )

        ts_code = transpiler.transpile_file(str(input_path))

        if args.stdout:
            print(ts_code)
        else:
            output_path = Path(args.output) / input_path.with_suffix('.ts').name
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, 'w') as f:
                f.write(ts_code)
            print(f"Written: {output_path}")

    elif input_path.is_dir():
        transpiler = SolidityToTypeScriptTranspiler(
            str(input_path), args.output, discovery_dirs,
            emit_metadata=emit_metadata,
            overrides_path=overrides_path,
        )
        results = transpiler.transpile_directory()
        transpiler.write_output(results)
    else:
        print(f"Error: {args.input} is not a valid file or directory")
        raise SystemExit(1)


if __name__ == '__main__':
    main()
