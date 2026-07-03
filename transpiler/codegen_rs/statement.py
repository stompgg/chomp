"""Rust statement emission.

Notable desugarings:
- ``for`` loops become ``loop`` + explicit condition/post so that Solidity
  ``continue`` still executes the post-expression: the body is wrapped in a
  labeled block and ``continue`` becomes ``break 'label`` (labels are unique
  per nesting depth). ``break`` maps to plain ``break`` (binds to the loop —
  unlabeled break/continue never bind to labeled blocks).
- ``unchecked { ... }`` toggles wrapping arithmetic in the expression
  generator for the duration of the block.
- Compound assignment re-emits the (side-effect-free) place expression:
  ``a[k] += v`` -> ``a[k] = a[k].sol_add(v)`` for wide types, native checked
  stays ``+=`` (overflow-checks panics), native unchecked becomes
  ``wrapping_add``.
"""

from typing import List, Optional, TYPE_CHECKING

from ..parser.ast_nodes import (
    AssemblyStatement,
    BinaryOperation,
    Block,
    BreakStatement,
    ContinueStatement,
    DeleteStatement,
    DoWhileStatement,
    EmitStatement,
    Expression,
    ExpressionStatement,
    ForStatement,
    FunctionCall,
    Identifier,
    IfStatement,
    IndexAccess,
    Literal,
    MemberAccess,
    ReturnStatement,
    RevertStatement,
    Statement,
    TupleExpression,
    UnaryOperation,
    VariableDeclarationStatement,
    WhileStatement,
)
from .soltypes import BOOL, SolType, UNKNOWN, UINT256
from .rust_types import rust_ident

if TYPE_CHECKING:
    from .context import RustCodeGenerationContext
    from .expression import RustExpressionGenerator
    from .soltypes import TypeInferencer
    from .rust_types import RustTypeConverter


_WIDE_CHECKED = {'+': 'sol_add', '-': 'sol_sub', '*': 'sol_mul'}
_WIDE_UNCHECKED = {'+': 'wrapping_add', '-': 'wrapping_sub', '*': 'wrapping_mul'}
_NATIVE_UNCHECKED = {'+': 'wrapping_add', '-': 'wrapping_sub', '*': 'wrapping_mul',
                     '/': 'wrapping_div', '%': 'wrapping_rem'}


