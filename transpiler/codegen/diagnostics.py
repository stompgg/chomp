"""
Diagnostic/warning system for the transpiler.

Collects and reports warnings about unsupported Solidity constructs
that were skipped or degraded during transpilation. Helps developers
understand simulation fidelity gaps.
"""

import sys
from dataclasses import dataclass, field
from enum import Enum
from typing import List, Optional


class DiagnosticSeverity(Enum):
    """Severity levels for transpiler diagnostics."""
    WARNING = 'warning'
    INFO = 'info'


@dataclass
class Diagnostic:
    """A single diagnostic message."""
    severity: DiagnosticSeverity
    code: str
    message: str
    file_path: str = ''
    line: Optional[int] = None
    construct: str = ''  # e.g., 'modifier', 'try/catch', 'receive'

    def __str__(self) -> str:
        location = self.file_path
        if self.line:
            location = f'{location}:{self.line}'
        if location:
            return f'[{self.severity.value}] {location}: {self.message} ({self.code})'
        return f'[{self.severity.value}] {self.message} ({self.code})'


class TranspilerDiagnostics:
    """
    Collects transpiler warnings/diagnostics during code generation.

    Usage:
        diag = TranspilerDiagnostics()
        diag.warn_modifier_stripped("onlyOwner", "Engine.sol", line=42)
        # ... after transpilation ...
        diag.print_summary()
    """

    def __init__(self, verbose: bool = False):
        self._diagnostics: List[Diagnostic] = []
        self._verbose = verbose

    @property
    def diagnostics(self) -> List[Diagnostic]:
        """Get all collected diagnostics."""
        return list(self._diagnostics)

    @property
    def warnings(self) -> List[Diagnostic]:
        """Get only warning-level diagnostics."""
        return [d for d in self._diagnostics if d.severity == DiagnosticSeverity.WARNING]

    @property
    def count(self) -> int:
        """Get total diagnostic count."""
        return len(self._diagnostics)

    def clear(self) -> None:
        """Clear all diagnostics."""
        self._diagnostics.clear()

    # =========================================================================
    # SPECIFIC WARNING METHODS
    # =========================================================================

    def warn_modifier_stripped(
        self,
        modifier_name: str,
        file_path: str = '',
        line: Optional[int] = None,
    ) -> None:
        """Warn that a modifier was stripped (not inlined)."""
        self._diagnostics.append(Diagnostic(
            severity=DiagnosticSeverity.WARNING,
            code='W001',
            message=f'Modifier "{modifier_name}" was stripped (not inlined). '
                    f'Access control and validation logic may be missing.',
            file_path=file_path,
            line=line,
            construct='modifier',
        ))

    def warn_try_catch_skipped(
        self,
        file_path: str = '',
        line: Optional[int] = None,
    ) -> None:
        """Warn that a try/catch block was skipped."""
        self._diagnostics.append(Diagnostic(
            severity=DiagnosticSeverity.WARNING,
            code='W002',
            message='try/catch block was skipped (empty block generated). '
                    'Error handling logic is missing.',
            file_path=file_path,
            line=line,
            construct='try/catch',
        ))

    def warn_receive_fallback_skipped(
        self,
        kind: str,
        file_path: str = '',
        line: Optional[int] = None,
    ) -> None:
        """Warn that receive() or fallback() was skipped."""
        self._diagnostics.append(Diagnostic(
            severity=DiagnosticSeverity.WARNING,
            code='W003',
            message=f'{kind}() function was skipped (not supported).',
            file_path=file_path,
            line=line,
            construct=kind,
        ))

    def warn_function_pointer_unsupported(
        self,
        file_path: str = '',
        line: Optional[int] = None,
    ) -> None:
        """Warn that a function pointer type was encountered."""
        self._diagnostics.append(Diagnostic(
            severity=DiagnosticSeverity.WARNING,
            code='W004',
            message='Function pointer type is not supported; using generic type.',
            file_path=file_path,
            line=line,
            construct='function pointer',
        ))

    def warn_yul_parse_error(
        self,
        error: str,
        file_path: str = '',
        line: Optional[int] = None,
    ) -> None:
        """Warn that Yul code could not be parsed."""
        self._diagnostics.append(Diagnostic(
            severity=DiagnosticSeverity.WARNING,
            code='W005',
            message=f'Yul parse error: {error}. Assembly block may be incorrect.',
            file_path=file_path,
            line=line,
            construct='assembly',
        ))

    def warn_unsupported_construct(
        self,
        construct: str,
        detail: str = '',
        file_path: str = '',
        line: Optional[int] = None,
    ) -> None:
        """Generic warning for unsupported constructs."""
        msg = f'Unsupported construct: {construct}'
        if detail:
            msg += f' ({detail})'
        self._diagnostics.append(Diagnostic(
            severity=DiagnosticSeverity.WARNING,
            code='W099',
            message=msg,
            file_path=file_path,
            line=line,
            construct=construct,
        ))

    def info_runtime_replacement(
        self,
        file_path: str,
        replacement_path: str,
    ) -> None:
        """Info that a file uses a runtime replacement."""
        self._diagnostics.append(Diagnostic(
            severity=DiagnosticSeverity.INFO,
            code='I001',
            message=f'Using runtime replacement: {replacement_path}',
            file_path=file_path,
            construct='runtime-replacement',
        ))

    # =========================================================================
    # REPORTING
    # =========================================================================

    def print_summary(self, file=None) -> None:
        """Print a summary of all diagnostics to stderr (or specified file)."""
        if file is None:
            file = sys.stderr

        if not self._diagnostics:
            return

        warnings = self.warnings
        infos = [d for d in self._diagnostics if d.severity == DiagnosticSeverity.INFO]

        if warnings:
            print(f'\nTranspiler warnings ({len(warnings)}):', file=file)
            # Group by construct type
            by_construct: dict = {}
            for w in warnings:
                key = w.construct or 'other'
                if key not in by_construct:
                    by_construct[key] = []
                by_construct[key].append(w)

            for construct, diags in sorted(by_construct.items()):
                print(f'  {construct}: {len(diags)} occurrence(s)', file=file)
                if self._verbose:
                    for d in diags:
                        print(f'    {d}', file=file)

        if infos and self._verbose:
            print(f'\nTranspiler info ({len(infos)}):', file=file)
            for d in infos:
                print(f'  {d}', file=file)

    def get_summary(self) -> str:
        """Get a summary string of all diagnostics."""
        if not self._diagnostics:
            return 'No transpiler warnings.'

        warnings = self.warnings
        by_construct: dict = {}
        for w in warnings:
            key = w.construct or 'other'
            if key not in by_construct:
                by_construct[key] = 0
            by_construct[key] += 1

        parts = [f'{count} {construct}' for construct, count in sorted(by_construct.items())]
        return f'Transpiler warnings: {", ".join(parts)}'
