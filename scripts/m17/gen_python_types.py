#!/usr/bin/env python3
"""Generate the Python standard-library type table (M17 T17.10).

Reads every typeshed `stdlib/` stub with the standard-library `ast` module,
evaluates `sys.version_info` for 3.13 and `sys.platform` for "darwin", honours
`stdlib/VERSIONS`, and writes one `.ktt` file (format: see the header comment
of Sources/KaruCore/Inference/TypeTableFile.swift and docs/ARCHITECTURE.md).

Usage: python3 -I scripts/m17/gen_python_types.py <typeshed>/stdlib <out.ktt>

Deterministic: sorted modules / names, no timestamps, no hash-order iteration.
Overloads are kept in source order, capped at OVERLOAD_CAP per function.
"""
from __future__ import annotations

import ast
import pathlib
import sys

sys.dont_write_bytecode = True   # keep scripts/m17/ free of __pycache__
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from ktt_writer import (  # noqa: E402
    KTTWriter, Blob, put_tparam, put_signature, put_class, P_POSITIONAL_ONLY, P_POSITIONAL, P_VAR_POSITIONAL, P_KEYWORD_ONLY,
    P_VAR_KEYWORD, P_HAS_DEFAULT, M_METHOD, M_CLASSMETHOD, M_STATICMETHOD, M_PROPERTY, M_FIELD,
    MF_READONLY, MF_CLASSVAR, MF_FINAL, MF_ABSTRACT, MF_DEPRECATED, MF_ASSIGNED,
)

TARGET_VERSION = (3, 13)
TARGET_PLATFORM = "darwin"
# Largest overload sets on the 3.13 / darwin code paths: builtins.pow (15),
# asyncio.gather (14), tarfile.TarFile.open (13). 24 keeps every set at the
# pinned commit except tkinter.Wm.wm_attributes (28 -> 24, its last 4 dropped;
# the `attributes` alias shares them). Drops are counted in the report line.
OVERLOAD_CAP = 24

# Class flags
CF_PROTOCOL = 1 << 0
CF_TYPEDDICT = 1 << 1
CF_NAMEDTUPLE = 1 << 2
CF_ENUM = 1 << 3
CF_FINAL = 1 << 4
CF_TYPE_CHECK_ONLY = 1 << 5
CF_DEPRECATED = 1 << 6
# Module flags
MOD_PACKAGE = 1 << 0
MOD_HAS_ALL = 1 << 1
# Import flags
IMP_REEXPORT = 1 << 0
# Variable flags
VF_FINAL = 1 << 0
# Type-parameter kinds (low 2 bits) and flags
TP_TYPEVAR, TP_PARAMSPEC, TP_TYPEVARTUPLE = 0, 1, 2
TP_CONSTRAINTS = 1 << 2   # `bound` holds the constraints as a union

ENUM_BASES = {"Enum", "IntEnum", "StrEnum", "Flag", "IntFlag", "ReprEnum", "enum.Enum",
              "enum.IntEnum", "enum.StrEnum", "enum.Flag", "enum.IntFlag"}
TYPEVAR_FACTORIES = {"TypeVar": TP_TYPEVAR, "ParamSpec": TP_PARAMSPEC, "TypeVarTuple": TP_TYPEVARTUPLE}

stats = {"overloads_dropped": 0, "functions_capped": 0}


# --- VERSIONS ---------------------------------------------------------------

def parse_versions(path: pathlib.Path) -> dict[str, tuple[tuple[int, int], tuple[int, int] | None]]:
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        name, rng = (s.strip() for s in line.split(":", 1))
        lo, hi = rng.split("-", 1)
        lo_t = tuple(int(x) for x in lo.split("."))
        hi_t = tuple(int(x) for x in hi.split(".")) if hi else None
        out[name] = (lo_t, hi_t)
    return out


def module_available(name: str, versions) -> bool:
    parts = name.split(".")
    for i in range(len(parts), 0, -1):
        key = ".".join(parts[:i])
        if key in versions:
            lo, hi = versions[key]
            return lo <= TARGET_VERSION and (hi is None or TARGET_VERSION <= hi)
    raise SystemExit(f"module {name} not listed in VERSIONS")