class RustStatementGenerator:
    def __init__(self, ctx: 'RustCodeGenerationContext', expr: 'RustExpressionGenerator',
                 types: 'RustTypeConverter', inferencer: 'TypeInferencer'):
        self._ctx = ctx
        self._expr = expr
        self._types = types
        self._infer = inferencer

    # ------------------------------------------------------------------

    def generate(self, stmt: Statement) -> str:
        if isinstance(stmt, Block):
            return self.generate_block(stmt)
        if isinstance(stmt, VariableDeclarationStatement):
            return self._gen_var_decl(stmt)
        if isinstance(stmt, IfStatement):
            return self._gen_if(stmt)
        if isinstance(stmt, ForStatement):
            return self._gen_for(stmt)
        if isinstance(stmt, WhileStatement):
            return self._gen_while(stmt)
        if isinstance(stmt, DoWhileStatement):
            return self._gen_do_while(stmt)
        if isinstance(stmt, ReturnStatement):
            return self._gen_return(stmt)
        if isinstance(stmt, BreakStatement):
            top = self._ctx.loop_stack[-1] if self._ctx.loop_stack else None
            if top is not None and top['body_label'] is not None:
                # Inside the labeled body block an unlabeled `break` is
                # rejected by Rust (E0695): target the loop label explicitly.
                return f"{self.ind()}break {top['loop_label']};"
            return f'{self.ind()}break;'
        if isinstance(stmt, ContinueStatement):
            top = self._ctx.loop_stack[-1] if self._ctx.loop_stack else None
            if top is None or top['kind'] == 'while':
                # Plain `continue` re-tests a while condition — correct.
                return f'{self.ind()}continue;'
            # for / do-while: jump to the post-expression / condition check,
            # which live after the labeled body block.
            return f"{self.ind()}break {top['body_label']};"
        if isinstance(stmt, EmitStatement):
            return self._gen_emit(stmt)
        if isinstance(stmt, RevertStatement):
            return self._gen_revert(stmt)
        if isinstance(stmt, DeleteStatement):
            return self._gen_delete(stmt)
        if isinstance(stmt, AssemblyStatement):
            self._ctx.warn('inline assembly reached the Rust backend (Phase 2 decision pending)')
            return f'{self.ind()}unimplemented!("inline assembly not supported by the Rust backend yet");'
        if isinstance(stmt, ExpressionStatement):
            return self._gen_expr_stmt(stmt)
        self._ctx.warn(f'unhandled statement {type(stmt).__name__}')
        return f'{self.ind()}unimplemented!("unhandled statement {type(stmt).__name__}");'

    def ind(self) -> str:
        return self._ctx.indent()

    # ------------------------------------------------------------------
    # Blocks
    # ------------------------------------------------------------------

    def generate_block(self, block: Block) -> str:
        lines = []
        unchecked = getattr(block, 'is_unchecked', False)
        header = '{' if not unchecked else '{ // unchecked'
        lines.append(f'{self.ind()}{header}')
        if unchecked:
            self._ctx.unchecked_depth += 1
        self._ctx.indent_level += 1
        for s in block.statements:
            lines.append(self.generate(s))
        self._ctx.indent_level -= 1
        if unchecked:
            self._ctx.unchecked_depth -= 1
        lines.append(f'{self.ind()}}}')
        return '\n'.join(lines)

    def _gen_body(self, body: Statement, lines: List[str]) -> None:
        if isinstance(body, Block):
            unchecked = getattr(body, 'is_unchecked', False)
            if unchecked:
                self._ctx.unchecked_depth += 1
            for s in body.statements:
                lines.append(self.generate(s))
            if unchecked:
                self._ctx.unchecked_depth -= 1
        else:
            lines.append(self.generate(body))

    # ------------------------------------------------------------------
    # Declarations
    # ------------------------------------------------------------------

    def _gen_var_decl(self, stmt: VariableDeclarationStatement) -> str:
        for decl in stmt.declarations:
            if decl and decl.name:
                self._ctx.current_local_vars.add(decl.name)
                if decl.type_name:
                    self._ctx.var_types[decl.name] = decl.type_name

        if len(stmt.declarations) == 1 and stmt.declarations[0] is not None:
            decl = stmt.declarations[0]
            t = self._infer.from_type_name(decl.type_name)
            rust_t = self._types.rust_type(t)
            if decl.storage_location == 'storage':
                self._ctx.warn(f'storage pointer local `{decl.name}` (Phase 2 storage model)')
            if stmt.initial_value is not None:
                init = self._expr.emit(stmt.initial_value, t)
                init = self._clone_if_place(init, stmt.initial_value, t)
                if isinstance(stmt.initial_value, Identifier):
                    self._maybe_record_alias(
                        Identifier(name=decl.name), stmt.initial_value, t
                    )
            else:
                init = self._types.default_value(t)
            return f'{self.ind()}let mut {rust_ident(decl.name)}: {rust_t} = {init};'

        # Tuple destructuring
        pats = []
        for d in stmt.declarations:
            if d is None or not d.name:
                pats.append('_')
            else:
                pats.append(f'mut {rust_ident(d.name)}')
        init = self._expr.emit(stmt.initial_value) if stmt.initial_value else '()'
        return f'{self.ind()}let ({", ".join(pats)}) = {init};'

    def _maybe_record_alias(self, lhs: Expression, rhs: Expression, t: SolType) -> None:
        """`local = refParam` (whole memory array/struct): in Solidity both
        names now alias one memory object. Redirect the param name to the
        owned local so later reads/writes see the same values (bit-correct
        for intra-function aliasing; the caller-side copy boundary is the
        documented &mut-param model divergence the differential gates watch).
        """
        if not t.is_memory_ref:
            return
        if not (isinstance(lhs, Identifier) and isinstance(rhs, Identifier)):
            return
        if rhs.name in self._ctx.ref_params and lhs.name in self._ctx.current_local_vars:
            self._ctx.alias_map[rhs.name] = lhs.name

    def _clone_if_place(self, code: str, expr: Expression, t: SolType) -> str:
        """Memory-to-memory assignment ALIASES in Solidity; Rust copies. For
        Copy types the copy is bit-identical; for non-Copy (Vec-backed) we
        clone and record the (documented) alias-vs-copy divergence, which the
        differential gates watch for."""
        if self._types.is_copy(t):
            return code
        if isinstance(expr, (Identifier, IndexAccess, MemberAccess)):
            if t.kind in ('array', 'struct', 'string', 'bytes'):
                return f'{code}.clone()'
        return code

    # ------------------------------------------------------------------
    # Control flow
    # ------------------------------------------------------------------

    def _gen_if(self, stmt: IfStatement) -> str:
        lines = []
        cond = self._expr.emit(stmt.condition, BOOL)
        lines.append(f'{self.ind()}if {cond} {{')
        self._ctx.indent_level += 1
        self._gen_body(stmt.true_body, lines)
        self._ctx.indent_level -= 1
        if stmt.false_body is not None:
            if isinstance(stmt.false_body, IfStatement):
                nested = self._gen_if(stmt.false_body)
                lines.append(f'{self.ind()}}} else {nested.lstrip()}')
            else:
                lines.append(f'{self.ind()}}} else {{')
                self._ctx.indent_level += 1
                self._gen_body(stmt.false_body, lines)
                self._ctx.indent_level -= 1
                lines.append(f'{self.ind()}}}')
        else:
            lines.append(f'{self.ind()}}}')
        return '\n'.join(lines)

    def _gen_for(self, stmt: ForStatement) -> str:
        lines = []
        lines.append(f'{self.ind()}{{')
        self._ctx.indent_level += 1

        if stmt.init is not None:
            if isinstance(stmt.init, VariableDeclarationStatement):
                lines.append(self._gen_var_decl(stmt.init))
            else:
                lines.append(self._gen_expr_stmt(stmt.init))

        cond = self._expr.emit(stmt.condition, BOOL) if stmt.condition is not None else 'true'
        has_continue = stmt.body is not None and _contains_continue(stmt.body)
        depth = len(self._ctx.loop_stack) + 1
        body_label = f"'__body{depth}" if has_continue else None
        loop_label = f"'__loop{depth}" if has_continue else None

        loop_prefix = f'{loop_label}: ' if loop_label else ''
        lines.append(f'{self.ind()}{loop_prefix}loop {{')
        self._ctx.indent_level += 1
        # This break sits outside any labeled body block; unlabeled is fine.
        lines.append(f'{self.ind()}if !({cond}) {{ break; }}')

        self._ctx.loop_stack.append(
            {'kind': 'for', 'body_label': body_label, 'loop_label': loop_label}
        )
        if has_continue:
            lines.append(f'{self.ind()}{body_label}: {{')
            self._ctx.indent_level += 1
        if stmt.body is not None:
            self._gen_body(stmt.body, lines)
        if has_continue:
            self._ctx.indent_level -= 1
            lines.append(f'{self.ind()}}}')
        self._ctx.loop_stack.pop()

        if stmt.post is not None:
            lines.append(self._gen_loose_expression(stmt.post))

        self._ctx.indent_level -= 1
        lines.append(f'{self.ind()}}}')
        self._ctx.indent_level -= 1
        lines.append(f'{self.ind()}}}')
        return '\n'.join(lines)

    def _gen_while(self, stmt: WhileStatement) -> str:
        lines = []
        cond = self._expr.emit(stmt.condition, BOOL)
        lines.append(f'{self.ind()}while {cond} {{')
        self._ctx.indent_level += 1
        self._ctx.loop_stack.append({'kind': 'while', 'body_label': None, 'loop_label': None})
        self._gen_body(stmt.body, lines)
        self._ctx.loop_stack.pop()
        self._ctx.indent_level -= 1
        lines.append(f'{self.ind()}}}')
        return '\n'.join(lines)

    def _gen_do_while(self, stmt: DoWhileStatement) -> str:
        # Solidity `continue` in do-while jumps to the CONDITION check, so the
        # body gets the same labeled-block treatment as for-loops (a plain
        # Rust `continue` would skip the trailing condition — wrong).
        lines = []
        has_continue = _contains_continue(stmt.body)
        depth = len(self._ctx.loop_stack) + 1
        body_label = f"'__body{depth}" if has_continue else None
        loop_label = f"'__loop{depth}" if has_continue else None

        loop_prefix = f'{loop_label}: ' if loop_label else ''
        lines.append(f'{self.ind()}{loop_prefix}loop {{')
        self._ctx.indent_level += 1
        self._ctx.loop_stack.append(
            {'kind': 'dowhile', 'body_label': body_label, 'loop_label': loop_label}
        )
        if has_continue:
            lines.append(f'{self.ind()}{body_label}: {{')
            self._ctx.indent_level += 1
        self._gen_body(stmt.body, lines)
        if has_continue:
            self._ctx.indent_level -= 1
            lines.append(f'{self.ind()}}}')
        self._ctx.loop_stack.pop()
        cond = self._expr.emit(stmt.condition, BOOL)
        lines.append(f'{self.ind()}if !({cond}) {{ break; }}')
        self._ctx.indent_level -= 1
        lines.append(f'{self.ind()}}}')
        return '\n'.join(lines)

    # ------------------------------------------------------------------
    # Return
    # ------------------------------------------------------------------

    # Set by the function generator before emitting a body.
    named_returns: List[str] = []
    return_types: List[SolType] = []

    def _gen_return(self, stmt: ReturnStatement) -> str:
        if stmt.expression is None:
            if self.named_returns:
                return f'{self.ind()}return {self._named_return_value()};'
            return f'{self.ind()}return;'
        if len(self.return_types) > 1 and isinstance(stmt.expression, TupleExpression) \
                and len(stmt.expression.components) == len(self.return_types):
            parts = []
            for comp, t in zip(stmt.expression.components, self.return_types):
                code = self._expr.emit(comp, t)
                parts.append(self._clone_if_place(code, comp, t))
            return f'{self.ind()}return ({", ".join(parts)});'
        t = self.return_types[0] if len(self.return_types) == 1 else UNKNOWN
        code = self._expr.emit(stmt.expression, t)
        if len(self.return_types) == 1:
            code = self._clone_if_place(code, stmt.expression, t)
        return f'{self.ind()}return {code};'

    def _named_return_value(self) -> str:
        names = [rust_ident(n) for n in self.named_returns]
        if len(names) == 1:
            return names[0]
        return f'({", ".join(names)})'

    # ------------------------------------------------------------------
    # Expression statements (assignments, calls, require, ++/--)
    # ------------------------------------------------------------------

    def _gen_expr_stmt(self, stmt: ExpressionStatement) -> str:
        return self._gen_loose_expression(stmt.expression)

    def _gen_loose_expression(self, expr: Expression) -> str:
        # require / assert
        if isinstance(expr, FunctionCall) and isinstance(expr.function, Identifier):
            name = expr.function.name
            if name in ('require', 'assert'):
                cond = self._expr.emit(expr.arguments[0], BOOL)
                if len(expr.arguments) >= 2 and isinstance(expr.arguments[1], Literal) \
                        and expr.arguments[1].kind == 'string':
                    msg = _panic_message(expr.arguments[1].value)
                else:
                    msg = f'"{name.capitalize()} failed"'
                return f'{self.ind()}if !({cond}) {{ panic!({msg}); }}'

        # assignments
        if isinstance(expr, BinaryOperation) and (
            expr.operator == '=' or expr.operator in
            ('+=', '-=', '*=', '/=', '%=', '|=', '&=', '^=', '<<=', '>>=')
        ):
            return self._gen_assignment(expr)

        # ++ / --
        if isinstance(expr, UnaryOperation) and expr.operator in ('++', '--'):
            op = '+' if expr.operator == '++' else '-'
            one = Literal(value='1', kind='number')
            synthetic = BinaryOperation(left=expr.operand, operator=op + '=', right=one)
            return self._gen_assignment(synthetic)

        code = self._expr.emit(expr)
        return f'{self.ind()}{code};'

    def _gen_assignment(self, expr: BinaryOperation) -> str:
        lhs_t = self._infer.infer(expr.left)

        # Tuple assignment: (a, b) = f(...)
        if isinstance(expr.left, TupleExpression) and expr.operator == '=':
            pats = []
            for comp in expr.left.components:
                if comp is None:
                    pats.append('_')
                else:
                    code, _ = self._expr.emit_typed(comp)
                    pats.append(code)
            rhs = self._expr.emit(expr.right)
            # Rust has no tuple-assignment; destructure into temps then move.
            tmp_names = [f'__t{i}' for i in range(len(pats))]
            lines = [f'{self.ind()}let ({", ".join(tmp_names)}) = {rhs};']
            for pat, tmp in zip(pats, tmp_names):
                if pat != '_':
                    lines.append(f'{self.ind()}{pat} = {tmp};')
                else:
                    lines.append(f'{self.ind()}let _ = {tmp};')
            return '\n'.join(lines)

        lhs_code, _ = self._expr.emit_typed(expr.left)

        if expr.operator == '=':
            if (isinstance(expr.left, Identifier)
                    and expr.left.name in self._ctx.ref_params
                    and lhs_t.is_memory_ref):
                # Solidity rebinding a memory parameter (`arr = ...`) is a
                # LOCAL rebind; the &mut model writes through to the caller.
                # No phase-1 code does this — flag loudly if it appears.
                self._ctx.warn(
                    f'memory parameter `{expr.left.name}` is reassigned: the &mut '
                    f'model writes through to the caller instead of rebinding locally'
                )
            rhs = self._expr.emit(expr.right, lhs_t)
            rhs = self._clone_if_place(rhs, expr.right, lhs_t)
            out = f'{self.ind()}{lhs_code} = {rhs};'
            self._maybe_record_alias(expr.left, expr.right, lhs_t)
            return out

        op = expr.operator[:-1]  # '+=' -> '+'
        rhs = self._expr.emit(expr.right, lhs_t)

        if op in ('<<', '>>'):
            amt = self._expr._shift_amount(expr.right)
            method = 'sol_shl' if op == '<<' else 'sol_shr'
            out = f'{lhs_code}.{method}({amt})'
            if op == '<<':
                out = self._expr._mask_odd_width(out, lhs_t)
            return f'{self.ind()}{lhs_code} = {out};'

        if lhs_t.is_wide:
            if op in ('+', '-', '*'):
                method = _WIDE_UNCHECKED[op] if self._ctx.unchecked else _WIDE_CHECKED[op]
                return f'{self.ind()}{lhs_code} = {lhs_code}.{method}({rhs});'
            if op in ('/', '%'):
                if self._ctx.unchecked and lhs_t.kind == 'int':
                    method = 'wrapping_div' if op == '/' else 'wrapping_rem'
                    return f'{self.ind()}{lhs_code} = {lhs_code}.{method}({rhs});'
                if lhs_t.kind == 'int':
                    # alloy's raw I256 Div/Rem only debug_assert on overflow
                    # (release would silently wrap MIN /= -1); route through
                    # the checked helpers like the expression path does.
                    method = 'sol_div' if op == '/' else 'sol_rem'
                    return f'{self.ind()}{lhs_code} = {lhs_code}.{method}({rhs});'
                return f'{self.ind()}{lhs_code} = {lhs_code} {op} ({rhs});'
            return f'{self.ind()}{lhs_code} = {lhs_code} {op} ({rhs});'

        # native
        if self._ctx.unchecked and op in _NATIVE_UNCHECKED:
            return f'{self.ind()}{lhs_code} = {lhs_code}.{_NATIVE_UNCHECKED[op]}({rhs});'
        if op == '%' and lhs_t.kind == 'int':
            # Checked signed %=: Solidity's MIN % -1 == 0 (see rt::srem).
            return f'{self.ind()}{lhs_code} = rt::srem({lhs_code}, {rhs});'
        return f'{self.ind()}{lhs_code} {op}= {rhs};'

    # ------------------------------------------------------------------
    # emit / revert / delete
    # ------------------------------------------------------------------

    def _gen_emit(self, stmt: EmitStatement) -> str:
        # Event stream lands with Phase 3 (feature-flagged); events don't
        # affect battle-state fidelity.
        name = ''
        if isinstance(stmt.event_call, FunctionCall) and isinstance(stmt.event_call.function, Identifier):
            name = stmt.event_call.function.name
        self._ctx.info(f'event emission `{name}` skipped (event stream is Phase 3, feature-flagged)')
        return f'{self.ind()}// emit {name} (event stream: Phase 3)'

    def _gen_revert(self, stmt: RevertStatement) -> str:
        if stmt.error_call is not None:
            if isinstance(stmt.error_call, Identifier):
                return f'{self.ind()}panic!("{stmt.error_call.name}");'
            if isinstance(stmt.error_call, FunctionCall) and isinstance(stmt.error_call.function, Identifier):
                return f'{self.ind()}panic!("{stmt.error_call.function.name}");'
            if isinstance(stmt.error_call, Literal) and stmt.error_call.kind == 'string':
                return f'{self.ind()}panic!({_panic_message(stmt.error_call.value)});'
        return f'{self.ind()}panic!("Revert");'

    def _gen_delete(self, stmt: DeleteStatement) -> str:
        t = self._infer.infer(stmt.expression)
        code, _ = self._expr.emit_typed(stmt.expression)
        default = self._types.default_value(t)
        return f'{self.ind()}{code} = {default};'


def _panic_message(quoted: str) -> str:
    """Quoted Solidity string literal -> safe panic! format string.

    panic!'s first argument is a FORMAT string: a revert message containing
    `{` or `}` would be parsed as a format placeholder (compile error or
    worse). Escape braces so the message is emitted verbatim."""
    return quoted.replace('{', '{{').replace('}', '}}')


def _contains_continue(stmt: Statement) -> bool:
    """True if the statement (without descending into nested loops) contains
    a ContinueStatement that would bind to the CURRENT loop."""
    if isinstance(stmt, ContinueStatement):
        return True
    if isinstance(stmt, Block):
        return any(_contains_continue(s) for s in stmt.statements)
    if isinstance(stmt, IfStatement):
        if _contains_continue(stmt.true_body):
            return True
        return stmt.false_body is not None and _contains_continue(stmt.false_body)
    # for/while/do-while own their continues
    return False
