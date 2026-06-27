---
name: linear
description: |
  Use Symphony's `linear_graphql` client tool for raw Linear GraphQL
  operations such as comment editing and upload flows. Use the companion
  `sync_workpad` tool for workpad comment syncs so the multi-KB body stays
  out of the conversation context.
---

# Linear GraphQL

Use this skill for raw Linear GraphQL work during Symphony app-server sessions.

## Primary tool

Use the `linear_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured Linear auth for the session. Do **not** use
`mcp__plugin_linear_linear__*` or any other "Linear MCP" plugin tools — they are
denied in Symphony sessions; `linear_graphql` is the only supported raw Linear
path.

For the persistent `## Symphony Workpad` comment specifically, prefer the
`sync_workpad` companion tool described in
[Workpad syncs via `sync_workpad`](#workpad-syncs-via-sync_workpad). It funnels
through `linear_graphql` under the hood, so all the recipes below still apply
to every other Linear operation.

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

Tool behavior:

- Send one GraphQL operation per tool call.
- Treat a top-level `errors` array as a failed GraphQL operation even if the
  tool call itself completed.
- Keep queries/mutations narrowly scoped; ask only for the fields you need.

## Discovering unfamiliar operations

When you need an unfamiliar mutation, input type, or object field, use targeted
introspection through `linear_graphql`.

List mutation names:

```graphql
query ListMutations {
  __type(name: "Mutation") {
    fields {
      name
    }
  }
}
```

Inspect a specific input object:

```graphql
query CommentCreateInputShape {
  __type(name: "CommentCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
}
```

## Common workflows

### Query an issue by key, identifier, or id

Use these progressively:

- Start with `issue(id: $key)` when you have a ticket key such as `MT-686`.
- Fall back to `issues(filter: ...)` when you need identifier search semantics.
- Once you have the internal issue id, prefer `issue(id: $id)` for narrower reads.

Lookup by issue key:

```graphql
query IssueByKey($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    branchName
    url
    description
    updatedAt
    links {
      nodes {
        id
        url
        title
      }
    }
  }
}
```

Lookup by identifier filter:

```graphql
query IssueByIdentifier($identifier: String!) {
  issues(filter: { identifier: { eq: $identifier } }, first: 1) {
    nodes {
      id
      identifier
      title
      state {
        id
        name
        type
      }
      project {
        id
        name
      }
      branchName
      url
      description
      updatedAt
    }
  }
}
```

Resolve a key to an internal id:

```graphql
query IssueByIdOrKey($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Read the issue once the internal id is known:

```graphql
query IssueDetails($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
    url
    description
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    attachments {
      nodes {
        id
        title
        url
        sourceType
      }
    }
  }
}
```

### Query team workflow states for an issue

Use this before changing issue state when you need the exact `stateId`:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    id
    team {
      id
      key
      name
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

### Edit an existing comment

Use `commentUpdate` through `linear_graphql`:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment {
      id
      body
    }
  }
}
```

### Create a comment

Use `commentCreate` through `linear_graphql`:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment {
      id
      url
    }
  }
}
```

### Move an issue to a different state

Use `issueUpdate` with the destination `stateId`:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue {
      id
      identifier
      state {
        id
        name
      }
    }
  }
}
```

### Attach a GitHub PR to an issue

Use the GitHub-specific attachment mutation when linking a PR:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(
    issueId: $issueId
    url: $url
    title: $title
    linkKind: links
  ) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

If you only need a plain URL attachment and do not care about GitHub-specific
link metadata, use:

