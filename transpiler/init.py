"""
`extruder init` — interactive project bootstrap.

Walks a Solidity source tree, classifies each file as OK / SKIP / REPLACE /
MAYBE, infers interface-to-implementation aliases, and produces:

- A populated `transpiler-config.json` at the project root
- Scaffolded runtime-replacement stubs for each REPLACE file (via the
  existing `--emit-replacement-stub` machinery)
- A human-readable `.extruder-init-report.md` summarizing decisions

The module is split into three layers with no cross-contamination:

- `scan()` — pure: takes a source root + registry, returns an `InitReport`.
  No prompts, no filesystem writes.
- `build_plan()` — takes a report + a `Prompter`, returns an `InitPlan`
  (list of concrete actions). All user interaction lives here.
- `apply()` — executes a plan. All filesystem writes live here.

Each layer is independently testable. The Prompter is a tiny interface so
tests can mock input without monkey-patching stdin.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple

from .lexer import Lexer
from .parser import Parser, SourceUnit
from .parser.visitor import ASTVisitor
from .parser.ast_nodes import (
    ASTNode,
    AssemblyBlock,
    AssemblyStatement,
    ContractDefinition,
    FunctionCall,
    Identifier,
    MemberAccess,
    NewExpression,
)
from .codegen.metadata import MetadataExtractor
from .config import TranspilerConfig, merge_config_updates
from .dependency_resolver import DependencyResolver
from .type_system import TypeRegistry


# =============================================================================
# DATA MODEL
# =============================================================================

# Verdict values
OK = 'OK'
SKIP = 'SKIP'
REPLACE = 'REPLACE'
MAYBE = 'MAYBE'

# Interface classifications
IFACE_AUTO = 'auto'       # exactly one implementer — map automatically
IFACE_PROMPT = 'prompt'   # 2 to TAG_THRESHOLD-1 implementers — ask user
IFACE_TAG = 'tag'         # TAG_THRESHOLD+ implementers — treat as tag interface
IFACE_NO_IMPL = 'no_impl' # zero implementers in the scanned tree

TAG_INTERFACE_THRESHOLD = 6


@dataclass
class FileVerdict:
    """Classification result for one Solidity file."""
    path: str             # relative to scan root
    verdict: str          # OK / SKIP / REPLACE / MAYBE
    reasons: List[str] = field(default_factory=list)  # human-readable evidence
    # Set on REPLACE when we know which contract in the file needs the stub.
    replace_contract: Optional[str] = None


@dataclass
class InterfaceMapping:
    """Alias inference result for one interface."""
    interface_name: str
    implementers: List[str]
    classification: str  # IFACE_* constants


@dataclass
class UnresolvedDep:
    """A constructor param the resolver couldn't map, with candidate impls.

    `implementers` is the list of concrete contract names that implement
    `type_name` (or extend it). Populated from the same inheritance index
    phase 2 uses, so phase 3 can prompt with real choices rather than
    forcing the user to type class names by hand.
    """
    contract_name: str
    param_name: str
    type_name: str
    is_array: bool
    implementers: List[str]


@dataclass
class InitReport:
    """Output of the scan phase — input to prompt + apply phases."""
    root: Path
    files: List[FileVerdict] = field(default_factory=list)
    interfaces: List[InterfaceMapping] = field(default_factory=list)
    unresolved_deps: List[UnresolvedDep] = field(default_factory=list)

    def by_verdict(self, verdict: str) -> List[FileVerdict]:
        return [f for f in self.files if f.verdict == verdict]

    def by_classification(self, classification: str) -> List[InterfaceMapping]:
        return [i for i in self.interfaces if i.classification == classification]


@dataclass
class InitPlan:
    """Concrete actions to execute. Produced by build_plan, consumed by apply."""
    skip_files: List[str] = field(default_factory=list)
    # (source_path, contract_name) pairs to scaffold stubs for
    replace_targets: List[Tuple[str, str]] = field(default_factory=list)
    interface_aliases: Dict[str, Optional[str]] = field(default_factory=dict)
    # {ContractName: {paramName: ImplName or [ImplName, ...] for arrays}}
    dependency_overrides: Dict[str, Dict[str, object]] = field(default_factory=dict)
    # Things we punted on — listed in the report so the user can revisit
    punted_interfaces: List[str] = field(default_factory=list)
    punted_files: List[str] = field(default_factory=list)
    punted_deps: List[UnresolvedDep] = field(default_factory=list)


# =============================================================================
# SCAN PHASE (pure)
# =============================================================================

# Directories and filename patterns treated as "obvious skip" without parsing.
_SKIP_DIRS = ('test', 'tests', 'script', 'scripts', 'foundry-test')
_SKIP_SUFFIXES = ('.t.sol', '.s.sol')


def scan(
    root: Path,
    registry: TypeRegistry,
    existing_config_path: Optional[Path] = None,
    speculative_aliases: Optional[Dict[str, Optional[str]]] = None,
) -> InitReport:
    """Classify every .sol file under `root`, infer interface aliases, and
    run a dry-run dependency-resolver pass.

    Pure: no prompts, no writes. `registry` should already have been populated
    via `registry.discover_from_directory(root)`.

    `speculative_aliases` lets the caller feed in aliases that `build_plan`
    has just decided on (phase 2) so the phase-3 resolver sees the same view
    the final factory generator will — otherwise every interface without an
    explicit config entry would show up as unresolved.
    """
    report = InitReport(root=root)
    parsed: Dict[str, SourceUnit] = {}  # rel_path → AST, for reuse by phase 3

    for sol_file in sorted(root.rglob('*.sol')):
        rel = sol_file.relative_to(root).as_posix()
        verdict, ast = _classify_file(sol_file, rel)
        report.files.append(verdict)
        if ast is not None:
            parsed[rel] = ast

    report.interfaces = _infer_interfaces(registry)
    report.unresolved_deps = _run_resolver_dry_run(
        registry,
        existing_config_path,
        speculative_aliases or {},
        report.interfaces,
        parsed,
    )
    return report


_RECEIVE_RE = re.compile(r'\breceive\s*\(\s*\)\s*external')
_FALLBACK_RE = re.compile(r'\bfallback\s*\(\s*\)\s*external')


def _classify_file(path: Path, rel: str) -> Tuple[FileVerdict, Optional[SourceUnit]]:
    """Classify a single file. Returns `(verdict, ast)` — ast is None if
    parsing failed (REPLACE) or the path was skipped without parsing.
    Callers reuse the ast for phase 3 to avoid a second parse pass.
    """
    skip_reason = _path_skip_reason(rel)
    if skip_reason:
        return FileVerdict(path=rel, verdict=SKIP, reasons=[skip_reason]), None

    # Parse the file. Syntax errors mean the transpiler can't handle it —
    # definitive REPLACE signal.
    try:
        source = path.read_text()
        tokens = Lexer(source).tokenize()
        ast = Parser(tokens).parse()
    except Exception as e:  # noqa: BLE001 — parser raises various exception types
        return FileVerdict(path=rel, verdict=REPLACE, reasons=[f'parse error: {e}']), None

    reasons: List[str] = []
    replace_contract: Optional[str] = None
    for contract in ast.contracts:
        contract_reasons = _scan_contract_for_red_flags(contract)
        if contract_reasons:
            reasons.extend(contract_reasons)
            replace_contract = replace_contract or contract.name

    if reasons:
        return FileVerdict(
            path=rel, verdict=REPLACE, reasons=reasons,
            replace_contract=replace_contract,
        ), ast

    # MAYBE signals (degraded fidelity, not hard failures):
    #   W001 — modifier stripped; W003 — receive/fallback skipped.
    # W003 uses a source-text regex because the parser drops those tokens.
    # W002 / W004 aren't detected yet — would need parser-side support.
    maybe_reasons: List[str] = []
    for contract in ast.contracts:
        maybe_reasons.extend(_scan_contract_for_maybe(contract))
    if _RECEIVE_RE.search(source):
        maybe_reasons.append(
            'receive() will be skipped (W003) — ETH-receiving path silently no-ops'
        )
    if _FALLBACK_RE.search(source):
        maybe_reasons.append(
            'fallback() will be skipped (W003) — fallback path silently no-ops'
        )
    if maybe_reasons:
        return FileVerdict(path=rel, verdict=MAYBE, reasons=_dedup(maybe_reasons)), ast

    return FileVerdict(path=rel, verdict=OK), ast


def _dedup(items: List[str]) -> List[str]:
    """Dedupe a list while preserving first-seen order."""
    seen: Set[str] = set()
    return [x for x in items if not (x in seen or seen.add(x))]


def _path_skip_reason(rel: str) -> Optional[str]:
    """Return a human-readable skip reason if the path matches heuristics."""
    parts = rel.split('/')
    top = parts[0] if parts else ''
    if top in _SKIP_DIRS:
        return f'path under {top}/'
    for suffix in _SKIP_SUFFIXES:
        if rel.endswith(suffix):
            return f'matches {suffix} convention'
    # test/mocks and similar nested locations
    for i, part in enumerate(parts[:-1]):
        if part == 'mocks' and i > 0:
            return 'nested mocks/ directory'
    return None


def _scan_contract_for_red_flags(contract: ContractDefinition) -> List[str]:
    """Walk a contract's functions and return reasons why it needs a replacement."""
    reasons: List[str] = []
    for func in contract.functions:
        if func.body is None:
            continue
        _walk_for_flags(func.body, reasons)
    if contract.constructor and contract.constructor.body:
        _walk_for_flags(contract.constructor.body, reasons)
    return _dedup(reasons)


