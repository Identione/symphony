# Captured prompt bodies

Point-in-time copies of instance `WORKFLOW.md` files that exist nowhere else in
version control.

`instances/` is gitignored (`.gitignore:8`) because instance files are
per-operator: front matter carries host paths, ports, and the chosen `command:`
form. That is the right default, but it means a hand-tuned *prompt body* living
in an instance file has no backup — the only copy is on the host that runs it.

Files here are byte-exact captures, front matter included (it is useful
provenance: which host, which base branch, which adapter). They are reference
artifacts, not inputs — nothing reads them at build or run time.

| file | source | fetched | body |
|---|---|---|---|
| `slimshady.entry-elixir-v1-app-v2.WORKFLOW.md` | `slimshady.tonka.se:~/stash.tail-f.com/identione/symphony/instances/entry-elixir-v1-app-v2/WORKFLOW.md` | 2026-08-28 | 1390 words, condensed, `agent.kind: claude`, no `agent.kind` guards |

## About the slimshady capture

This is the tuned condensed prompt, kept for promotion to the canonical
template body. Two things to know before using it:

- **It is not the local namesake.** `instances/entry-elixir-v1-app-v2/WORKFLOW.md`
  on the maintainer's machine is a *different* variant — a 3100-word
  template-derived body — despite the identical instance name.
- **Its lineage is unrecorded.** At 1390 words it matches neither the 651-word
  "minimal" nor the 788-word "vnext" variant from the prompt-length experiment,
  so it is presumably a later hand-edit. Treat its measured performance as
  unknown until re-run.

Promoting it to the template is not a copy: the base branch is baked into the
body in four places (`origin/entry-elixir-v1-app-v2`, plus a dedicated
issue-branch section that only exists because `repo.base_branch` is set), and it
carries no `{%- if agent.kind == "claude" %}` guards, which `core_test.exs`
requires the canonical body to have.
