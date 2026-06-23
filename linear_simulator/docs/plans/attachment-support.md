# Plan: Add attachment support to the Linear simulator

**Goal:** unblock the ENG-1 finalization loop. The coding agent finishes ENG-1's
work (commit + open PR) but cannot complete the Linear-side finalization, so the
issue never leaves `In Progress` and the orchestrator re-claims it every poll
(8 sessions on 2026-06-18). Adding attachment support lets the agent record the
PR on the issue and transition it to Human Review, breaking the loop.

**Posture:** deliberately over-provision. The agent discovers Linear ops via
introspection and the `linear` skill, and its exact choice of attachment mutation
is prompt-driven, not fixed by Symphony's adapter — so we implement the whole
*git/URL/manual* attachment surface (create, link, read-back, update, delete)
rather than only the single mutation we believe ENG-1 hit. Cost is low (one
persistence path, thin mutation aliases); the upside is we stop playing
whack-a-mole every time the prompt or skill prefers a different variant.

## Root cause

| Operation the agent needs | Simulator status | Verdict |
|---|---|---|
| Record the PR on the issue (`attachmentLinkGitHubPR` / `attachmentLinkURL`) | **missing** | **fix — blocker** |
| `Issue.attachments` field (read back existing links) | **missing** | **fix — blocker** |
| `attachmentCreate` / `attachmentUpdate` / `attachmentDelete` | missing | fix — cheap, same path |
| `workflowStates` root query | missing (agent recovers via `issue.team.states`) | optional polish |
| `mcp__plugin_linear_linear__save_issue` denied | correct sandbox behavior | out of scope |
| `jj` errors in a git workspace | env/prompt friction | out of scope |

State transition itself already works via `issueUpdate` (that's how ENG-2 reached
Done). Once attachments exist, the agent's finalize step succeeds and the loop ends.

> **Verify which mutation ENG-1 actually called before relying on a single fix.**
> The `linear` skill tells the agent to *prefer* `attachmentLinkGitHubPR` over
> `attachmentLinkURL` for PR links. The captured-operations dir
> (`priv/linear/operations/captured/`) does **not exist yet**, so there is no
> in-repo trace proving which one it hit — confirm from the live instance log /
> session transcript. Because we implement both (and `attachmentCreate`), the fix
> is robust regardless of which the agent leads with, but record the finding so
> Step 8's e2e proof targets the real path.

## Verified against live Linear (2026-06-18)

Probed the real Linear API (`api.linear.app/graphql`) with read-only introspection
plus a throwaway scratch issue (created, probed, deleted). Findings the sim must
match — **these override the earlier assumptions**:

1. **Shape is exact.** Live introspection of `Attachment` matches the committed
   `schema_reference` snapshot field-for-field (non-null `id/createdAt/updatedAt/
   title/url`; nullable `archivedAt/subtitle/source/sourceType`; `metadata: JSONObject!`).
2. **Duplicate-URL semantics differ by mutation — this is the key correction:**
   - `attachmentLinkURL` / `attachmentLinkGitHubPR` **error** on a duplicate
     `(issue, url)`: `code: "INPUT_ERROR"`, HTTP 400, `userPresentableMessage:
     "This URL has already been linked with <IDENTIFIER>."` They do **not** update
     the existing attachment.
   - `attachmentCreate` **upserts**: re-posting the same `(issue, url)` returns the
     **same attachment id** and **updates the title** — idempotent.
   - ⇒ The sim must reproduce *both*: link\* raises a user error on conflict;
     `attachmentCreate` upserts. Making link\* silently upsert would make the sim
     *easier* than prod and mask agent bugs (see retry note in Step 1b).
3. **`issueId` accepts the human identifier *or* the UUID.** `issueId: "IDE-229"`
   resolved fine — so the planned `get_issue_by_id_or_identifier/2` path **matches**
   real Linear; it is not a divergence.
4. **GitHub URLs get async-enriched in prod, and the sim will not replicate it.**
   Real Linear (with the GitHub integration connected) backfills `sourceType:
   "github"`, `source.pullRequestId`, a rich `metadata` blob (`status`, `mergedAt`,
   `branch`, `linkKind`, reviewers…) and **overrides the title from the live PR**;
   a plain link stays `sourceType: "unknown"` with the passed title. The sim has no
   GitHub integration, so it stores literal inputs only. Acceptable — the agent
   depends only on the link persisting + reading back url/title — but record it.
5. **`id` is a bare UUID in prod** (no prefix). The sim's `att_<uuid>` convention
   (matching its existing `label_…` house style) is a cosmetic divergence; the
   agent never parses the id, so either is fine — keep the sim convention for
   internal consistency.
6. `subtitle` defaults to `null`.

## Scope: what we add vs. defer

**Add now (the git/URL/manual surface — all share one persistence path):**