def _scan_contract_for_maybe(contract: ContractDefinition) -> List[str]:
    """Return MAYBE-reasons: things that transpile but with degraded fidelity."""
    reasons: List[str] = []
    # W001: modifiers are stripped, not inlined.
    if contract.modifiers:
        reasons.append(
            'has modifier(s) that will be stripped at transpile time (W001) — '
            'access-control checks disappear, hand-audit required'
        )
    else:
        for func in contract.functions:
            if func.modifiers:
                reasons.append(
                    'function applies modifier(s) which get stripped at transpile '
                    'time (W001) — access-control checks disappear'
                )
                break
    # W003 (receive/fallback) is checked at the source-text level in
    # _classify_file — the parser drops those tokens before the AST.
    return reasons


def _walk_for_flags(node: ASTNode, reasons: List[str]) -> None:
    """Recurse an AST subtree, appending red-flag reasons as we find them."""
    _RedFlagVisitor(reasons).visit(node)


class _RedFlagVisitor(ASTVisitor):
    """Collect init-time REPLACE red flags from statement/expression trees."""

    def __init__(self, reasons: List[str]):
        self.reasons = reasons

    def visit_AssemblyBlock(self, node: AssemblyBlock):
        _inspect_yul(node.code, self.reasons)

    def visit_AssemblyStatement(self, node: AssemblyStatement):
        _inspect_yul(node.block.code, self.reasons)

    def visit_FunctionCall(self, node: FunctionCall):
        _inspect_call(node, self.reasons)
        return self.generic_visit(node)

    def visit_NewExpression(self, node: NewExpression):
        tn = node.type_name
        is_array_alloc = getattr(tn, 'is_array', False) or tn.name in (
            'bytes', 'string',
        ) or tn.name.startswith(('uint', 'int'))
        if not is_array_alloc:
            self.reasons.append(
                f'uses `new {tn.name}(...)` to deploy a contract (no bytecode model)'
            )
        return self.generic_visit(node)