```graphql
mutation AttachURL($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

> **Do not wrap these arguments in an input object.** `attachmentLinkURL` and
> `attachmentLinkGitHubPR` take their arguments as top-level scalars
> (`$issueId: String!`, `$url: String!`, `$title: String`) exactly as shown
> above. There is **no** `AttachmentLinkURLInput` / `AttachmentLinkGitHubPRInput`
> type — passing `input: { ... }` (or declaring `$input: AttachmentLinkURLInput!`)
> fails with `Unknown type "AttachmentLinkURLInput"`. The `input: { ... }` shape
> applies only to `attachmentCreate`/`attachmentUpdate`, not to these
> link-helper mutations.

### Introspection patterns used during schema discovery

Use these when the exact field or mutation shape is unclear:

```graphql
query QueryFields {
  __type(name: "Query") {
    fields {
      name
    }
  }
}
```

```graphql
query IssueFieldArgs {
  __type(name: "Query") {
    fields {
      name
      args {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
  }
}
```

### Upload a video to a comment

Do this in three steps:

1. Call `linear_graphql` with `fileUpload` to get `uploadUrl`, `assetUrl`, and
   any required upload headers.
2. Upload the local file bytes to `uploadUrl` with `curl -X PUT` and the exact
   headers returned by `fileUpload`.
3. Call `linear_graphql` again with `commentCreate` (or `commentUpdate`) and
   include the resulting `assetUrl` in the comment body.

Useful mutations:

```graphql
mutation FileUpload(
  $filename: String!
  $contentType: String!
  $size: Int!
  $makePublic: Boolean
) {
  fileUpload(
    filename: $filename
    contentType: $contentType
    size: $size
    makePublic: $makePublic
  ) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers {
        key
        value
      }
    }
  }
}
```

## Workpad syncs via `sync_workpad`

`sync_workpad` is the second client-side tool Symphony exposes. It exists to
keep the `## Symphony Workpad` comment body out of the conversation context:
the agent edits a local `workpad.md` for free, and the tool reads the body on
the Elixir side (via `File.read/1`) before forwarding `commentCreate` /
`commentUpdate` through the same `linear_graphql` transport (so telemetry and
`symphony_hint` enrichment still apply).

Tool input:

```json
{
  "issue_id": "ENG-42",
  "file_path": "/abs/path/to/workpad.md",
  "comment_id": "optional-existing-comment-id"
}
```

Lifecycle:

- **First sync** — omit `comment_id`. The tool calls `commentCreate` and the
  response includes `commentCreate.comment.id`. Persist that id locally (e.g.
  alongside the `workpad.md`) — you will need it for every later sync.
- **Later syncs** — pass the persisted `comment_id`. The tool calls
  `commentUpdate` against that comment so a single workpad is reused instead of
  spawning duplicates.

Rules:

- `file_path` **must be absolute**. The tool reads the file in the daemon
  process whose cwd is the instance dir (not your workspace), so a relative
  path will resolve against the wrong root.
- The local file must be non-empty; empty files are rejected before any Linear
  call is made.
- Keep `## Symphony Workpad` as the very first heading of `workpad.md`. The
  in-process `Workpad.find/1` resolver (used by deterministic-failure and
  overseer flows) looks for that exact marker text.
- Use `linear_graphql` directly for everything else (issue lookups, state
  moves, attachments, ad-hoc reads/writes) — `sync_workpad` only handles the
  one workpad comment.
- This is **enforced**, not just advised: a raw `linear_graphql`
  `commentCreate` / `commentUpdate` whose body carries the `## Symphony Workpad`
  marker is rejected with an error pointing back here. Always sync the workpad
  through `sync_workpad`. (If `sync_workpad` isn't listed, run `ToolSearch` with
  `select:mcp__symphony_workpad__sync_workpad` first.)

## Usage rules

- Use `linear_graphql` for comment edits, uploads, and ad-hoc Linear API
  queries.
- Prefer the narrowest issue lookup that matches what you already know:
  key -> identifier search -> internal id.
- For state transitions, fetch team states first and use the exact `stateId`
  instead of hardcoding names inside mutations.
- Prefer `attachmentLinkGitHubPR` over a generic URL attachment when linking a
  GitHub PR to a Linear issue.
- Do not introduce new raw-token shell helpers for GraphQL access.
- If you need shell work for uploads, only use it for signed upload URLs
  returned by `fileUpload`; those URLs already carry the needed authorization.
