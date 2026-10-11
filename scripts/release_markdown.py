"""Read file destinations in release Markdown without a Markdown dependency.

Inline links/images and reference definitions share the same destination rules.
Code fences, indented/inline code and comments are not navigable links.
"""
from __future__ import annotations

import posixpath
import re
from typing import NamedTuple
from urllib.parse import unquote, urlsplit


class MarkdownTarget(NamedTuple):
    start: int
    end: int
    value: str


class FileTarget(NamedTuple):
    path: str
    suffix: str


def _visible_markdown(text: str) -> str:
    visible = list(text)

    def hide(start: int, end: int) -> None:
        visible[start:end] = ["\n" if character == "\n" else " " for character in text[start:end]]

    fence = None
    indented = False
    previous_blank = True
    offset = 0
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)", line)
        if fence is not None:
            hide(offset, offset + len(line))
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= fence[1] and not marker[2].strip():
                fence = None
        elif marker and (marker[1][0] != "`" or "`" not in marker[2]):
            fence = (marker[1][0], len(marker[1]))
            hide(offset, offset + len(line))
        elif re.match(r"^(?: {4}| {0,3}\t)", line) and (indented or previous_blank):
            indented = True
            hide(offset, offset + len(line))
        elif line.strip():
            indented = False
        previous_blank = not line.strip()
        offset += len(line)

    for comment in re.finditer(r"<!--.*?(?:-->|\Z)", "".join(visible), re.DOTALL):
        hide(comment.start(), comment.end())

    current = "".join(visible)
    cursor = 0
    while cursor < len(current):
        if current[cursor] == "\\":
            cursor += 2
            continue
        if current[cursor] != "`":
            cursor += 1
            continue
        end = cursor
        while end < len(current) and current[end] == "`":
            end += 1
        closing = re.search(r"(?<!`)" + re.escape(current[cursor:end]) + r"(?!`)", current[end:])
        if closing:
            finish = end + closing.end()
            hide(cursor, finish)
            cursor = finish
        else:
            cursor = end
    return "".join(visible)


def _destination(text: str, cursor: int) -> MarkdownTarget:
    while cursor < len(text) and text[cursor].isspace():
        cursor += 1
    if cursor < len(text) and text[cursor] == "<":
        start = cursor + 1
        cursor = start
        while cursor < len(text):
            if text[cursor] == "\\":
                cursor += 2
            elif text[cursor] == ">":
                return MarkdownTarget(start, cursor, text[start:cursor])
            elif text[cursor] in "\n<":
                break
            else:
                cursor += 1
        raise ValueError("unterminated angle-bracket Markdown destination")
    start = cursor
    depth = 0
    while cursor < len(text):
        character = text[cursor]
        if character == "\\":
            cursor += 2
            continue
        if character.isspace() or (character == ")" and depth == 0):
            break
        if character in "<>":
            raise ValueError("invalid angle bracket in Markdown destination")
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        cursor += 1
    if depth:
        raise ValueError("unbalanced parentheses in Markdown destination")
    return MarkdownTarget(start, cursor, text[start:cursor])


def markdown_targets(text: str) -> list[MarkdownTarget]:
    visible = _visible_markdown(text)
    targets = []
    for definition in re.finditer(r"^ {0,3}\[(?:\\.|[^\]\\\n])+\]:[ \t]*(?:\n[ \t]*)?", visible, re.MULTILINE):
        target = _destination(visible, definition.end())
        if not target.value:
            raise ValueError("empty Markdown reference destination")
        targets.append(target)

    brackets = []
    cursor = 0
    while cursor < len(visible):
        character = visible[cursor]
        if character == "\\":
            cursor += 2
            continue
        if character == "[":
            brackets.append(cursor)
        elif character == "]" and brackets:
            brackets.pop()
            if cursor + 1 < len(visible) and visible[cursor + 1] == "(":
                target = _destination(visible, cursor + 2)
                end = target.end + (1 if visible[target.start - 1:target.start] == "<" else 0)
                while end < len(visible) and visible[end].isspace():
                    end += 1
                if end < len(visible) and visible[end] in "\"'(":
                    quote = ")" if visible[end] == "(" else visible[end]
                    end += 1
                    while end < len(visible) and visible[end] != quote:
                        end += 2 if visible[end] == "\\" else 1
                    end += 1
                    while end < len(visible) and visible[end].isspace():
                        end += 1
                if end >= len(visible) or visible[end] != ")":
                    raise ValueError("unterminated Markdown link or invalid link title")
                targets.append(target)
                cursor = end
        cursor += 1
    return sorted(targets)


def file_target(document: str, target: str) -> FileTarget | None:
    """Normalize decoded path boundaries before checking repository membership."""
    target = re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])", r"\1", target)
    try:
        parsed = urlsplit(target)
    except ValueError as exc:
        raise ValueError(f"invalid Markdown target {target!r}: {exc}") from exc
    if parsed.scheme or parsed.netloc or target.startswith("//") or not parsed.path:
        return None
    if re.search(r"%(?![0-9a-fA-F]{2})", parsed.path):
        raise ValueError(f"invalid percent encoding in Markdown target {target!r}")
    path = unquote(parsed.path, encoding="utf-8", errors="strict")
    if path.startswith("/") or "\\" in path or any(ord(character) < 32 for character in path):
        raise ValueError(f"unsafe relative Markdown target {target!r}")
    normalized = posixpath.normpath(posixpath.join(posixpath.dirname(document), path))
    if normalized == ".." or normalized.startswith("../"):
        raise ValueError(f"Markdown target escapes release root: {target!r}")
    # Preserve authored queries and fragments byte for byte.
    return FileTarget(normalized, target[len(parsed.path):])