def _inspect_call(call: FunctionCall, reasons: List[str]) -> None:
    """Check a function call for red-flag patterns."""
    func = call.function
    if isinstance(func, Identifier):
        if func.name == 'ecrecover':
            reasons.append('calls ecrecover (no secp256k1 recovery in runtime)')
    elif isinstance(func, MemberAccess):
        if func.member in ('call', 'delegatecall', 'staticcall'):
            reasons.append(
                f'uses low-level .{func.member}() for dispatch '
                '(no ABI dispatch model)'
            )


_KECCAK_IN_SSTORE_RE = re.compile(r'\b(?:sstore|sload)\s*\(\s*keccak256\b')
# Yul `:=` tokenizes as `:` and `=`, separated by whitespace in the captured
# code string; match either spacing.
_KECCAK_ASSIGNED_RE = re.compile(r':\s*=\s*keccak256\b')
_CREATE2_RE = re.compile(r'\bcreate2\s*\(')
_CREATE_RE = re.compile(r'\bcreate\s*\(')
# `staticcall(gas(), <precompile-addr>, ...)` where precompile is 1..9. The
# second argument is the precompile address; 1 is ecrecover, 2 is sha256, etc.
_PRECOMPILE_STATICCALL_RE = re.compile(
    r'\bstaticcall\s*\(\s*gas\s*\(\s*\)\s*,\s*(?:0x0?[1-9]|[1-9])\b'
)