| Field | Kind | Why |
|---|---|---|
| `attachmentLinkURL(url!, issueId!, title, …)` | mutation | generic PR/URL link |
| `attachmentLinkGitHubPR(url!, issueId!, title, linkKind, …)` | mutation | skill's preferred PR link |
| `attachmentLinkGitHubIssue(url!, issueId!, title, …)` | mutation | same shape, free alias |
| `attachmentCreate(input: AttachmentCreateInput!)` | mutation | full manual create |
| `attachmentUpdate(id!, input: AttachmentUpdateInput!)` | mutation | title/subtitle edits + retry-safe |
| `attachmentDelete(id!)` | mutation | cleanup / dedup |
| `Issue.attachments(first, after, orderBy)` | field | read links back |
| `attachment(id!)` | root query | fetch one |
| `attachmentsForURL(url!, first, after)` | root query | dedup check by url |

`attachmentLinkURL` / `…GitHubPR` / `…GitHubIssue` are thin wrappers over the same
`Linear.create_attachment/1` upsert — they differ only in which scalar args they
accept, all normalizing to `{issue_id, url, title, source_type}`.

**Defer (record the decision; do not silently drop):** the third-party
integration links — `attachmentLinkGitLabMR`, `attachmentLinkSlack`,
`attachmentLinkDiscord`, `attachmentLinkFront` (returns `FrontAttachmentPayload`),
`attachmentLinkIntercom`, `attachmentLinkJiraIssue`, `attachmentLinkSalesforce`,
`attachmentLinkZendesk`, `attachmentSyncToSlack`, `attachmentSources`,
`attachmentIssue`, and `Project.attachments`/`ProjectAttachmentConnection`. These
need integration-specific args/types the agent will never exercise against the
sim. If one is ever needed, it's another thin alias on the same path.

## Reference shapes to match (real Linear, `priv/linear/schema_reference.graphql`)

```graphql
# Mutations (NOTE: link* take top-level scalar args, NOT an input object)
attachmentCreate(input: AttachmentCreateInput!): AttachmentPayload!
attachmentUpdate(input: AttachmentUpdateInput!, id: String!): AttachmentPayload!
attachmentLinkURL(createAsUser: String, displayIconUrl: String, title: String, url: String!, issueId: String!, id: String): AttachmentPayload!
attachmentLinkGitHubPR(createAsUser: String, displayIconUrl: String, title: String, issueId: String!, id: String, url: String!, linkKind: GitLinkKind): AttachmentPayload!
attachmentLinkGitHubIssue(createAsUser: String, displayIconUrl: String, title: String, issueId: String!, id: String, url: String!): AttachmentPayload!
attachmentDelete(id: String!): DeletePayload!

# Root queries
attachment(id: String!): Attachment!
attachmentsForURL(url: String!, first: Int, after: String, ...): AttachmentConnection!

type AttachmentPayload { success: Boolean!, attachment: Attachment! }   # attachment is NON-NULL

type Attachment {
  id: ID!
  createdAt: DateTime!
  updatedAt: DateTime!
  archivedAt: DateTime
  title: String!        # NON-NULL
  subtitle: String
  url: String!          # NON-NULL
  creator: User
  source: JSONObject
  sourceType: String
  metadata: JSONObject!
  issue: Issue!
}

input AttachmentCreateInput { id: String, title: String!, subtitle: String, url: String!, issueId: String!, iconUrl: String, metadata: JSONObject, createAsUser: String, displayIconUrl: String, ... }
input AttachmentUpdateInput { title: String!, subtitle: String, metadata: JSONObject, iconUrl: String }
enum GitLinkKind { closes contributes links }
```

> **Sim house-style divergence (intentional):** the sim's existing connections
> (`comments`, `labels`, `children`) are deliberate *subsets* of real Linear's
> Relay+filter surface — they expose `first/after`(+`orderBy` for comments), not
> `filter`/`includeArchived`/`last`/`before`. `Issue.attachments` and
> `attachmentsForURL` follow that same convention (mirror the `comments`
> connection), **not** the full reference signature. `metadata: JSONObject!` and
> `source: JSONObject` can resolve to `{}`/`nil` — keep the fields so introspection
> and broad selection sets don't error, but don't model integration metadata.

## Pre-flight note

The working tree has **uncommitted, unrelated changes** in `linear_simulator/` that
add **project** support (`project(id:)` query, `project.issues`, `issue.project`),
not attachments. Commit/stash those onto their own change first (recommended) so the
attachment PR stays narrowly scoped, then build attachments on top.

---

## Step 1 — RED: reproducing tests (write first, expect failure)

**1a. Context-level** — new `test/linear_sim/linear_attachment_test.exs`:
- `create_attachment/1` inserts an attachment bound to an issue (resolved by
  internal id **or** identifier), autogenerates an `att_<uuid>` id, returns
  `{:ok, attachment}` with `:issue` preloaded.
