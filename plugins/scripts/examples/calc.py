#!/usr/bin/env python3
# =============================================================================
# calc.py — Mediabot v3 reference plugin script (mediabot-script-v1), in Python.
#
# A safe arithmetic calculator routed as "pcalc": Mediabot already ships an
# internal "calc" command, and the script reads its command name from the
# envelope, so the usage line always shows the real routed name.
#
#   pcalc 2 + 2 * 3        -> 8
#   pcalc (10 - 4) / 2     -> 3
#   pcalc 2 ** 10          -> 1024
#
# WHY THIS EXAMPLE MATTERS — safe evaluation of untrusted input.
# A naive plugin would call eval() on the user expression, which is a remote
# code-execution hole (e.g. !calc __import__("os").system("rm -rf ~")).
# This script instead PARSES the expression into an AST and walks it, allowing
# ONLY numeric literals and arithmetic operators. Names, calls, attributes,
# comprehensions, etc. are rejected. It also caps exponents and result size so a
# tiny input like 9**9**9 cannot become a CPU/memory denial-of-service.
#
# Dependency-free (standard library only). Deterministic shape -> validatable
# offline with tools/mb_plugin_dev.pl.
# =============================================================================

import ast
import json
import math
import sys

MAX_EXPR_LEN = 200      # reject absurdly long expressions outright
MAX_EXPONENT = 1000     # reject huge powers before computing them
MAX_RESULT_BITS = 1024  # reject results that grow too large


class CalcError(Exception):
    """Raised for any rejected or invalid expression."""


# Allowed binary / unary operators mapped to safe implementations.
_BIN_OPS = {
    ast.Add: lambda a, b: a + b,
    ast.Sub: lambda a, b: a - b,
    ast.Mult: lambda a, b: a * b,
    ast.Div: lambda a, b: a / b,
    ast.FloorDiv: lambda a, b: a // b,
    ast.Mod: lambda a, b: a % b,
    ast.Pow: None,  # handled specially (DoS guard)
}
_UNARY_OPS = {
    ast.UAdd: lambda a: +a,
    ast.USub: lambda a: -a,
}


def _check_size(value):
    # bool is an int subclass; arithmetic should not produce it, but reject to be safe
    if isinstance(value, bool):
        raise CalcError("invalid value")
    if isinstance(value, int):
        if value.bit_length() > MAX_RESULT_BITS:
            raise CalcError("number too large")
        return value
    if isinstance(value, float):
        if math.isnan(value) or math.isinf(value):
            raise CalcError("number too large")
        return value
    # e.g. complex, from a fractional power of a negative number like (-1) ** 0.5
    raise CalcError("unsupported result")


def _eval(node):
    if isinstance(node, ast.Expression):
        return _eval(node.body)

    # numeric literals only
    if isinstance(node, ast.Constant):
        if isinstance(node.value, bool) or not isinstance(node.value, (int, float)):
            raise CalcError("only numbers are allowed")
        # MB299: validate literals too. Python parses values such as 1e309 as
        # float('inf'); letting that reach formatting would expose a non-finite
        # result instead of returning a clean calculator error.
        return _check_size(node.value)

    if isinstance(node, ast.UnaryOp):
        op = _UNARY_OPS.get(type(node.op))
        if op is None:
            raise CalcError("unsupported unary operator")
        return _check_size(op(_eval(node.operand)))

    if isinstance(node, ast.BinOp):
        op_type = type(node.op)
        if op_type not in _BIN_OPS:
            raise CalcError("unsupported operator")
        left = _eval(node.left)
        right = _eval(node.right)

        if op_type is ast.Pow:
            # guard BEFORE computing: 9**9**9 must never be evaluated
            if isinstance(right, float) and not right.is_integer():
                pass  # fractional powers are fine (roots), they don't explode
            elif abs(right) > MAX_EXPONENT:
                raise CalcError("exponent too large")
            try:
                return _check_size(left ** right)
            except ZeroDivisionError:
                raise CalcError("division by zero")
            except (OverflowError, ValueError):
                raise CalcError("number too large")

        try:
            return _check_size(_BIN_OPS[op_type](left, right))
        except ZeroDivisionError:
            raise CalcError("division by zero")

    raise CalcError("unsupported expression")


def safe_calc(expression):
    expression = expression.strip()
    if not expression:
        raise CalcError("empty expression")
    if len(expression) > MAX_EXPR_LEN:
        raise CalcError("expression too long")
    try:
        tree = ast.parse(expression, mode="eval")
    except SyntaxError:
        raise CalcError("invalid expression")
    return _eval(tree)


def _format(value):
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    if isinstance(value, float):
        value = round(value, 10)
    return value


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}

    data = payload.get("data")
    if not isinstance(data, dict):
        data = {}

    command = data.get("command")
    if not isinstance(command, str) or not command:
        command = "calc"

    nick = data.get("nick")
    if not isinstance(nick, str) or not nick:
        nick = "someone"

    args = data.get("args")
    expr = " ".join(a for a in args if isinstance(a, str)) if isinstance(args, list) else ""

    try:
        result = safe_calc(expr)
        text = f"{nick}: {expr.strip()} = {_format(result)}"
        actions = [
            {"type": "reply", "text": text},
            {"type": "log", "level": "info", "text": f"calc: {nick} evaluated an expression"},
        ]
    except CalcError as err:
        text = f"{nick}: {err}. usage: {command} 2 + 2 * 3"
        actions = [{"type": "reply", "text": text}]

    print(json.dumps({
        "protocol": "mediabot-script-v1",
        "ok": True,
        "actions": actions,
    }))


if __name__ == "__main__":
    main()