def _inspect_yul(code: str, reasons: List[str]) -> None:
    """Scan a Yul block body for red-flag patterns.

    Yul bodies arrive here as a space-separated token stream (the parser
    normalizes whitespace), so checks tolerate `keccak256 ( …` spacing via
    `\\s*`. Substring checks would miss these.
    """
    if _KECCAK_IN_SSTORE_RE.search(code) or _KECCAK_ASSIGNED_RE.search(code):
        reasons.append('uses Yul keccak256 over memory (no memory model — result is 0n)')
    if _CREATE2_RE.search(code):
        reasons.append('uses Yul create2 (no bytecode deployment)')
    elif _CREATE_RE.search(code):
        reasons.append('uses Yul create (no bytecode deployment)')
    if _PRECOMPILE_STATICCALL_RE.search(code):
        reasons.append(
            'calls an EVM precompile via staticcall '
            '(e.g. ecrecover / sha256 / ripemd160 — no precompile impls in runtime)'
        )


def _run_resolver_dry_run(
    registry: TypeRegistry,
    existing_config_path: Optional[Path],
    speculative_aliases: Dict[str, Optional[str]],
    interface_mappings: List[InterfaceMapping],
    parsed_files: Dict[str, SourceUnit],
) -> List[UnresolvedDep]:
    """Walk constructors, resolve each interface param via the real resolver,
    and return anything that couldn't be auto-mapped. Uses ASTs already
    produced by `_classify_file` — no re-parsing."""
    metadata = MetadataExtractor()
    for rel, ast in parsed_files.items():
        metadata.extract_from_ast(ast, rel)

    # Concrete (non-abstract, non-library, non-interface) contract names form
    # the "known classes" pool. Match FactoryGenerator's view exactly.
    known_classes = {
        name for name, meta in metadata.contracts.items()
        if meta.kind == 'contract' and not meta.is_abstract
    }

    resolver = DependencyResolver(
        overrides_path=str(existing_config_path) if existing_config_path else None,
        known_classes=known_classes,
    )
    resolver.add_aliases(speculative_aliases)

    # Interfaces seen here plus those the TypeRegistry knows about via
    # cross-file discovery — some constructor param types reference interfaces
    # defined in files the metadata extractor hasn't (yet) parsed.
    known_interfaces = set(metadata.interfaces) | set(registry.interfaces)

    for contract_name, meta in metadata.contracts.items():
        if meta.kind != 'contract' or meta.is_abstract:
            continue
        resolver.resolve_constructor_params(
            contract_name=contract_name,
            constructor_params=meta.constructor_params,
            known_interfaces=known_interfaces,
        )

    impls_by_iface: Dict[str, List[str]] = {
        m.interface_name: list(m.implementers) for m in interface_mappings
    }

    unresolved: List[UnresolvedDep] = []
    for dep in resolver.get_unresolved():
        base = dep.type_name.rstrip('[]')
        unresolved.append(UnresolvedDep(
            contract_name=dep.contract_name,
            param_name=dep.param_name,
            type_name=dep.type_name,
            is_array=dep.is_array,
            implementers=impls_by_iface.get(base, []),
        ))
    return unresolved


