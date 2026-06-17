#!/usr/bin/env python3
"""Scan Claude Agent SDK session transcripts and quantify rate-limit waste per issue.

Provenance artifact for docs/claude-token-spend-fix-plan.md. Reproduces the
per-issue rate-limit shares (e.g. IDE-163 ~80%) and the 290/1,114-session figure
that motivate the P0-first ordering.

The transcripts live on the orchestrator host (see the
[[symphony-orchestrator-deployment]] note), so the default base path points
there. Run either locally (if transcripts are synced) or piped over SSH:

    python3 scripts/scan_token_waste.py [BASE_DIR] > token_waste.csv
    ssh slimshady.tonka.se 'python3 -' < scripts/scan_token_waste.py > token_waste.csv

Output: CSV to stdout — one row per issue plus a TOTAL row. Columns:
    issue, sessions, ratelimit_sessions, assistant_turns,
    ratelimit_turns, ratelimit_share, turns_in_rl_sessions, rl_session_share

Classification (matches the manual grep in the fix plan):
    - an "assistant turn" is a transcript record with type == "assistant"
    - a "rate-limit turn" is one with top-level error == "rate_limit" OR
      isApiErrorMessage == true (the "You've hit your limit · resets …" record)
    - a "rate-limit session" is any session file containing >= 1 rate-limit turn

Two waste measures are reported, because they differ by ~2x and the gap is
methodological, not a bug:
    - ratelimit_share  = ratelimit_turns / assistant_turns
      (mechanical floor: only the literal limit-hit records)
    - rl_session_share = turns_in_rl_sessions / assistant_turns
      (session-level attribution: every turn in a session that got rate-limited
      is counted as wasted, since that session accomplished nothing — this is the
      basis of the operator table's higher per-issue percentages)
"""

from __future__ import annotations

import csv
import glob
import json
import os
import re
import sys

DEFAULT_BASE = os.path.expanduser(
    "~/.jai/default.changes/.claude-identione/projects"
)

# Per-issue dir naming: -home-...-workspaces-<instance>-<TICKET>
_TICKET_RE = re.compile(r"-([A-Z]{2,}-\d+)$")


def ticket_of(dirname: str) -> str | None:
    m = _TICKET_RE.search(dirname)
    return m.group(1) if m else None


def scan_session(path: str) -> tuple[int, int]:
    """Return (assistant_turns, ratelimit_turns) for one .jsonl transcript."""
    asst = rl = 0
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except (ValueError, json.JSONDecodeError):
                    continue
                if rec.get("type") != "assistant":
                    continue
                asst += 1
                if rec.get("error") == "rate_limit" or rec.get("isApiErrorMessage"):
                    rl += 1
    except OSError:
        pass
    return asst, rl


def main(argv: list[str]) -> int:
    base = argv[1] if len(argv) > 1 else DEFAULT_BASE
    issue_dirs: dict[str, list[str]] = {}
    for d in sorted(glob.glob(os.path.join(base, "*"))):
        if not os.path.isdir(d):
            continue
        ticket = ticket_of(os.path.basename(d))
        if ticket:
            issue_dirs.setdefault(ticket, []).extend(
                sorted(glob.glob(os.path.join(d, "*.jsonl")))
            )

    writer = csv.writer(sys.stdout)
    writer.writerow(
        ["issue", "sessions", "ratelimit_sessions", "assistant_turns",
         "ratelimit_turns", "ratelimit_share", "turns_in_rl_sessions", "rl_session_share"]
    )

    tot_sessions = tot_rl_sessions = tot_asst = tot_rl = tot_rl_sess_turns = 0
    rows = []
    for ticket, files in issue_dirs.items():
        s_asst = s_rl = rl_sessions = rl_sess_turns = 0
        for f in files:
            a, r = scan_session(f)
            s_asst += a
            s_rl += r
            if r:
                rl_sessions += 1
                rl_sess_turns += a  # whole session attributed as wasted
        share = round(s_rl / s_asst, 3) if s_asst else 0.0
        sess_share = round(rl_sess_turns / s_asst, 3) if s_asst else 0.0
        rows.append((ticket, len(files), rl_sessions, s_asst, s_rl, share,
                     rl_sess_turns, sess_share))
        tot_sessions += len(files)
        tot_rl_sessions += rl_sessions
        tot_asst += s_asst
        tot_rl += s_rl
        tot_rl_sess_turns += rl_sess_turns

    # Largest session-level waste first.
    rows.sort(key=lambda r: r[6], reverse=True)
    for row in rows:
        writer.writerow(row)

    tot_share = round(tot_rl / tot_asst, 3) if tot_asst else 0.0
    tot_sess_share = round(tot_rl_sess_turns / tot_asst, 3) if tot_asst else 0.0
    writer.writerow(
        ["TOTAL", tot_sessions, tot_rl_sessions, tot_asst, tot_rl, tot_share,
         tot_rl_sess_turns, tot_sess_share]
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
