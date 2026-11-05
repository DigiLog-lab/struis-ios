#!/usr/bin/env python3
"""Validate learner-visible reply text before sending it.

This is a narrow foreground helper. It checks the draft's visible LaTeX spans
for common broken commands and delimiter/braces mistakes, then exits non-zero
when the draft should be rewritten as simpler valid LaTeX or plain text.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ALLOWED_COMMANDS = {
    "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "theta",
    "lambda", "mu", "pi", "rho", "sigma", "phi", "varphi", "omega",
    "Gamma", "Delta", "Theta", "Lambda", "Pi", "Sigma", "Phi", "Omega",
    "vec", "overrightarrow", "hat", "bar", "overline", "underline",
    "frac", "sqrt", "left", "right", "begin", "end", "text", "mathrm",
    "mathit", "mathbf", "mathbb", "operatorname", "displaystyle",
    "partial", "nabla", "int", "sum", "prod", "lim", "sin", "cos",
    "tan", "log", "ln", "exp", "det", "rank", "dim",
    "le", "leq", "ge", "geq", "ne", "neq", "approx", "equiv", "sim",
    "to", "rightarrow", "leftarrow", "Rightarrow", "Leftrightarrow",
    "in", "notin", "subset", "subseteq", "cup", "cap", "varnothing",
    "times", "div", "pm", "mp", "cdot", "infty",
    "quad", "qquad", ",", ";", ":", "!", " ", "{", "}", "[", "]",
    "(", ")", "|",
}

COMMON_BROKEN_COMMANDS = {
    "cd": "Use \\cdot, or write the dot/product in plain text.",
    "dx": "Use \\,dx, or write dx as plain text inside the formula.",
    "dy": "Use \\,dy, or write dy as plain text inside the formula.",
    "dz": "Use \\,dz, or write dz as plain text inside the formula.",
    "lex": "Use \\le x with a space, or write <= x in plain text.",
}


def _is_escaped(text: str, index: int) -> bool:
    slashes = 0
    i = index - 1
    while i >= 0 and text[i] == "\\":
        slashes += 1
        i -= 1
    return slashes % 2 == 1


def _find_unescaped(text: str, needle: str, start: int) -> int:
    index = text.find(needle, start)
    while index >= 0:
        if not _is_escaped(text, index):
            return index
        index = text.find(needle, index + len(needle))
    return -1


def _extract_math_spans(text: str) -> tuple[list[tuple[str, int]], list[str]]:
    spans: list[tuple[str, int]] = []
    errors: list[str] = []
    i = 0
    while i < len(text):
        if text.startswith("$$", i):
            end = _find_unescaped(text, "$$", i + 2)
            if end < 0:
                errors.append("Unclosed $$ display math delimiter.")
                break
            spans.append((text[i + 2 : end], i))
            i = end + 2
            continue
        if text.startswith("\\[", i):
            end = _find_unescaped(text, "\\]", i + 2)
            if end < 0:
                errors.append("Unclosed \\[ display math delimiter.")
                break
            spans.append((text[i + 2 : end], i))
            i = end + 2
            continue
        if text.startswith("\\(", i):
            end = _find_unescaped(text, "\\)", i + 2)
            if end < 0:
                errors.append("Unclosed \\( inline math delimiter.")
                break
            spans.append((text[i + 2 : end], i))
            i = end + 2
            continue
        if text[i] == "$" and not _is_escaped(text, i):
            end = _find_unescaped(text, "$", i + 1)
            if end < 0:
                errors.append("Unclosed $ inline math delimiter.")
                break
            spans.append((text[i + 1 : end], i))
            i = end + 1
            continue
        i += 1
    return spans, errors


def _strip_escaped_braces(span: str) -> str:
    return span.replace(r"\{", "").replace(r"\}", "")


def _validate_span(span: str, offset: int) -> list[str]:
    errors: list[str] = []
    if not span.strip():
        errors.append(f"Empty math span near character {offset}.")
        return errors
    brace_text = _strip_escaped_braces(span)
    if brace_text.count("{") != brace_text.count("}"):
        errors.append(f"Unbalanced braces near character {offset}.")
    if span.count(r"\left") != span.count(r"\right"):
        errors.append(f"Unbalanced \\left / \\right near character {offset}.")
    for match in re.finditer(r"\\([A-Za-z]+|.)", span):
        command = match.group(1)
        if command in COMMON_BROKEN_COMMANDS:
            errors.append(
                f"Broken LaTeX command \\{command} near character {offset + match.start()}: "
                f"{COMMON_BROKEN_COMMANDS[command]}"
            )
            continue
        if command not in ALLOWED_COMMANDS:
            errors.append(
                f"Unknown or unsafe LaTeX command \\{command} near character {offset + match.start()}."
            )
    if re.search(r"\\[+\-*/=<>]", span):
        errors.append(f"Escaped arithmetic/comparison operator near character {offset}.")
    return errors


def lint_reply(text: str) -> list[str]:
    spans, errors = _extract_math_spans(text)
    for span, offset in spans:
        errors.extend(_validate_span(span, offset))
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="struis_reply_lint.py")
    parser.add_argument("--stdin", action="store_true", help="read draft reply from stdin")
    parser.add_argument("path", nargs="?", help="optional draft reply file")
    args = parser.parse_args(argv)
    if args.stdin:
        text = sys.stdin.read()
    elif args.path:
        text = Path(args.path).read_text(encoding="utf-8")
    else:
        parser.error("provide --stdin or a draft file path")
    errors = lint_reply(text)
    if errors:
        print("FAIL", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