def _infer_interfaces(registry: TypeRegistry) -> List[InterfaceMapping]:
    """Build interface-to-implementer mappings from the registry."""
    # Build reverse index: base contract -> direct subclasses
    subclasses: Dict[str, List[str]] = {}
    for contract, bases in registry.contract_bases.items():
        if contract in registry.interfaces:
            continue  # interfaces don't count as implementers
        for base in bases:
            subclasses.setdefault(base, []).append(contract)

    mappings: List[InterfaceMapping] = []
    for iface in sorted(registry.interfaces):
        impls = sorted(subclasses.get(iface, []))
        if not impls:
            classification = IFACE_NO_IMPL
        elif len(impls) == 1:
            classification = IFACE_AUTO
        elif len(impls) >= TAG_INTERFACE_THRESHOLD:
            classification = IFACE_TAG
        else:
            classification = IFACE_PROMPT
        mappings.append(InterfaceMapping(
            interface_name=iface,
            implementers=impls,
            classification=classification,
        ))
    return mappings


# =============================================================================
# PROMPT PHASE (user interaction)
# =============================================================================

class Prompter:
    """Thin wrapper around stdin/stdout so tests can mock it."""

    def yes_no(self, message: str, default: bool = True) -> bool:
        hint = '[Y/n]' if default else '[y/N]'
        raw = input(f'{message} {hint} ').strip().lower()
        if not raw:
            return default
        return raw in ('y', 'yes')

    def pick(self, message: str, options: List[str]) -> Optional[int]:
        """Prompt for a numeric pick; returns index or None if user skipped.

        Appends a 'skip' option automatically. `options` should be the
        concrete choices.
        """
        print(message)
        for i, opt in enumerate(options, start=1):
            print(f'  [{i}] {opt}')
        print(f'  [{len(options) + 1}] skip')
        while True:
            raw = input('> ').strip()
            if not raw:
                continue
            try:
                choice = int(raw)
            except ValueError:
                print('  (enter a number)')
                continue
            if choice == len(options) + 1:
                return None
            if 1 <= choice <= len(options):
                return choice - 1
            print('  (out of range)')