- **Two conflict behaviors (match prod — see verified §2):**
  - `link_url/1` (backs the link\* mutations): a second call with the same
    `(issue_id, url)` returns `{:error, :already_linked}` (or an equivalent the
    resolver maps to Linear's `"This URL has already been linked with <ID>."`);
    it does **not** mutate the existing row.
  - `create_attachment/1` (backs `attachmentCreate`): a second call with the same
    `(issue_id, url)` **upserts** — returns the existing row's id and updates the
    title. (`link_url` is a thin wrapper that calls a shared insert and surfaces
    the unique-constraint violation as an error rather than upserting.)
- `update_attachment/2` edits title/subtitle; `delete_attachment/1` removes it.

**1b. GraphQL behavior** — extend `test/linear_sim_web/graphql_behavior_test.exs`
with the agent's exact sequences (use the identifier `"ENG-1"` for `issueId`,
as the agent does — verified §3 that prod accepts the identifier too):
- **Preferred path:** `mutation { attachmentLinkGitHubPR(issueId:"ENG-1", url:"https://.../pull/82", title:"…", linkKind: links) { success attachment { id url title } } }` → `success: true`.
- **Generic path:** same via `attachmentLinkURL(issueId:"ENG-1", url:…, title:…)`.
- **Manual path:** `attachmentCreate(input:{ issueId:"ENG-1", url:…, title:… })`.
- **Read-back:** `query { issue(id:"ENG-1") { attachments { nodes { url title } } } }` returns it; root `attachment(id:…)` and `attachmentsForURL(url:…)` also return it.
- **Conflict (match prod):** re-running `attachmentLinkURL`/`…GitHubPR` with the
  same `(issueId,url)` returns a GraphQL **error** whose message matches Linear's
  `"This URL has already been linked with …"`; `attachments.nodes` length stays 1.
  Re-running `attachmentCreate` **succeeds**, returns the same attachment id, and
  the updated title is reflected — length still 1.
- **Update/delete:** `attachmentUpdate` changes the title; `attachmentDelete` drops it from `attachments.nodes`.

