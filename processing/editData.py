#!/usr/bin/env python3
"""Visual editor for chomp's game data: mon stats, move rows, and CPU teams.

Serves a local page with three tabs:
  Mons      — drool/mons.csv, with live stat rankings, defensive typing and threat/KO tables
  Moves     — drool/moves.csv, badged by whether the row drives the deployed move or mirrors a .sol
  CPU teams — script/cpu-teams.json

Saving writes the file and reruns the generators it feeds, so the deploy scripts and munch's
generated data stay in step. Contract-backed move rows are reported rather than auto-patched:
their .sol is the deployed artifact, so syncing it is an explicit `validateMoves.py` run.

Usage:
    python processing/editData.py [--port 8777] [--no-open]
"""

import argparse
import contextlib
import csv
import io
import json
import re
import subprocess
import sys
import webbrowser
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from typing import Any

# Add processing directory to path for local imports
sys.path.insert(0, str(Path(__file__).parent))

from csvTable import Table
from generateSetupCPU import load_cpu_teams, run as run_setup_cpu
from generateSolidity import contract_name_from_move_or_ability, get_mon_directory_name, run as run_solidity


EDITOR_HTML = Path(__file__).parent / "dataEditor.html"
STAT_FIELDS = ("HP", "Attack", "Defense", "SpecialAttack", "SpecialDefense", "Speed")
MOVE_NUMERIC_FIELDS = ("Power", "Stamina", "Accuracy", "Priority", "UnlockLevel")


def chomp_dir() -> Path:
    return Path(__file__).parent.parent


def load_team_size(base: Path) -> int:
    """GAME_MONS_PER_TEAM from Constants.sol — the per-seat roster length the Engine enforces."""
    match = re.search(r"GAME_MONS_PER_TEAM\s*=\s*(\d+)", (base / "src" / "Constants.sol").read_text())
    if not match:
        raise RuntimeError("GAME_MONS_PER_TEAM not found in src/Constants.sol")
    return int(match.group(1))


def move_source(base: Path, mon: str, move: str) -> tuple[str, str]:
    """Classify a move row by what the CSV actually drives, and name the file it pairs with.

    inline   — no .sol; the row is packed straight into the move word, so the CSV is authoritative
    contract — mirrored in a .sol that has to be re-synced when the row changes
    complex  — power is '?', computed by the engine at runtime; the CSV can't drive it
    """
    contract = contract_name_from_move_or_ability(move)
    mon_dir = base / "src" / "mons" / get_mon_directory_name(mon)
    if (mon_dir / f"{contract}.json").exists():
        return "inline", f"{contract}.json"
    if (mon_dir / f"{contract}.sol").exists():
        return "contract", f"{contract}.sol"
    return "missing", f"{contract}.sol"


