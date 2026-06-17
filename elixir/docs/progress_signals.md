# Deterministic Per-Turn Progress Signals (IDE-211, Layer 1)

Layer 1 of the IDE-189 agent-run robustness defense. It sits beside the
deterministic-failure taxonomy ([token_exhaustion.md](token_exhaustion.md)) and
the Layer-0 non-destructive cutoff, and feeds the Layer-2 AI overseer.

`SymphonyElixir.ProgressSignal` is the pure decision core;
`SymphonyElixir.Git.working_tree_signals/4` is the cheap non-mutating probe; the
orchestrator owns the per-issue rolling state and runs the probe at each turn
boundary.

## What it computes

At each **turn boundary** — `:turn_completed` (claude) or a new-`session_id`
`:session_started` (codex) — the orchestrator runs one `sh` git probe and rolls
the signals forward. Raw inputs per turn:

| Input | How | Meaning |
| -- | -- | -- |
| `hash` | `git write-tree` on a throwaway index (captures tracked **and** untracked) | identical across turns ⇔ nothing changed |
| `empty` | `git status --porcelain` is empty | clean working tree |
| `commits_since` | `git rev-list --count <dispatch_head>..HEAD` | commits landed since dispatch |
| `error_sig` | adapter-tagged terminal-error code, or `nil` | a turn's terminal error |

Derived status (most→least severe) and an independent flag, with
`K = agent.progress_signal_window_k`:

```
:oscillating     last 4 hashes are A,B,A,B with A != B
:repeated_error  error_sig != nil AND its streak >= K
:stuck_state     identical hash for >= K turns AND the tree is empty
:progressing     otherwise

at_risk_no_commits = commits_since == 0 AND turn_count >= K
```

## The empty-tree guard (the IDE-189 lesson)

The motivating incident (IDE-189) ran 20 turns holding a *dirty* tree (one
pending `Containerfile` edit) and produced 0 commits. A naive
"identical-hash-for-K-turns ⇒ stuck" rule misclassifies that as stuck the moment
edits stop (e.g. a long build/validate phase). The fix: **`:stuck_state` only
fires on an empty (clean) working tree.** A dirty-but-identical tree is
`:progressing` carrying `at_risk_no_commits`.

So `at_risk_no_commits` is a *parallel boolean*, not a status — it coexists with
`:progressing`. The replay corpus is pinned as a regression test in
`test/symphony_elixir/progress_signal_test.exs` ("IDE-189 regression").

## Non-enforcement contract

Layer 1 **only reports**. It:

- logs each boundary (`Progress assessment status=… at_risk_no_commits=… …`),
  `info` when the status is non-`:progressing` or the flag flips true, `debug`
  otherwise (per [logging.md](logging.md): `issue_id` + `issue_identifier` +
  `session_id`, `key=value`, deterministic wording, no payloads);
- exposes the assessment through the orchestrator snapshot, so the LiveView
  dashboard and `/api/v1/*` carry `progress.status` / `progress.at_risk_no_commits`.

It never kills a session, moves a Linear state, or gates continuation — those are
Layers 0/2. The predicate Layer 2 consumes is `ProgressSignal.trigger?/2`:

```
status in [:stuck_state, :oscillating, :repeated_error]
OR (at_risk_no_commits AND turn_count >= agent.progress_trigger_min_turns)
```

## Config knobs (`agent.*`)

These are global `agent.*` (not per-adapter) because the signals live in the
adapter-agnostic orchestrator path, so codex and claude are covered by
construction.

| Key | Default | Notes |
| -- | -- | -- |
| `progress_signal_enabled` | `true` | master switch for the probe + assessment |
| `progress_signal_window_k` | `4` | window `K`; validated `>= 2`. Tuned from the IDE-189 replay: fires by turn 4 of a 20-turn budget (early enough to warn, late enough to avoid noise on a normal 2–3 turn issue) and never trips `:stuck_state` on IDE-189's dirty tree |
| `progress_signal_git_timeout_ms` | `2000` | per-turn probe timeout; a slow/locked repo degrades to "unknown" (assessment unchanged) |
| `progress_trigger_min_turns` | `4` | turn floor for the `at_risk_no_commits` arm of `trigger?/2`; validated `>= 1` |

## Known limitations

- **Lazy dispatch marker.** `dispatch_head` is captured on the first probe (first
  turn boundary), because `workspace_path` is unknown at spawn. Commits landed
  during turn 1 are therefore not counted. Acceptable for Layer 1.
- **Error signatures are usually `nil`.** Terminal errors abort the run and
  surface via the agent DOWN reason rather than as a per-turn worker update, so
  `:repeated_error` rarely fires from the live boundary path. The classifier
  handles it (and is unit-tested), and the claude path captures an `error_code`
  defensively if a future envelope ever carries one at the boundary.
- **Wandering is Layer-2 territory.** A *different* valid-looking change each turn
  that never converges yields a fresh hash + dirty tree, so Layer 1 reports
  `:progressing` (+ `at_risk_no_commits` once commits stay 0). Layer 1 cannot and
  must not judge semantic convergence; `trigger?/2` hands that case to Layer 2.