# --- condition evaluation ---------------------------------------------------

class UnknownCondition(Exception):
    pass


def _is_sys_attr(node, attr):
    return (isinstance(node, ast.Attribute) and node.attr == attr
            and isinstance(node.value, ast.Name) and node.value.id == "sys")


def eval_condition(node) -> bool:
    if isinstance(node, ast.BoolOp):
        vals = [eval_condition(v) for v in node.values]
        return all(vals) if isinstance(node.op, ast.And) else any(vals)
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
        return not eval_condition(node.operand)
    if isinstance(node, ast.Compare) and len(node.ops) == 1:
        left, op, right = node.left, node.ops[0], node.comparators[0]
        if _is_sys_attr(left, "version_info") and isinstance(right, ast.Tuple):
            value = tuple(e.value for e in right.elts)
            cur = TARGET_VERSION[:len(value)] if len(value) <= 2 else TARGET_VERSION + (0,) * (len(value) - 2)
            return _cmp(cur, op, value)
        if _is_sys_attr(left, "platform") and isinstance(right, ast.Constant):
            return _cmp(TARGET_PLATFORM, op, right.value)
    if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == "startswith" and _is_sys_attr(node.func.value, "platform")):
        return TARGET_PLATFORM.startswith(node.args[0].value)
    raise UnknownCondition(ast.unparse(node))


def _cmp(a, op, b):
    if isinstance(op, ast.GtE): return a >= b
    if isinstance(op, ast.Gt): return a > b
    if isinstance(op, ast.Lt): return a < b
    if isinstance(op, ast.LtE): return a <= b
    if isinstance(op, ast.Eq): return a == b
    if isinstance(op, ast.NotEq): return a != b
    raise UnknownCondition(ast.dump(op))


def flatten(body, where):
    """Statements of `body` with `if sys...` blocks resolved for the target."""
    out = []
    for stmt in body:
        if isinstance(stmt, ast.If):
            try:
                taken = stmt.body if eval_condition(stmt.test) else stmt.orelse
            except UnknownCondition as exc:
                raise SystemExit(f"{where}:{stmt.lineno}: unknown condition {exc}")
            out.extend(flatten(taken, where))
        else:
            out.append(stmt)
    return out


# --- type text --------------------------------------------------------------

class _Normalize(ast.NodeTransformer):
    """Forward-reference strings become expressions; Annotated[T, ...] -> T."""

    def visit_Subscript(self, node):
        base = ast.unparse(node.value)
        if base in ("Literal", "typing.Literal", "typing_extensions.Literal"):
            return node  # string literals stay literals
        if base in ("Annotated", "typing.Annotated", "typing_extensions.Annotated"):
            first = node.slice.elts[0] if isinstance(node.slice, ast.Tuple) else node.slice
            return self.visit(first)
        return self.generic_visit(node)

    def visit_Constant(self, node):
        if isinstance(node.value, str):
            return self.visit(ast.parse(node.value, mode="eval").body)
        return node


def type_text(node) -> str:
    if node is None:
        return ""
    return ast.unparse(_Normalize().visit(_copy(node)))


def _copy(node):
    return ast.parse(ast.unparse(node), mode="eval").body


def unwrap_qualifier(node):
    """ClassVar[T] / Final[T] -> (T, flags); bare ClassVar/Final -> (None, flags)."""
    flags = 0
    while True:
        if isinstance(node, ast.Subscript):
            base = ast.unparse(node.value).rsplit(".", 1)[-1]
            if base in ("ClassVar", "Final", "ReadOnly", "Required", "NotRequired"):
                flags |= MF_CLASSVAR if base == "ClassVar" else 0
                flags |= MF_FINAL if base == "Final" else 0
                flags |= MF_READONLY if base == "ReadOnly" else 0
                node = node.slice
                continue
        elif isinstance(node, (ast.Name, ast.Attribute)):
            base = ast.unparse(node).rsplit(".", 1)[-1]
            if base in ("ClassVar", "Final"):
                return None, flags | (MF_CLASSVAR if base == "ClassVar" else MF_FINAL)
        return node, flags


