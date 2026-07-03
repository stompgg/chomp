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
                 types: 'RustTypeConverter', inferencer: 'TypeInferencer', symbols=None):
        self._ctx = ctx
        self._expr = expr
        self._types = types
        self._infer = inferencer
        self._symbols = symbols

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
            return self._gen_assembly(stmt)
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
                return self._gen_storage_local(decl, stmt.initial_value, t, rust_t)
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

        # Tuple destructuring (typed: diverging inits like abi.decode stubs
        # otherwise leave the pattern uninferrable)
        pats = []
        tys = []
        for d in stmt.declarations:
            if d is None or not d.name:
                pats.append('_')
                tys.append('_')
            else:
                pats.append(f'mut {rust_ident(d.name)}')
                dt = self._infer.from_type_name(d.type_name)
                tys.append(self._types.rust_type(dt) if dt.kind != 'unknown' else '_')
        init = self._expr.emit(stmt.initial_value) if stmt.initial_value else '()'
        annot = f': ({", ".join(tys)})' if any(t != '_' for t in tys) else ''
        return f'{self.ind()}let ({", ".join(pats)}){annot} = {init};'

    def _gen_storage_local(self, decl, init: Optional[Expression], t: SolType,
                           rust_t: str) -> str:
        """`X storage y = <place>;` — three shapes:

        1. Direct place path (mapping index / member path / ternary of
           places): REGISTER a substitution; every later use re-derives the
           place from world (no held borrow). Keys/conditions hoist to temps
           so they evaluate exactly once, like the Solidity binding.
        2. Helper call returning a storage ref (`_getMonState(...)`), or a
           member path off one: plain `let` binding of the `&mut` (NLL keeps
           it alive only to the last use).
        3. Declared without initializer (assigned in branches): deferred
           `let` of `&mut T`, assignments bind `&mut <place>`.
        """
        from ..parser.ast_nodes import FunctionCall as _FC
        name = decl.name

        if init is None:
            self._ctx.storage_ref_locals.add(name)
            return f'{self.ind()}let mut {rust_ident(name)}: &mut {rust_t};'

        def contains_call(e) -> bool:
            if isinstance(e, _FC):
                return True
            if isinstance(e, MemberAccess):
                return contains_call(e.expression)
            if isinstance(e, IndexAccess):
                return contains_call(e.base)
            if isinstance(e, TupleExpression) and len(e.components) == 1:
                return contains_call(e.components[0])
            return False

        if contains_call(init):
            # Place-selector helpers (`_getMonState(config, p, m)` — a single
            # return of a ternary over places) INLINE into a substitution:
            # a plain `&mut` binding would hold the battleConfig borrow across
            # every intervening world access until the local's last use.
            inlined = self._try_inline_place_helper(init)
            if inlined is not None:
                place, hoists = inlined
                self._ctx.storage_locals[name] = {'place': place, 'key': None, 'root': None}
                self._ctx.current_local_vars.add(name)
                if decl.type_name is not None:
                    self._ctx.var_types[name] = decl.type_name
                lines = [f'{self.ind()}{h}' for h in hoists]
                lines.append(f'{self.ind()}// storage local `{name}` inlined from place helper')
                return '\n'.join(lines)
            self._ctx.storage_ref_locals.add(name)
            code, _ = self._expr.emit_typed(init)
            if isinstance(init, MemberAccess):
                # e.g. `_getTeamMon(...).stats` — reborrow the field place
                return f'{self.ind()}let mut {rust_ident(name)} = &mut {code};'
            return f'{self.ind()}let mut {rust_ident(name)} = {code};'

        # Direct place: register a substitution with hoisted keys.
        hoists: list = []
        place, _pt = self._expr.emit_place(init, hoists)
        key_text = None
        root = None
        if isinstance(init, IndexAccess) and isinstance(init.base, Identifier):
            base_name = init.base.name
            container = self._ctx.current_class_name
            svars = self._symbols.state_vars.get(container, {})
            st = svars.get(base_name)
            if st is not None and st.kind == 'mapping':
                root = (container, base_name, st.key)
                # emit_place hoisted the key as the LAST temp
                if hoists:
                    key_text = hoists[-1].split(' ')[1]
        self._ctx.storage_locals[name] = {'place': place, 'key': key_text, 'root': root}
        self._ctx.current_local_vars.add(name)
        if decl.type_name is not None:
            self._ctx.var_types[name] = decl.type_name
        lines = [f'{self.ind()}{h}' for h in hoists]
        if not lines:
            return f'{self.ind()}// storage local `{name}` substituted in place'
        return '\n'.join(lines)

    def _try_inline_place_helper(self, init: Expression):
        """If ``init`` is a call (possibly with a trailing member path) to a
        same-container helper whose body is a single `return <place>;` over
        its own params, inline it: bind value args to hoisted temps, storage
        args to their existing substitutions, and emit the body as a place.
        Returns (place_text, hoist_lines) or None."""
        from ..parser.ast_nodes import FunctionCall as _FC, ReturnStatement as _Ret

        trailing = []  # member path applied after the call: `.stats`
        node = init
        while isinstance(node, MemberAccess):
            trailing.append(node.member)
            node = node.expression
        if not isinstance(node, _FC) or not isinstance(node.function, Identifier):
            return None
        fname = node.function.name
        ov = self._symbols.lookup_overload(
            self._ctx.current_class_name, fname, len(node.arguments)
        ) if self._symbols else None
        if ov is None:
            return None
        # find the matching def
        fdef = None
        for key in ((self._ctx.current_class_name, fname),):
            for cand_sig, cand_def in self._symbols.overloads.get(key, []):
                if len(cand_sig.param_types) == len(node.arguments):
                    fdef = cand_def
        if fdef is None:
            for base in self._symbols.flatten_bases.get(self._ctx.current_class_name, []):
                for cand_sig, cand_def in self._symbols.overloads.get((base, fname), []):
                    if len(cand_sig.param_types) == len(node.arguments):
                        fdef = cand_def
        if fdef is None or fdef.body is None or len(fdef.body.statements) != 1:
            return None
        ret = fdef.body.statements[0]
        if not isinstance(ret, _Ret) or ret.expression is None:
            return None
        if not _is_place_shape(ret.expression):
            return None

        hoists: list = []
        saved = (dict(self._ctx.storage_locals), dict(self._ctx.alias_map),
                 set(self._ctx.current_local_vars), dict(self._ctx.var_types))
        try:
            for p, arg in zip(fdef.parameters, node.arguments):
                if getattr(p, 'storage_location', '') == 'storage':
                    if isinstance(arg, Identifier) and arg.name in self._ctx.storage_locals:
                        self._ctx.storage_locals[p.name] = self._ctx.storage_locals[arg.name]
                    elif isinstance(arg, Identifier) and (
                            arg.name in self._ctx.ref_params
                            or arg.name in self._ctx.storage_ref_locals):
                        # `&mut T` param/local: re-borrow through it per use.
                        self._ctx.storage_locals[p.name] = {
                            'place': f'(*{rust_ident(arg.name)})',
                            'key': None, 'root': None,
                        }
                    else:
                        return None  # storage arg we can't re-derive
                else:
                    tmp = self._ctx.fresh_temp('ph')
                    hoists.append(f'let {tmp} = {self._expr.emit(arg)};')
                    self._ctx.alias_map[p.name] = tmp
                    self._ctx.current_local_vars.add(tmp)
                    if p.type_name is not None:
                        self._ctx.var_types[tmp] = p.type_name
                        self._ctx.var_types[p.name] = p.type_name
            place, _ = self._expr.emit_place(ret.expression, hoists)
            for member in reversed(trailing):
                place = f'{place}.{rust_ident(member)}'
            return place, hoists
        finally:
            (self._ctx.storage_locals, self._ctx.alias_map,
             self._ctx.current_local_vars, self._ctx.var_types) = saved

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
        if getattr(self._ctx, 'current_fn_returns_storage', False) and stmt.expression is not None:
            # Storage-returning fn: hand back a reference to the place.
            from ..parser.ast_nodes import TernaryOperation as _T
            if isinstance(stmt.expression, _T):
                cond = self._expr.emit(stmt.expression.condition, BOOL)
                a, _ = self._expr.emit_place(stmt.expression.true_expression)
                b, _ = self._expr.emit_place(stmt.expression.false_expression)
                return f'{self.ind()}return if {cond} {{ &mut {a} }} else {{ &mut {b} }};'
            place, _ = self._expr.emit_place(stmt.expression)
            return f'{self.ind()}return &mut {place};'
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

        # Deferred storage-ref local being (re)bound to a storage place:
        # `effectInstance = config.globalEffects[idx];` -> bind the &mut.
        if (expr.operator == '=' and isinstance(expr.left, Identifier)
                and expr.left.name in self._ctx.storage_ref_locals):
            place, _ = self._expr.emit_place(expr.right)
            return f'{self.ind()}{rust_ident(expr.left.name)} = &mut {place};'

        lhs_code, _ = self._expr.emit_place(expr.left)
        lhs_is_world_place = '.get_mut(' in lhs_code or lhs_code.startswith('world.')

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
            out_lines = []
            if lhs_is_world_place:
                # RHS may traverse world too; evaluate it first.
                tmp = self._ctx.fresh_temp('rhs')
                out_lines.append(f'{self.ind()}let {tmp} = {rhs};')
                out_lines.append(f'{self.ind()}{lhs_code} = {tmp};')
                out = '\n'.join(out_lines)
            else:
                out = f'{self.ind()}{lhs_code} = {rhs};'
            self._maybe_record_alias(expr.left, expr.right, lhs_t)
            return out

        op = expr.operator[:-1]  # '+=' -> '+'
        rhs = self._expr.emit(expr.right, lhs_t)

        def compound(value_expr_of) -> str:
            """Emit `place = f(place, rhs)` safely for world places: hoist
            the RHS, take one &mut to the place, update through it."""
            if not lhs_is_world_place:
                return f'{self.ind()}{lhs_code} = {value_expr_of(lhs_code, rhs)};'
            r = self._ctx.fresh_temp('rhs')
            p = self._ctx.fresh_temp('p')
            return (
                f'{self.ind()}{{ let {r} = {rhs}; '
                f'let {p} = &mut {lhs_code}; '
                f'*{p} = {value_expr_of(f"(*{p})", r)}; }}'
            )

        if op in ('<<', '>>'):
            amt = self._expr._shift_amount(expr.right)
            method = 'sol_shl' if op == '<<' else 'sol_shr'

            def shift_value(lhs, _r):
                out = f'{lhs}.{method}({amt})'
                if op == '<<':
                    out = self._expr._mask_odd_width(out, lhs_t)
                return out

            if not lhs_is_world_place:
                return f'{self.ind()}{lhs_code} = {shift_value(lhs_code, rhs)};'
            p = self._ctx.fresh_temp('p')
            return (
                f'{self.ind()}{{ let {p} = &mut {lhs_code}; '
                f'*{p} = {shift_value(f"(*{p})", rhs)}; }}'
            )

        if lhs_t.is_wide:
            if op in ('+', '-', '*'):
                method = _WIDE_UNCHECKED[op] if self._ctx.unchecked else _WIDE_CHECKED[op]
                return compound(lambda l, r: f'{l}.{method}({r})')
            if op in ('/', '%'):
                if self._ctx.unchecked and lhs_t.kind == 'int':
                    method = 'wrapping_div' if op == '/' else 'wrapping_rem'
                    return compound(lambda l, r: f'{l}.{method}({r})')
                if lhs_t.kind == 'int':
                    # alloy's raw I256 Div/Rem only debug_assert on overflow
                    # (release would silently wrap MIN /= -1); route through
                    # the checked helpers like the expression path does.
                    method = 'sol_div' if op == '/' else 'sol_rem'
                    return compound(lambda l, r: f'{l}.{method}({r})')
                return compound(lambda l, r: f'{l} {op} ({r})')
            return compound(lambda l, r: f'{l} {op} ({r})')

        # native
        if self._ctx.unchecked and op in _NATIVE_UNCHECKED:
            return compound(lambda l, r: f'{l}.{_NATIVE_UNCHECKED[op]}({r})')
        if op == '%' and lhs_t.kind == 'int':
            # Checked signed %=: Solidity's MIN % -1 == 0 (see rt::srem).
            return compound(lambda l, r: f'rt::srem({l}, {r})')
        if lhs_is_world_place:
            return compound(lambda l, r: f'{l} {op} ({r})')
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

    # ------------------------------------------------------------------
    # Inline assembly: known-block registry (see _KNOWN_YUL_NOTE)
    # ------------------------------------------------------------------

    def _gen_assembly(self, stmt: AssemblyStatement) -> str:
        import re
        # The lexer re-joins Yul with spaces around every token
        # (`monState . slot`, `mstore ( a , b )`); compact punctuation so the
        # shape patterns below can match the canonical source spelling.
        code = re.sub(r'\s*([().,])\s*', r'\1', stmt.block.code)

        # Shape 1: MonState sentinel slot-clear (startBattle recycling).
        # `let slot := X.slot ... eq(v, PACKED_CLEARED_MON_STATE) ... sstore`
        if 'PACKED_CLEARED_MON_STATE' in code and '.slot' in code:
            m = re.search(r'let\s+slot\s*:=\s*(\w+)\.slot', code)
            if m:
                from ..parser.ast_nodes import Identifier as _Id
                place, _ = self._expr.emit_typed(_Id(name=m.group(1)))
                p = self._ctx.fresh_temp('ms')
                return (
                    f'{self.ind()}{{ let {p} = &mut {place}; '
                    f'if *{p} != Default::default() && *{p} != crate::world::cleared_mon_state() '
                    f'{{ *{p} = crate::world::cleared_mon_state(); }} }}'
                )

        # Shape 3: batch event-payload packer (_packBatchPayload).
        if 'calldataload' in code and 'shl(104' in code:
            return (
                f'{self.ind()}{{ let __n = rt::usize(numTurns); '
                f'let mut __p: Vec<u8> = Vec::with_capacity(20 + __n * 19); '
                f'__p.extend_from_slice(winner.as_slice()); '
                f'for __i in 0..__n {{ '
                f'let __w = (*entries)[__i].to_be_bytes::<32>(); '
                f'__p.extend_from_slice(&__w[13..32]); }} '
                f'payload = __p; }}'
            )

        # Shape 2: memory-array length shrink — every statement in the block
        # is `mstore(<ident>, <ident>)`.
        stmts = [s.strip() for s in code.replace('\n', ' ').split() if s.strip()]
        pairs = re.findall(r'mstore\(\s*(\w+)\s*,\s*(\w+)\s*\)', code)
        non_ws = re.sub(r'\s+', '', code)
        rebuilt = ''.join(f'mstore({a},{b})' for a, b in pairs)
        if pairs and non_ws == rebuilt:
            from ..parser.ast_nodes import Identifier as _Id
            lines = []
            for arr, ln in pairs:
                arr_code, _ = self._expr.emit_typed(_Id(name=arr))
                ln_code, ln_t = self._expr.emit_typed(_Id(name=ln))
                idx = f'rt::usize({ln_code})' if ln_t.is_wide else f'({ln_code} as usize)'
                lines.append(f'{self.ind()}{arr_code}.truncate({idx});')
            return '\n'.join(lines)

        self._ctx.warn('unrecognized inline assembly block (add to the known-block registry)')
        return f'{self.ind()}unimplemented!("unrecognized inline assembly");'

    def _gen_delete(self, stmt: DeleteStatement) -> str:
        # `delete m[k]` on a mapping removes the entry (reads then see zero).
        if isinstance(stmt.expression, IndexAccess):
            base_t = self._infer.infer(stmt.expression.base)
            if base_t.kind == 'mapping':
                base_place, _ = self._expr.emit_place(stmt.expression.base)
                key = self._expr.emit(stmt.expression.index, base_t.key or UNKNOWN)
                return f'{self.ind()}{base_place}.remove(&{key});'
        t = self._infer.infer(stmt.expression)
        code, _ = self._expr.emit_place(stmt.expression)
        default = self._types.default_value(t)
        return f'{self.ind()}{code} = {default};'