def build_plan(
    report: InitReport,
    prompter: Optional[Prompter] = None,
    yes_all: bool = False,
    existing_config: Optional[dict] = None,
) -> InitPlan:
    """Turn a report into a concrete action plan.

    If `yes_all` is set, accepts every auto-classifiable decision and punts
    anything ambiguous. Otherwise uses `prompter` for decisions.

    `existing_config` is the pre-init `transpiler-config.json` contents (or
    None if fresh). When an alias or override in the report conflicts with
    an entry already in the config, `build_plan` prompts; under `--yes` the
    existing value is preserved and the conflict is reported.
    """
    plan = InitPlan()
    existing_config = existing_config or {}
    existing_aliases = existing_config.get('interfaceAliases', {})
    existing_overrides = existing_config.get('dependencyOverrides', {})

    skips = report.by_verdict(SKIP)
    replaces = report.by_verdict(REPLACE)
    maybes = report.by_verdict(MAYBE)
    auto_ifaces = report.by_classification(IFACE_AUTO)
    prompt_ifaces = report.by_classification(IFACE_PROMPT)

    # --- SKIPs ---
    if skips:
        print(f'[auto-skip] {len(skips)} files matched path heuristics.')
        take = yes_all or (prompter and prompter.yes_no('  Add to skipFiles?'))
        if take:
            plan.skip_files = [f.path for f in skips]

    # --- REPLACEs ---
    if replaces:
        print(f'[needs replacement] {len(replaces)} files flagged:')
        for f in replaces:
            reason_str = '; '.join(f.reasons[:2]) or '(see report)'
            print(f'  {f.path:<48} {reason_str}')
        take = yes_all or (prompter and prompter.yes_no(
            '  Scaffold runtime-replacement stubs for all of these?'
        ))
        if take:
            for f in replaces:
                contract_name = f.replace_contract or Path(f.path).stem
                plan.replace_targets.append((f.path, contract_name))
        else:
            plan.punted_files.extend(f.path for f in replaces)

    # --- MAYBE reported only, not prompted ---
    if maybes:
        plan.punted_files.extend(f.path for f in maybes)

    # --- Interface aliases: auto ---
    # Skip entries that are already set in the existing config to the same
    # value. Surface conflicts explicitly.
    new_auto = []
    for i in auto_ifaces:
        existing = existing_aliases.get(i.interface_name)
        if existing == i.implementers[0]:
            continue  # already set to the right value, no-op
        new_auto.append(i)

    if new_auto:
        print(f'[interface aliases] {len(new_auto)} interfaces with one implementer:')
        for i in new_auto[:8]:
            note = ''
            existing = existing_aliases.get(i.interface_name)
            if existing is not None and existing != i.implementers[0]:
                note = f'  (CONFLICT: existing = {existing})'
            print(f'  {i.interface_name} → {i.implementers[0]}{note}')
        if len(new_auto) > 8:
            print(f'  ...{len(new_auto) - 8} more')
        take = yes_all or (prompter and prompter.yes_no('  Accept all auto-mappings?'))
        if take:
            for i in new_auto:
                existing = existing_aliases.get(i.interface_name)
                if existing is not None and existing != i.implementers[0] and not yes_all:
                    # Conflict — ask which wins
                    keep = prompter and prompter.pick(
                        f'  Conflict for {i.interface_name}: existing config has '
                        f'`{existing}`, scan suggests `{i.implementers[0]}`. Which wins?',
                        [f'{existing} (keep existing)', f'{i.implementers[0]} (use new)'],
                    )
                    if keep == 1:
                        plan.interface_aliases[i.interface_name] = i.implementers[0]
                elif existing is None:
                    plan.interface_aliases[i.interface_name] = i.implementers[0]

    # --- Interface aliases: prompt ---
    for i in prompt_ifaces:
        existing = existing_aliases.get(i.interface_name)
        if existing is not None:
            # Already chosen. If it's one of the candidates, honor it silently;
            # otherwise report the conflict in the report file.
            if existing in i.implementers:
                continue
            # Stale existing choice — prompt with the new options
        if yes_all or prompter is None:
            plan.punted_interfaces.append(i.interface_name)
            continue
        options = list(i.implementers)
        default_hint = f' (existing: {existing})' if existing else ''
        idx = prompter.pick(
            f'  {i.interface_name}: pick an implementation{default_hint}',
            options,
        )
        if idx is None:
            plan.punted_interfaces.append(i.interface_name)
        else:
            plan.interface_aliases[i.interface_name] = options[idx]

    # --- Dependency-resolver follow-up ---
    # scan()'s unresolved_deps were computed against the pre-init config.
    # Drop any that the aliases we just chose now cover.
    pending_deps = [
        d for d in report.unresolved_deps
        if d.type_name.rstrip('[]') not in plan.interface_aliases
    ]
    if pending_deps:
        print(
            f'[dependency overrides] {len(pending_deps)} constructor params '
            'could not be resolved via aliases:'
        )
        for d in pending_deps[:10]:
            print(f'  {d.contract_name}.{d.param_name}: {d.type_name}')
        if len(pending_deps) > 10:
            print(f'  ...{len(pending_deps) - 10} more (see report)')

    for dep in pending_deps:
        # Skip deps already set in existing config — user already decided.
        existing_contract = existing_overrides.get(dep.contract_name, {})
        if dep.param_name in existing_contract:
            continue
        if dep.implementers:
            picked = _pick_implementer(dep, prompter, yes_all)
            if picked is None:
                plan.punted_deps.append(dep)
            else:
                plan.dependency_overrides.setdefault(dep.contract_name, {})
                value: object = [picked] if dep.is_array else picked
                plan.dependency_overrides[dep.contract_name][dep.param_name] = value
        else:
            # No implementers in the tree; user needs to wire this manually.
            plan.punted_deps.append(dep)

    return plan


def _pick_implementer(
    dep: UnresolvedDep,
    prompter: Optional[Prompter],
    yes_all: bool,
) -> Optional[str]:
    """Auto-pick single implementers; prompt when ambiguous (unless --yes)."""
    if len(dep.implementers) == 1:
        return dep.implementers[0]
    if yes_all or prompter is None:
        return None
    idx = prompter.pick(
        f'  {dep.contract_name}.{dep.param_name} ({dep.type_name}): pick an implementation',
        dep.implementers,
    )
    if idx is None:
        return None
    return dep.implementers[idx]