# --- per-module model ----------------------------------------------------------

def decorator_names(fn):
    names = []
    for d in fn.decorator_list:
        target = d.func if isinstance(d, ast.Call) else d
        names.append(ast.unparse(target))
    return names


def signature(fn) -> dict:
    a = fn.args
    params = []
    pos = a.posonlyargs + a.args
    defaults = [None] * (len(pos) - len(a.defaults)) + list(a.defaults)
    for i, arg in enumerate(pos):
        kind = P_POSITIONAL_ONLY if i < len(a.posonlyargs) else P_POSITIONAL
        params.append((arg.arg, kind | (P_HAS_DEFAULT if defaults[i] is not None else 0), type_text(arg.annotation)))
    if a.vararg:
        params.append((a.vararg.arg, P_VAR_POSITIONAL, type_text(a.vararg.annotation)))
    for arg, default in zip(a.kwonlyargs, a.kw_defaults):
        params.append((arg.arg, P_KEYWORD_ONLY | (P_HAS_DEFAULT if default is not None else 0), type_text(arg.annotation)))
    if a.kwarg:
        params.append((a.kwarg.arg, P_VAR_KEYWORD, type_text(a.kwarg.annotation)))
    tparams = [type_param_pep695(tp) for tp in getattr(fn, "type_params", [])]
    return {"tparams": tparams, "params": params, "returns": type_text(fn.returns),
            "async": isinstance(fn, ast.AsyncFunctionDef)}


def type_param_pep695(tp) -> tuple:
    kind = {ast.TypeVar: TP_TYPEVAR, ast.ParamSpec: TP_PARAMSPEC, ast.TypeVarTuple: TP_TYPEVARTUPLE}[type(tp)]
    bound = type_text(getattr(tp, "bound", None))
    if isinstance(getattr(tp, "bound", None), ast.Tuple):
        bound = " | ".join(type_text(e) for e in tp.bound.elts)
        kind |= TP_CONSTRAINTS
    return (tp.name, bound, type_text(getattr(tp, "default_value", None)), kind)


def typevar_decl(name, call) -> tuple | None:
    if not isinstance(call, ast.Call):
        return None
    factory = ast.unparse(call.func).rsplit(".", 1)[-1]
    if factory not in TYPEVAR_FACTORIES:
        return None
    kind = TYPEVAR_FACTORIES[factory]
    bound = ""
    default = ""
    constraints = [type_text(c) for c in call.args[1:]]
    for kw in call.keywords:
        if kw.arg == "bound":
            bound = type_text(kw.value)
        elif kw.arg == "default":
            default = type_text(kw.value)
    if constraints:
        bound = " | ".join(constraints)
        kind |= TP_CONSTRAINTS
    return (name, bound, default, kind)


class FunctionAcc:
    def __init__(self):
        self.overloads = []
        self.flags = 0
        self.overloaded = False
        self.capped = False

    def add(self, sig):
        if len(self.overloads) >= OVERLOAD_CAP:
            stats["overloads_dropped"] += 1
            if not self.capped:
                self.capped = True
                stats["functions_capped"] += 1
            return
        self.overloads.append(sig)


class ModuleModel:
    def __init__(self, name, is_package):
        self.name = name
        self.is_package = is_package
        self.all: list[str] | None = None
        self.imports: dict[str, tuple[str, str, int]] = {}   # local -> (module, original, flags)
        self.stars: list[str] = []
        self.typevars: dict[str, tuple] = {}
        self.aliases: dict[str, tuple] = {}                  # name -> (tparams, text)
        self.variables: dict[str, tuple[str, int]] = {}
        self.functions: dict[str, FunctionAcc] = {}
        self.classes: dict[str, dict] = {}


def resolve_relative(module: ModuleModel, level: int, target: str | None) -> str:
    if level == 0:
        return target or ""
    parts = module.name.split(".")
    base = parts if module.is_package else parts[:-1]
    if level > 1:
        base = base[: len(base) - (level - 1)]
    return ".".join(base + ([target] if target else []))