> **Agent-retry implication (record, don't fix here):** because link\* errors on a
> duplicate, an agent that re-links the same PR on a re-claim will get an error. By
> matching prod we faithfully reproduce that — but if ENG-1's loop turns out to be
> the agent treating "already linked" as fatal, the fix is in the skill/prompt
> (treat it as success-equivalent, or prefer `attachmentCreate`), not in the sim.

Run `mise exec -- mix test test/linear_sim/linear_attachment_test.exs test/linear_sim_web/graphql_behavior_test.exs`
→ **fails** (unknown field / unknown mutation). This is the documented RED.

## Step 2 — GREEN: persistence layer

- **Migration** `priv/repo/migrations/2026XXXXXXXXXX_create_attachments.exs`:
  `attachments` table, string PK, `issue_id references(:issues, on_delete: :delete_all) null: false`,
  `title null: false`, `url null: false`, `subtitle`, `source_type`,
  `creator_id references(:users, on_delete: :nilify_all)`, timestamps;
  `unique_index(:attachments, [:issue_id, :url])` for upsert idempotency.
- **Schema** `lib/linear_sim/linear/attachment.ex`: mirror `comment.ex`;
  `belongs_to :issue`, `belongs_to :creator, User`, changeset
  `validate_required([:id, :issue_id, :title, :url])`.
- **`lib/linear_sim/linear/issue.ex`**: add `has_many :attachments, LinearSim.Linear.Attachment`.
- **`lib/linear_sim/linear.ex`** (all resolve the issue via
  `get_issue_by_id_or_identifier/2`, so identifier *or* UUID works — verified §3):
  - `create_attachment/1`: **upsert** on `(issue_id, url)` (`on_conflict:
    {:replace, [:title, :subtitle, :updated_at]}, conflict_target: [:issue_id, :url]`)
    using an `att_<uuid>` id like the existing `"label_" <> …` pattern; returns
    `{:ok, attachment}` with `:issue` preloaded. Backs `attachmentCreate`.
  - `link_url/1`: thin wrapper that attempts a plain insert and maps the
    unique-constraint violation to `{:error, :already_linked}` (no upsert) — backs
    the link\* mutations, matching prod's "already been linked" error (verified §2).
  - `update_attachment/2`, `delete_attachment/1`.
  - `get_attachment/2`, `list_attachments_for_url/2` (root queries).
  - Add `:attachments` to `@issue_preloads` so `issue { attachments }` resolves.

Run **1a** → green.

## Step 3 — GREEN: GraphQL surface

- New `lib/linear_sim_web/graphql/types/attachment_types.ex`:
  - `object :attachment` with the full field set from the reference (id, title,
    subtitle, url, source, source_type, `metadata` → resolves `{}`, created_at,
    updated_at, archived_at, creator, issue). Title/url `non_null`.
  - `:attachment_edge`, `:attachment_connection` (mirror the comment connection).
  - `enum :git_link_kind` (`closes`/`contributes`/`links`).
  - `input_object :attachment_create_input`, `:attachment_update_input`.
  - `object :attachment_mutations`:
    - `attachment_link_url` (args `url!`, `issue_id!`, `title`, `create_as_user`, `display_icon_url`, `id`)
    - `attachment_link_github_pr` (above + `link_kind`)
    - `attachment_link_github_issue` (same as url)
    - `attachment_create` (input), `attachment_update` (id + input), `attachment_delete` (id → `DeletePayload`)
  - `object :attachment_queries`: `attachment(id!)`, `attachments_for_url(url!, first, after)`.
- `object :attachment_payload { success, non_null(:attachment) }` added to `common_types.ex`
  (reuse the existing `:delete_payload` for `attachment_delete`).
- `lib/linear_sim_web/graphql/types/issue_types.ex`: add `field :attachments,
  :attachment_connection` (args `first`, `after`, `order_by`) resolved by
  `&AttachmentResolver.attachments/3` (mirror the `comments` connection).
- New `lib/linear_sim_web/graphql/resolvers/attachment_resolver.ex`:
  - the three `link_*` resolvers normalize args and delegate to `Linear.link_url/1`,
    translating `{:error, :already_linked}` into a GraphQL error whose message
    mirrors prod (`"This URL has already been linked with <identifier>."`);
  - `create/3` delegates to `Linear.create_attachment/1` (upsert);
  - `update/3`, `delete/3`, `attachment/3`, `attachments_for_url/3`;
  - `attachments/3` → `Connection.from_nodes(issue.attachments, args)`.
  - Every public `def` gets an `@spec` (lint gate).
- `lib/linear_sim_web/graphql/schema.ex`: `import_types(…AttachmentTypes)` +
  `import_fields(:attachment_mutations)` in the `mutation` block and
  `import_fields(:attachment_queries)` in the `query` block.

Run **1b** → green.

## Step 4 — GREEN: regenerate schema snapshot

`mise exec -- mix linear_sim.dump_schema` to refresh `priv/linear_sim/schema.graphql`
+ `schema.json`, then confirm `test/mix/tasks/linear_sim.dump_schema_test.exs`
(snapshot-freshness check) passes. The new mutations/queries/types appear in the
sim's own schema; this does **not** need to match the full reference — the
compatibility tooling (Step 6) validates only curated ops, which still resolve.

## Step 5 — OPTIONAL: `workflowStates` root query

Add a root `workflowStates` query resolving via `Linear.list_workflow_states/1`
+ a behavior test. Removes the agent's wasted introspection turns; not required
(it already falls back to `issue.team.states`).

## Step 6 — OPTIONAL / decision: curated op + compatibility report

ENG-1's acceptance mentions "compatibility report shows no missing fields for
curated operations." Curated ops are Symphony-core operations, and PR-attachment
is currently an *agent-prompt* behavior, not something Symphony's adapter calls —
so adding `symphony_attach_pr` to `priv/linear/operations/curated/` may be out of
charter. Include it (and run `mix linear_sim.compatibility_report`) only if we
want the simulator to formally certify the attachment path.

## Step 7 — Quality gate + live verification

- `cd linear_simulator && make all` (fmt-check, lint, coverage, dialyzer).
- **Restart the running simulator** — the live process serves the old schema;
  restart it and `mix ecto.migrate` for the new table.
- Manual curl proof against the live endpoint: `attachmentLinkGitHubPR` (and
  `attachmentLinkURL`) on ENG-1 → `issueUpdate` to the Human Review state id →
  confirm ENG-1 reads back the attachment and the new state.

## Step 8 — End-to-end loop proof

Restart the `linear-sim` instance daemon, let it re-claim ENG-1 once, and confirm
it now reaches **Human Review** and **stops re-claiming** (no 9th session). That's
the real green for the original bug. Target whichever mutation the captured/live
trace showed the agent using (see the root-cause verify note).

## Docs

Update `linear_simulator/docs/linear-sim.md` operation inventory (§15) — list the
added attachment surface **and** the deliberately-deferred integration links (so
the gap is recorded, not silent). If attachment becomes a curated op, update the
compatibility section too. Docs change in the same PR.

---

## Open decisions

1. **Base state:** commit the existing project changes separately first
   (recommended), build on top, or stash.
2. **Scope:** as specified above (git/URL/manual surface + read/update/delete) /
   trim to URL+GitHubPR only / also add `workflowStates` / also add the curated op.
3. **Execution:** implement now (recommended — live loop burning a session per
   poll) / file as a Linear issue (dogfood) / plan only.