# =============================================================================
# APPLY PHASE (filesystem writes)
# =============================================================================

def apply(
    plan: InitPlan,
    report: InitReport,
    config_path: Path,
    stub_output_dir: Path,
    stub_emitter: Callable[[str, str, str], None],
    existing_config: Optional[dict] = None,
) -> None:
    """Write `transpiler-config.json`, scaffold stubs, write report.

    `stub_emitter` is a callable `(contract_name, source_file, output_file) ->
    None` — we depend on extruder's existing stub-emission machinery via this
    seam rather than importing `sol2ts` directly, which keeps the module
    acyclic and testable.

    `existing_config` is the pre-loaded config (if any); callers that already
    loaded it for `build_plan` should pass it through to avoid re-reading.
    """
    _write_config(plan, config_path, existing_config)

    stub_output_dir.mkdir(parents=True, exist_ok=True)
    for rel_path, contract_name in plan.replace_targets:
        abs_source = report.root / rel_path
        out = stub_output_dir / f'{contract_name}.ts'
        stub_emitter(contract_name, str(abs_source), str(out))

    # Report lives next to the config, not inside the source tree.
    _write_report(plan, report, config_path.parent / '.extruder-init-report.md')


def _load_config(path: Path) -> dict:
    """Read a `transpiler-config.json` — empty dict if missing or malformed.
    Warns once on invalid JSON; writers downstream clobber the file."""
    return TranspilerConfig.load(path, warn_missing=False).raw


def _write_config(
    plan: InitPlan, path: Path, existing: Optional[dict] = None,
) -> None:
    """Merge plan into existing config (if any), else create fresh. Loads
    from disk when `existing` is None; callers that already have it in
    memory should pass it through."""
    if existing is None:
        existing = _load_config(path)

    runtime_replacements = [
        {
            'source': rel_path,
            'reason': 'TODO: explain why this Solidity source needs a runtime replacement',
            'runtimeModule': '../runtime-replacements',
            'exports': [contract_name],
        }
        for rel_path, contract_name in plan.replace_targets
    ]

    merged = merge_config_updates(
        existing,
        skip_files=plan.skip_files,
        interface_aliases=plan.interface_aliases,
        dependency_overrides=plan.dependency_overrides,
        runtime_replacements=runtime_replacements,
    )

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(merged, indent=2) + '\n')
    print(f'Wrote {path}')