def build_module(name, path, is_package, all_modules) -> ModuleModel:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    m = ModuleModel(name, is_package)
    where = str(path)
    for stmt in flatten(tree.body, where):
        if isinstance(stmt, ast.Import):
            for alias in stmt.names:
                if alias.asname:
                    flags = IMP_REEXPORT if alias.asname == alias.name else 0
                    m.imports[alias.asname] = (alias.name, "", flags)
                else:
                    # `import a.b` binds `a`
                    top = alias.name.split(".")[0]
                    m.imports.setdefault(top, (top, "", 0))
        elif isinstance(stmt, ast.ImportFrom):
            src = resolve_relative(m, stmt.level, stmt.module)
            for alias in stmt.names:
                if alias.name == "*":
                    m.stars.append(src)
                    continue
                local = alias.asname or alias.name
                flags = IMP_REEXPORT if alias.asname == alias.name else 0
                sub = f"{src}.{alias.name}"
                if sub in all_modules:
                    m.imports[local] = (sub, "", flags)
                else:
                    m.imports[local] = (src, alias.name, flags)
        elif isinstance(stmt, ast.ClassDef):
            add_class(m, stmt, "", where)
        elif isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            decos = [d.rsplit(".", 1)[-1] for d in decorator_names(stmt)]
            acc = m.functions.get(stmt.name)
            if acc is None or not ("overload" in decos and acc.overloaded):
                acc = m.functions[stmt.name] = FunctionAcc()
            acc.overloaded = "overload" in decos
            if "deprecated" in decos:
                acc.flags |= MF_DEPRECATED
            acc.add(signature(stmt))
        elif isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
            target = stmt.target.id
            ann = ast.unparse(stmt.annotation)
            if ann.rsplit(".", 1)[-1] == "TypeAlias":
                m.aliases[target] = ([], type_text(stmt.value))
            elif target == "__all__":
                m.all = list_of_strings(stmt.value)
            else:
                inner, qual = unwrap_qualifier(stmt.annotation)
                m.variables[target] = (type_text(inner), VF_FINAL if qual & MF_FINAL else 0)
        elif isinstance(stmt, ast.TypeAlias):
            m.aliases[stmt.name.id] = ([type_param_pep695(tp) for tp in stmt.type_params], type_text(stmt.value))
        elif isinstance(stmt, ast.Assign):
            for t in stmt.targets:
                if isinstance(t, ast.Name):
                    module_assign(m, t.id, stmt.value)
        elif isinstance(stmt, ast.AugAssign) and isinstance(stmt.target, ast.Name) and stmt.target.id == "__all__":
            m.all = (m.all or []) + list_of_strings(stmt.value)
        elif isinstance(stmt, (ast.Expr, ast.Pass)):
            pass
        else:
            raise SystemExit(f"{where}:{stmt.lineno}: unhandled module statement {type(stmt).__name__}")
    return m


def list_of_strings(node) -> list[str]:
    if isinstance(node, (ast.List, ast.Tuple)):
        return [e.value for e in node.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)]
    return []


def module_assign(m: ModuleModel, name: str, value):
    if name == "__all__":
        m.all = list_of_strings(value)
        return
    tv = typevar_decl(name, value)
    if tv:
        m.typevars[name] = tv
        return
    if isinstance(value, ast.Name) and value.id in m.imports:
        mod, orig, _ = m.imports[value.id]
        m.imports[name] = (mod, orig, 0 if name.startswith("_") else IMP_REEXPORT)
        return
    if isinstance(value, (ast.Name, ast.Attribute, ast.Subscript)) or (
            isinstance(value, ast.BinOp) and isinstance(value.op, ast.BitOr)):
        # `Text = str`, `AnyStr_co = ...`: a type alias in stub semantics.
        m.aliases[name] = ([], type_text(value))
        return
    m.variables[name] = ("", 0)