def load_state(base: Path) -> dict[str, Any]:
    mons_table = Table(base / "drool" / "mons.csv")
    moves_table = Table(base / "drool" / "moves.csv")

    mons = []
    for row in mons_table.rows:
        mons.append({
            "id": int(row["Id"]),
            "name": row["Name"],
            "t1": row["Type1"],
            "t2": "" if row["Type2"] in ("NA", "") else row["Type2"],
            "sprite": f"/drool/imgs/{row['Name'].lower()}_mini.gif",
            "stats": {f: int(row[f]) for f in STAT_FIELDS},
            "flavor": row["Flavor"],
        })

    moves = []
    for index, row in enumerate(moves_table.rows):
        source, filename = move_source(base, row["Mon"].strip(), row["Name"].strip())
        if source == "contract" and row["Power"].strip() == "?":
            source = "complex"
        moves.append({
            "index": index,
            "src": source,
            "file": filename,
            "sprite": f"/drool/imgs/{row['Mon'].strip().lower()}_mini.gif",
            **{field: row[field] for field in moves_table.fields},
        })

    types = {}
    with open(base / "drool" / "type-metadata.csv", newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            types[row["Type"]] = {"bg": row["BgColor"], "fg": row["TextColor"], "ab": row["Abbreviation"]}

    # Attacker -> defender -> raw code (0 immune, 1 neutral, 2 super, 5 half), as types.csv stores it.
    chart: dict[str, dict[str, int]] = {}
    with open(base / "drool" / "types.csv", newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            attacker = (row["Attacker"] or "").strip()
            defender = (row["Defender"] or "").strip()
            if attacker and defender:
                chart.setdefault(attacker, {})[defender] = int(row["Multiplier"])

    cpu = load_cpu_teams(base / "script" / "cpu-teams.json")
    return {
        "mons": mons,
        "moves": moves,
        "moveFields": moves_table.fields,
        "types": types,
        "chart": chart,
        "cpuTeams": cpu["teams"],
        "cpuPlayers": cpu["cpuPlayers"],
        "teamSize": load_team_size(base),
    }


def render_cpu_json(payload: dict[str, Any]) -> str:
    """One team per line, matching the hand-authored layout so diffs stay readable."""
    players = ", ".join(json.dumps(p) for p in payload["cpuPlayers"])
    teams = ",\n".join("    [" + ", ".join(str(int(m)) for m in team) + "]" for team in payload["teams"])
    return f'{{\n  "cpuPlayers": [{players}],\n  "teams": [\n{teams}\n  ]\n}}\n'


def regenerate_deploy_scripts(base: Path) -> list[str]:
    """Mon stats and inline move words are baked into script/mons/*.s.sol, so re-emit them."""
    log = io.StringIO()
    with contextlib.redirect_stdout(log):
        ok = run_solidity(base_path=str(base))
    lines = [line for line in log.getvalue().splitlines() if line.startswith(("Generated", "Removed"))]
    if not ok:
        lines.append("generateSolidity FAILED — see the server log")
        print(log.getvalue(), end="")
    return lines


def validate_moves_report(base: Path) -> list[str]:
    """Run validateMoves read-only ('n' declines its contract-patching prompt) and summarise."""
    result = subprocess.run(
        [sys.executable, "processing/validateMoves.py"],
        cwd=base, input="n\n", capture_output=True, text=True,
    )
    output = result.stdout + result.stderr
    if "All move validations passed" in output:
        return ["validateMoves: all rows match their contracts"]

    mismatches = [line.strip().lstrip("• ") for line in output.splitlines() if "mismatch" in line.lower()]
    summary = [f"validateMoves: {len(mismatches)} mismatch(es) against the .sol contracts"]
    summary += [f"  • {m}" for m in mismatches[:12]]
    if len(mismatches) > 12:
        summary.append(f"  … and {len(mismatches) - 12} more")
    summary.append("Run `python processing/validateMoves.py` and answer y to patch the contracts.")
    return summary


class EditorHandler(SimpleHTTPRequestHandler):
    """Editor routes over a static file server rooted at chomp/ (for drool/imgs sprites)."""

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(EDITOR_HTML.read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/api/state":
            self._send_json(load_state(chomp_dir()))
        else:
            super().do_GET()

    def do_POST(self):
        base = chomp_dir()
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except json.JSONDecodeError as e:
            self._send_json({"ok": False, "errors": [f"Malformed request: {e}"]}, status=400)
            return

        handlers = {
            "/api/save/mons": self._save_mons,
            "/api/save/moves": self._save_moves,
            "/api/save/cpu-teams": self._save_cpu_teams,
        }
        handler = handlers.get(self.path)
        if handler is None:
            self.send_error(404)
            return

        try:
            errors, log = handler(base, payload)
        except Exception as e:  # a bad payload shouldn't take the server down mid-session
            self._send_json({"ok": False, "errors": [f"{type(e).__name__}: {e}"]}, status=400)
            return

        self._send_json({"ok": not errors, "errors": errors, "log": log},
                        status=400 if errors else 200)

    def _save_mons(self, base: Path, payload: dict[str, Any]) -> tuple[list[str], list[str]]:
        table = Table(base / "drool" / "mons.csv")
        by_id = {int(row["Id"]): row for row in table.rows}
        errors = []
        for entry in payload.get("mons", []):
            row = by_id.get(int(entry["id"]))
            if row is None:
                errors.append(f"Unknown mon id {entry['id']}")
                continue
            for field, value in entry.get("stats", {}).items():
                if field not in STAT_FIELDS:
                    errors.append(f"{row['Name']}: {field} is not an editable stat")
                    continue
                if not (isinstance(value, int) and value > 0):
                    errors.append(f"{row['Name']}: {field} must be a positive integer, got {value!r}")
                    continue
                row[field] = str(value)
        if errors:
            return errors, []

        table.write()
        return [], ["Wrote drool/mons.csv"] + regenerate_deploy_scripts(base)

    def _save_moves(self, base: Path, payload: dict[str, Any]) -> tuple[list[str], list[str]]:
        table = Table(base / "drool" / "moves.csv")
        errors = []
        for entry in payload.get("moves", []):
            index = int(entry["index"])
            if not 0 <= index < len(table.rows):
                errors.append(f"Move row {index} is out of range")
                continue
            row = table.rows[index]
            for field, value in entry.get("cells", {}).items():
                if field not in table.fields:
                    errors.append(f"{row['Name']}: {field} is not a moves.csv column")
                    continue
                value = str(value)
                if field in MOVE_NUMERIC_FIELDS and value != "?" and not re.fullmatch(r"-?\d+", value):
                    errors.append(f"{row['Name']}: {field} must be a number (or '?'), got {value!r}")
                    continue
                row[field] = value
        if errors:
            return errors, []

        table.write()
        log = ["Wrote drool/moves.csv"] + regenerate_deploy_scripts(base)
        return [], log + validate_moves_report(base)

    def _save_cpu_teams(self, base: Path, payload: dict[str, Any]) -> tuple[list[str], list[str]]:
        team_size = load_team_size(base)
        mon_ids = {int(row["Id"]) for row in Table(base / "drool" / "mons.csv").rows}
        errors = []

        players = payload.get("cpuPlayers")
        if not isinstance(players, list) or not players or not all(isinstance(p, str) and p for p in players):
            errors.append("cpuPlayers must be a non-empty list of env var names.")

        teams = payload.get("teams")
        if not isinstance(teams, list) or not teams:
            return errors + ["Need at least one team."], []

        for index, team in enumerate(teams):
            label = f"Team {index + 1}"
            if not isinstance(team, list) or not all(isinstance(m, int) for m in team):
                errors.append(f"{label} is not a list of mon ids.")
                continue
            if len(team) != team_size:
                errors.append(f"{label} has {len(team)} mons; the Engine requires exactly {team_size}.")
            unknown = sorted(set(team) - mon_ids)
            if unknown:
                errors.append(f"{label} references unknown mon id(s) {unknown}.")
        if errors:
            return errors, []

        (base / "script" / "cpu-teams.json").write_text(render_cpu_json(payload), encoding="utf-8")
        log = io.StringIO()
        with contextlib.redirect_stdout(log):
            synced = run_setup_cpu()
        print(log.getvalue(), end="")
        if not synced:
            return ["generateSetupCPU failed; see the server log."], []
        return [], ["Wrote script/cpu-teams.json"] + log.getvalue().strip().splitlines()

    def log_message(self, fmt, *args):
        # Static sprite fetches are noise; only report the API calls.
        if self.path.startswith("/api/"):
            super().log_message(fmt, *args)

    def _send(self, body: bytes, content_type: str, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, payload: dict[str, Any], status: int = 200):
        self._send(json.dumps(payload).encode("utf-8"), "application/json", status)


def main():
    parser = argparse.ArgumentParser(description="Visual editor for chomp's mon, move and CPU-team data")
    parser.add_argument("--port", type=int, default=8777, help="Port to serve on (default: 8777)")
    parser.add_argument("--no-open", action="store_true", help="Do not open a browser window")
    args = parser.parse_args()

    url = f"http://127.0.0.1:{args.port}"
    server = HTTPServer(("127.0.0.1", args.port), partial(EditorHandler, directory=str(chomp_dir())))

    print(f"chomp data editor: {url}")
    print("Saving rewrites the CSV / JSON and reruns the generators it feeds. Ctrl-C to stop.")
    if not args.no_open:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