def _write_report(plan: InitPlan, report: InitReport, path: Path) -> None:
    lines: List[str] = []
    lines.append('# extruder init report')
    lines.append('')
    lines.append(f'Scanned: `{report.root}`')
    lines.append(f'Files: {len(report.files)} total')
    lines.append('')

    by_verdict: Dict[str, List[FileVerdict]] = {}
    for f in report.files:
        by_verdict.setdefault(f.verdict, []).append(f)

    for v in (OK, SKIP, REPLACE, MAYBE):
        entries = by_verdict.get(v, [])
        if not entries:
            continue
        lines.append(f'## {v} ({len(entries)})')
        lines.append('')
        show = entries if v != OK else entries[:0]  # don't list OK; too many
        for f in show:
            reason = '; '.join(f.reasons) if f.reasons else ''
            lines.append(f'- `{f.path}` — {reason}' if reason else f'- `{f.path}`')
        if v == OK:
            lines.append(f'{len(entries)} files passed without issue.')
        lines.append('')

    if plan.interface_aliases:
        lines.append('## Interface aliases added')
        lines.append('')
        for k, v in sorted(plan.interface_aliases.items()):
            lines.append(f'- `{k}` → `{v}`')
        lines.append('')

    tag_ifaces = report.by_classification(IFACE_TAG)
    if tag_ifaces:
        lines.append(
            f'## Tag interfaces ({len(tag_ifaces)}, ≥{TAG_INTERFACE_THRESHOLD} implementers)'
        )
        lines.append('')
        lines.append(
            'These interfaces have too many implementers to alias meaningfully. '
            'Treated as polymorphic tag interfaces — no alias added.'
        )
        lines.append('')
        for i in tag_ifaces:
            lines.append(f'- `{i.interface_name}` ({len(i.implementers)} implementers)')
        lines.append('')

    if plan.punted_interfaces:
        lines.append('## Punted interfaces')
        lines.append('')
        lines.append(
            'Multiple implementers; no choice made. Edit `interfaceAliases` '
            'in `transpiler-config.json` to resolve, or re-run `extruder init`.'
        )
        lines.append('')
        for name in plan.punted_interfaces:
            mapping = next(i for i in report.interfaces if i.interface_name == name)
            impls = ', '.join(mapping.implementers)
            lines.append(f'- `{name}` — implementers: {impls}')
        lines.append('')

    if plan.dependency_overrides:
        lines.append('## Dependency overrides added')
        lines.append('')
        for contract_name, params in sorted(plan.dependency_overrides.items()):
            for param_name, impl in sorted(params.items()):
                lines.append(f'- `{contract_name}.{param_name}` → `{impl}`')
        lines.append('')

    if plan.punted_deps:
        lines.append('## Punted dependency overrides')
        lines.append('')
        lines.append(
            'Constructor params the resolver could not map. Either no '
            'implementer exists in the scanned tree, or multiple implementers '
            'existed and no choice was made. Add entries to '
            '`dependencyOverrides` in `transpiler-config.json`.'
        )
        lines.append('')
        for d in plan.punted_deps:
            impls = ', '.join(d.implementers) if d.implementers else '(no implementers found)'
            lines.append(
                f'- `{d.contract_name}.{d.param_name}` ({d.type_name}) — candidates: {impls}'
            )
        lines.append('')

    if plan.punted_files:
        lines.append('## Files left for manual review')
        lines.append('')
        for p in plan.punted_files:
            lines.append(f'- `{p}`')
        lines.append('')

    lines.append('---')
    lines.append('')
    lines.append(
        'Next: fill in stub bodies under your runtime-replacements directory, '
        'then run extruder normally against your source tree.'
    )

    path.write_text('\n'.join(lines))
    print(f'Wrote {path}')


# =============================================================================
# CLI ENTRY POINT (called from sol2ts.main)
# =============================================================================

def run_init(
    source_root: str,
    yes: bool = False,
    stub_output_dir: Optional[str] = None,
    config_path: Optional[str] = None,
) -> None:
    """Top-level entry point wired from `extruder init`."""
    root = Path(source_root)
    if not root.is_dir():
        print(f'Error: {source_root} is not a directory')
        raise SystemExit(1)

    stub_dir = Path(stub_output_dir) if stub_output_dir else Path.cwd() / 'runtime-replacements'
    cfg_path = Path(config_path) if config_path else Path.cwd() / 'transpiler-config.json'

    registry = TypeRegistry()
    registry.discover_from_directory(str(root))

    print(f'Scanning {root}...')
    report = scan(root, registry, existing_config_path=cfg_path)
    print(
        f'  {len(report.by_verdict(OK))} OK, '
        f'{len(report.by_verdict(SKIP))} SKIP, '
        f'{len(report.by_verdict(REPLACE))} REPLACE, '
        f'{len(report.by_verdict(MAYBE))} MAYBE'
    )
    if report.unresolved_deps:
        print(f'  {len(report.unresolved_deps)} unresolved constructor dependencies')
    print()

    prompter = None if yes else Prompter()
    existing_config = _load_config(cfg_path)
    plan = build_plan(
        report, prompter=prompter, yes_all=yes, existing_config=existing_config,
    )

    # Import here to avoid circular dep with sol2ts module.
    from .sol2ts import emit_replacement_stub

    def stub_emitter(contract_name: str, source_file: str, output_file: str) -> None:
        emit_replacement_stub(
            contract_name=contract_name,
            source_file=source_file,
            output_file=output_file,
            discovery_dirs=[str(root)],
        )

    apply(plan, report, cfg_path, stub_dir, stub_emitter, existing_config=existing_config)

    print()
    print('Done. Review `.extruder-init-report.md` for decisions and next steps.')