def add_class(m: ModuleModel, node: ast.ClassDef, prefix: str, where: str):
    qual = prefix + node.name
    decos = decorator_names(node)
    flags = 0
    if any(d.endswith("final") for d in decos): flags |= CF_FINAL
    if any(d.endswith("type_check_only") for d in decos): flags |= CF_TYPE_CHECK_ONLY
    if any(d.endswith("deprecated") for d in decos): flags |= CF_DEPRECATED
    bases = []
    explicit_params = None
    for b in node.bases:
        text = type_text(b)
        bases.append(text)
        head = ast.unparse(b.value if isinstance(b, ast.Subscript) else b).rsplit(".", 1)[-1]
        if head == "Protocol": flags |= CF_PROTOCOL
        if head == "TypedDict": flags |= CF_TYPEDDICT
        if head == "NamedTuple": flags |= CF_NAMEDTUPLE
        if ast.unparse(b) in ENUM_BASES: flags |= CF_ENUM
        if head in ("Generic", "Protocol") and isinstance(b, ast.Subscript):
            sl = b.slice
            elts = sl.elts if isinstance(sl, ast.Tuple) else [sl]
            explicit_params = [ast.unparse(e.value if isinstance(e, ast.Starred) else e) for e in elts]
    members: dict[str, dict] = {}
    for stmt in flatten(node.body, where):
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            add_method(members, stmt)
        elif isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
            inner, qflags = unwrap_qualifier(stmt.annotation)
            members[stmt.target.id] = {"kind": M_FIELD, "flags": qflags, "type": type_text(inner), "overloads": []}
        elif isinstance(stmt, ast.Assign):
            for t in stmt.targets:
                if not isinstance(t, ast.Name):
                    continue
                v = stmt.value
                if isinstance(v, ast.Name) and v.id in members:
                    members[t.id] = dict(members[v.id])
                else:
                    members[t.id] = {"kind": M_FIELD, "flags": MF_ASSIGNED, "type": "", "overloads": []}
        elif isinstance(stmt, ast.ClassDef):
            add_class(m, stmt, qual + ".", where)
        elif isinstance(stmt, (ast.Expr, ast.Pass)):
            pass
        else:
            raise SystemExit(f"{where}:{stmt.lineno}: unhandled class statement {type(stmt).__name__}")
    m.classes[qual] = {"name": qual, "flags": flags, "bases": bases, "explicit_params": explicit_params,
                       "pep695": [type_param_pep695(tp) for tp in getattr(node, "type_params", [])],
                       "members": members, "base_nodes": node.bases}


def add_method(members, fn):
    decos = decorator_names(fn)
    short = [d.rsplit(".", 1)[-1] for d in decos]
    flags = 0
    if "abstractmethod" in short: flags |= MF_ABSTRACT
    if "final" in short: flags |= MF_FINAL
    if "deprecated" in short: flags |= MF_DEPRECATED
    if any(d.endswith(".setter") or d.endswith(".deleter") for d in decos):
        prop = members.get(fn.name)
        if prop and prop["kind"] == M_PROPERTY and any(d.endswith(".setter") for d in decos):
            prop["flags"] &= ~MF_READONLY
        return
    if "property" in short or "cached_property" in short:
        flags |= MF_READONLY if "property" in short else 0
        if "classmethod" in short: flags |= MF_CLASSVAR
        members[fn.name] = {"kind": M_PROPERTY, "flags": flags, "type": type_text(fn.returns), "overloads": []}
        return
    kind = M_CLASSMETHOD if "classmethod" in short else M_STATICMETHOD if "staticmethod" in short else M_METHOD
    overload = "overload" in short
    existing = members.get(fn.name)
    if existing is None or not (overload and existing.get("_overloaded")):
        existing = {"kind": kind, "flags": 0, "type": "", "overloads": [], "_acc": FunctionAcc()}
        members[fn.name] = existing
    existing["_overloaded"] = overload
    existing["flags"] |= flags
    existing["_acc"].add(signature(fn))
    existing["overloads"] = existing["_acc"].overloads


# --- type parameters of classes (need cross-module TypeVar knowledge) ----------