_KNOWN_YUL_NOTE = (
    'Known-block Yul registry: the engine has exactly 3 assembly shapes '
    '(MonState sentinel slot-clear, memory-array length shrink, the batch '
    'event-payload packer). Each is recognized structurally and replaced '
    'with a semantic Rust equivalent; anything else stays a loud stub.'
)


def _panic_message(quoted: str) -> str:
    """Quoted Solidity string literal -> safe panic! format string.

    panic!'s first argument is a FORMAT string: a revert message containing
    `{` or `}` would be parsed as a format placeholder (compile error or
    worse). Escape braces so the message is emitted verbatim."""
    return quoted.replace('{', '{{').replace('}', '}}')


def _is_place_shape(expr) -> bool:
    """Places only: identifiers, member/index paths, ternaries of places."""
    from ..parser.ast_nodes import TernaryOperation as _T
    if isinstance(expr, Identifier):
        return True
    if isinstance(expr, MemberAccess):
        return _is_place_shape(expr.expression)
    if isinstance(expr, IndexAccess):
        return _is_place_shape(expr.base)  # index exprs may be arbitrary values
    if isinstance(expr, _T):
        return _is_place_shape(expr.true_expression) and _is_place_shape(expr.false_expression)
    if isinstance(expr, TupleExpression) and len(expr.components) == 1:
        return _is_place_shape(expr.components[0])
    return False


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
