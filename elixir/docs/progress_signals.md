# Progress signals (Layer 1, IDE-189)

Layer 1 computes **cheap, deterministic per-turn progress signals** so the
orchestrator can tell — without an expensive AI judgement — whether a running
issue is actually making progress. It sits beside the non-destructive cutoff
(`SymphonyElixir.Git.preserve_uncommitted_work/4`) and the deterministic-failure
taxonomy (`token_exhaustion.md`): those mechanisms *act*; Layer 1 only *reports*.

See `SPEC.md` §19 for the normative contract. This doc covers the operator-facing
knobs and the rationale behind the defaults.

## What is computed, and when

Once per **turn boundary** per running issue (claude `turn_completed`, codex
new-session `session_started` — the existing `turn_count` increment), the
orchestrator runs one read-only git probe
(`SymphonyElixir.Git.working_tree_probe/4`) that yields, in a single `sh`
invocation off the agent's critical path:

- a **working-tree fingerprint** `sha256(git status --porcelain ++ git diff)` and
  an **empty-tree** bit, and
- **commits since dispatch** on `dispatch_head..HEAD`.

`SymphonyElixir.ProgressSignal` rolls these into per-issue streaks and classifies
them into one **status** and one independent **flag**:

| status (most → least severe) | meaning |
| -- | -- |
| `:oscillating` | last 4 fingerprints are `A,B,A,B` — flip-flopping between two states |
| `:repeated_error` | same terminal error signature `>= K` turns |
| `:stuck_state` | identical fingerprint `>= K` turns **and the tree is empty** |
| `:progressing` | none of the above |

`at_risk_no_commits` is a **separate boolean** (`commits_since == 0 AND
turn_count >= K`), not a status — it coexists with `:progressing`.

### Why the empty-tree guard matters

The IDE-189 replay surfaced the load-bearing design point: a first-cut classifier
that treated "identical fingerprint for K turns" as stuck **misclassified a real
in-progress issue** once its builds stopped editing files. IDE-189's working tree
was *dirty* (a pending `Containerfile` change) the whole time, so identical-dirty
is `:progressing` + `at_risk_no_commits`, never `:stuck`. Only an *empty* tree
repeated K turns means the agent genuinely did nothing.

## The Layer-2 trigger

`ProgressSignal.trigger?/2` returns the single boolean Layer 2 (the AI overseer)
consumes:

```
status in [:stuck_state, :oscillating, :repeated_error]
  OR (at_risk_no_commits AND turn_count >= agent.progress_trigger_min_turns)
```

For the IDE-189 incident this is `true` from turn 4 via the `at_risk_no_commits`
arm while the status stays `:progressing` — the desired early warning. **Layer 1
takes no action on it**: no session kill, no Linear state move, no continuation
gating. The full assessment is also exposed verbatim through `Orchestrator.snapshot/0`
(and so the dashboard / `/api/v1/*`) and a deterministic per-turn log line.

## Config knobs (`agent.*`, global — both adapters)

| knob | default | meaning |
| -- | -- | -- |
| `progress_signal_enabled` | `true` | master switch for computing the signals |
| `progress_signal_window_k` | `4` | consecutive-turn window `K` (min `2`); drives the `:stuck_state`/`:repeated_error` streaks and the `at_risk_no_commits` turn gate |
| `progress_signal_git_timeout_ms` | `2000` | timeout for the read-only probe; on expiry the prior assessment is kept rather than stalling the loop |
| `progress_trigger_min_turns` | `4` | turn gate for the trigger's `at_risk_no_commits` arm |

`K = 4` is tuned from the IDE-189 replay: it fires `at_risk_no_commits` by turn 4
(one fifth of the default 20-turn budget — early enough to warn, late enough to
avoid noise on a normal 2–3 turn issue) and requires 4 consecutive *empty*-tree
turns before `:stuck_state`, which never trips on a dirty tree.

## Known gaps (Layer-2 territory)

- **Wandering.** A *different* valid-looking change each turn that never converges
  produces a fresh fingerprint and a dirty tree every turn, so Layer 1 reports
  `:progressing` (+ `at_risk_no_commits` once commits stay 0). Judging semantic
  convergence is Layer 2's job; the trigger predicate hands this case off.
- **Untracked-file content.** The fingerprint hashes `git diff` (tracked changes)
  and `git status --porcelain` (which names untracked files but not their
  content), so distinct edits to an *untracked* file look identical. This matches
  the chosen tree-hash method and IDE-189's modified-tracked-file case.
- **Per-turn error signatures.** Terminal error envelopes do not currently reach
  the orchestrator as turn-boundary worker updates, so `error_sig` is `nil` on
  normal turns and `:repeated_error` does not fire from that path today. The
  streak mechanism and status remain in place for when error events do feed it.