def collect_class_params(models: dict[str, ModuleModel]):
    def is_typevar(m: ModuleModel, name: str, depth=0):
        if name in m.typevars:
            return m.typevars[name]
        if name in m.imports and depth < 4:
            mod, orig, _ = m.imports[name]
            if orig and mod in models:
                return is_typevar(models[mod], orig, depth + 1)
        return None

    for m in models.values():
        for cls in m.classes.values():
            if cls["pep695"]:
                cls["tparams"] = cls["pep695"]
                continue
            if cls["explicit_params"] is not None:
                names = cls["explicit_params"]
            else:
                names = []
                for b in cls["base_nodes"]:
                    for n in ast.walk(b):
                        if isinstance(n, ast.Name) and is_typevar(m, n.id) and n.id not in names:
                            names.append(n.id)
            tparams = []
            for n in names:
                tv = is_typevar(m, n)
                tparams.append((n, tv[1], tv[2], tv[3]) if tv else (n, "", "", TP_TYPEVAR))
            cls["tparams"] = tparams


# --- encoding ---------------------------------------------------------------

def encode_module(section, m: ModuleModel) -> Blob:
    b = section.blob()
    flags = (MOD_PACKAGE if m.is_package else 0) | (MOD_HAS_ALL if m.all is not None else 0)
    b.v(flags)
    names = m.all or []
    b.v(len(names))
    for n in names:
        b.s(n)
    b.v(len(m.imports))
    for local in sorted(m.imports):
        mod, orig, fl = m.imports[local]
        b.s(local); b.s(mod); b.s(orig); b.v(fl)
    b.v(len(m.stars))
    for s in m.stars:
        b.s(s)
    b.v(len(m.typevars))
    for n in sorted(m.typevars):
        put_tparam(b, m.typevars[n])
    b.v(len(m.aliases))
    for n in sorted(m.aliases):
        tps, text = m.aliases[n]
        b.s(n); b.v(len(tps))
        for tp in tps:
            put_tparam(b, tp)
        b.s(text)
    b.v(len(m.variables))
    for n in sorted(m.variables):
        text, fl = m.variables[n]
        b.s(n); b.s(text); b.v(fl)
    b.v(len(m.functions))
    for n in sorted(m.functions):
        acc = m.functions[n]
        b.s(n); b.v(acc.flags); b.v(len(acc.overloads))
        for sig in acc.overloads:
            put_signature(b, sig)
    b.v(len(m.classes))
    for n in sorted(m.classes):
        put_class(b, m.classes[n])
    return b


def main():
    stdlib = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2])
    versions = parse_versions(stdlib / "VERSIONS")
    files = {}
    for p in sorted(stdlib.rglob("*.pyi")):
        rel = p.relative_to(stdlib)
        if rel.parts[0].startswith("@"):
            continue
        parts = list(rel.with_suffix("").parts)
        is_pkg = parts[-1] == "__init__"
        if is_pkg:
            parts = parts[:-1]
        name = ".".join(parts)
        if module_available(name, versions):
            files[name] = (p, is_pkg)
    all_modules = set(files)
    models = {name: build_module(name, p, pkg, all_modules) for name, (p, pkg) in sorted(files.items())}
    collect_class_params(models)
    # `from posixpath import __all__ as __all__` (os.path): copy the source's list.
    changed = True
    while changed:
        changed = False
        for m in models.values():
            imp = m.imports.get("__all__")
            if m.all is None and imp and imp[1] == "__all__" and imp[0] in models and models[imp[0]].all is not None:
                m.all = list(models[imp[0]].all)
                changed = True

    w = KTTWriter(language=1)
    section = w.section(1)
    n_classes = n_members = n_functions = n_vars = 0
    for name in sorted(models):
        m = models[name]
        section.add(name, encode_module(section, m))
        n_classes += len(m.classes)
        n_members += sum(len(c["members"]) for c in m.classes.values())
        n_functions += len(m.functions)
        n_vars += len(m.variables) + len(m.aliases)
    data = w.finish()
    out.write_bytes(data)
    print(f"python-stdlib.ktt: {len(data)} bytes; modules {len(models)}, classes {n_classes}, "
          f"members {n_members}, functions {n_functions}, variables+aliases {n_vars}, "
          f"strings {section.string_count()}; overload cap {OVERLOAD_CAP}: "
          f"{stats['functions_capped']} functions capped, {stats['overloads_dropped']} overloads dropped")


if __name__ == "__main__":
    main()
