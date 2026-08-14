#!/usr/bin/env python3
"""Fidelity-preserving CSV read/write for the drool data files.

csv.DictWriter re-quotes by minimal rules, which strips the quotes drool/*.csv puts around
every description and flavour field — rewriting all 66 move rows on any save. This keeps each
cell's original quoting, so an untouched row round-trips byte-identically and a diff shows only
the cells that actually changed.
"""

from pathlib import Path


def split_csv_line(line: str) -> tuple[list[str], list[bool]]:
    """Split one CSV line into values plus whether each value was quoted in the source."""
    values: list[str] = []
    quoted: list[bool] = []
    i, n = 0, len(line)
    while True:
        if i < n and line[i] == '"':
            i += 1
            buf: list[str] = []
            while i < n:
                if line[i] == '"':
                    if i + 1 < n and line[i + 1] == '"':
                        buf.append('"')
                        i += 2
                        continue
                    i += 1
                    break
                buf.append(line[i])
                i += 1
            values.append("".join(buf))
            quoted.append(True)
        else:
            j = line.find(",", i)
            if j == -1:
                j = n
            values.append(line[i:j])
            quoted.append(False)
            i = j
        if i < n and line[i] == ",":
            i += 1
            if i == n:  # trailing comma closes one more empty field
                values.append("")
                quoted.append(False)
                break
        else:
            break
    return values, quoted


def join_csv_line(values: list[str], quoted: list[bool]) -> str:
    """Re-emit a row, keeping each cell's original quoting and adding it where now required."""
    out = []
    for value, was_quoted in zip(values, quoted):
        needs_quotes = was_quoted or any(c in value for c in ',"\n')
        out.append('"' + value.replace('"', '""') + '"' if needs_quotes else value)
    return ",".join(out)


class Table:
    """A CSV file as ordered dict rows, remembering per-cell quoting for a clean rewrite."""

    def __init__(self, path: Path | str):
        self.path = Path(path)
        raw = self.path.read_text(encoding="utf-8")
        self.trailing_newline = raw.endswith("\n")
        lines = raw.split("\n")
        if self.trailing_newline:
            lines = lines[:-1]
        if not lines:
            raise ValueError(f"{self.path} is empty")

        self.header = lines[0]
        self.fields = split_csv_line(self.header)[0]
        self.rows: list[dict[str, str]] = []
        self.quoted: list[list[bool]] = []
        for number, line in enumerate(lines[1:], start=2):
            if not line.strip():
                raise ValueError(f"{self.path}:{number} is blank; this reader expects one row per line")
            values, quoted = split_csv_line(line)
            pad = len(self.fields) - len(values)
            values += [""] * pad
            quoted += [False] * pad
            self.rows.append(dict(zip(self.fields, values)))
            self.quoted.append(quoted)

    def render(self) -> str:
        out = [self.header]
        for row, quoted in zip(self.rows, self.quoted):
            out.append(join_csv_line([row[f] for f in self.fields], quoted))
        return "\n".join(out) + ("\n" if self.trailing_newline else "")

    def write(self) -> None:
        self.path.write_text(self.render(), encoding="utf-8")
