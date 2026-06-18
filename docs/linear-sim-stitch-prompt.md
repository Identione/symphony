# Google Stitch prompts — Linear Simulator control UI

The simulator UI is a **multi-page** app: one shared shell (sidebar + top bar + footer) with
six views. Stitch generates **one screen per prompt**, so each section below is a complete,
standalone "new screen" prompt. Paste the **SHARED DESIGN SYSTEM** block (identical, verbatim)
at the top of every screen so they stay visually consistent, then paste the page-specific body.

All content is grounded in the real simulator: a Linear GraphQL API mock (Elixir/Phoenix/
Absinthe + SQLite). Control happens via REST admin endpoints; data is Linear-compatible GraphQL.

---

## SHARED DESIGN SYSTEM (paste at the top of every page prompt)

```
**DESIGN SYSTEM (REQUIRED):**
- Platform: Web, Desktop-first
- Theme: Dark, sophisticated, minimal, data-dense
- Background: Near-Black Charcoal (#08090A)
- Surface/Card: Graphite (#16171B) with 1px hairline borders in Faint Border (#23252A)
- Primary Accent: Linear Indigo (#5E6AD2) for primary buttons, active nav, links, focus rings
- Text Primary: Soft White (#F7F8F8)
- Text Secondary: Muted Slate (#8A8F98) for labels, metadata, timestamps
- Status colors (pills/badges): Healthy Green (#4CB782), Warning Amber (#F2C94C), Error Red (#EB5757), Neutral Gray (#62666D), Active Indigo (#5E6AD2)
- Buttons: rounded 6px, primary = solid indigo, secondary = transparent with hairline border
- Cards: rounded 8px, flat with 1px hairline border, subtle shadow on hover only
- Typography: Inter-style sans for UI chrome; monospace (JetBrains Mono) for IDs, tokens, GraphQL, JSON, log output
- Pills/badges: small rounded-full, uppercase 11px

**SHARED SHELL (must appear on every page, identical):**
- Left sidebar (240px, fixed): logo block "Linear Simulator / Local Instance"; vertical nav rows with icon + label — Overview, Scenarios, Entities, Captured Operations, Webhooks, Settings (highlight THIS page's row with indigo text + left accent bar); bottom shows a "GraphQL: /graphql" copy button and Docs / Health links.
- Top bar (48px): "Linear Simulator" wordmark; live status pills — active scenario (e.g. BASIC_WORKSPACE), response mode (green NORMAL or red RATE_LIMITED / INVALID_TOKEN / PERMISSION_DENIED), and a green health dot "API :4000"; right side — "Reset to default" secondary button and a "Capture ops" toggle switch.
- Footer (thin, muted): left "v1.x • linear_sim_dev.db • CONNECTED"; right links Docs / Health / /admin/state.
```

---

## Page 1 — Overview (landing dashboard)

> A glanceable status dashboard for the Linear Simulator — live counts and current state. Mark the **Overview** sidebar row active.
>
> *(paste SHARED DESIGN SYSTEM + SHARED SHELL here)*
>
> **Page Structure:**
> 1. **Section header:** "Overview" with a green "SIMULATOR ONLINE" status pill on the right.
> 2. **Stat cards (row of 8):** compact cards, each a big monospace number + small uppercase label — Orgs, Users, Teams, Projects, Issues, Comments, States, Deliveries. Use the default `basic_workspace` values: Orgs 1, Users 1, Teams 1, Projects 1, Issues 1, Comments 1, States 8, Deliveries 0.
> 3. **Current State card (left half):** key/value rows — Active Scenario (indigo pill `BASIC_WORKSPACE`), Response Mode (`NORMAL`), Last loaded (timestamp).
> 4. **Recent Activity card (right half):** compact vertical list with monospace timestamps — e.g. "POST /graphql IssuesQuery", "POST /graphql ViewerQuery", "Scenario loaded basic_workspace", each with a small status dot.

---

## Page 2 — Scenarios (control panel)

> A control panel to switch the simulator's data scenario and force error response modes. Mark the **Scenarios** sidebar row active.
>
> *(paste SHARED DESIGN SYSTEM + SHARED SHELL here)*
>
> **Page Structure:**
> 1. **Section header:** "Scenario Control Panel".
> 2. **Response Mode Override:** a segmented control with four options — NORMAL (active), RATE LIMITED, INVALID TOKEN, PERMISSION DENIED — with a one-line note: "Forces every GraphQL request to return that error in the response body (HTTP 200)."
> 3. **Scenario card grid (all 8 cards):** each card shows the scenario name (monospace), a one-line description, a small badge (DATA or ERROR), and a "Load" button; the active card is outlined in indigo with an ACTIVE pill and a disabled "LOADED" button. The cards:
>    - `basic_workspace` — DATA — "One org, one team, one project, one Todo issue (ENG-1). The default." (ACTIVE)
>    - `empty_workspace` — DATA — "Base workspace with zero issues."
>    - `many_issues` — DATA — "75 issues (ENG-1 through ENG-75) for pagination testing."
>    - `archived_issues` — DATA — "One active issue plus one archived Done issue."
>    - `webhook_demo` — DATA — "Basic workspace used as the source state for webhook replay demos."
>    - `rate_limited` — ERROR (red badge) — "Every request returns HTTP 200 with an errors array (type RATELIMITED)."
>    - `invalid_token` — ERROR (red badge) — "Every request returns an AUTHENTICATION_ERROR."
>    - `permission_denied` — ERROR (red badge) — "Every request returns a FORBIDDEN error."

---

## Page 3 — Entities (data browser)

> A browser for the simulator's current seeded data, Linear-style. Mark the **Entities** sidebar row active.
>
> *(paste SHARED DESIGN SYSTEM + SHARED SHELL here)*
>
> **Page Structure:**
> 1. **Section header:** "Entities Browser".
> 2. **Tabs:** Issues (active), Projects, Teams, Workflow States, Users.
> 3. **Toolbar:** a search field ("Search issues…") and a State filter dropdown listing all eight workflow states — Todo, In Progress, In Review, Merging, Rework, Done, Canceled, Duplicate.
> 4. **Issues table:** dense, columns Identifier (monospace, e.g. `ENG-1`), Title, State (colored workflow-state pill), Assignee, Branch (monospace, e.g. `hakan/eng-1`), Updated. Sample rows use the seeded user **Håkan Niska** and identifiers ENG-1 / ENG-2 / ENG-3 with realistic states (Todo, In Progress, Done).

---

## Page 4 — Captured Operations (master-detail)

> A feed of GraphQL operations captured from agent traffic, for promotion into the curated test corpus. Mark the **Captured Operations** sidebar row active.
>
> *(paste SHARED DESIGN SYSTEM + SHARED SHELL here)*
>
> **Page Structure:**
> 1. **Section header:** "Captured Operations" with a capture on/off status indicator and a secondary "Clear captures" button.
> 2. **Master list (left third, full height, scrollable):** rows showing operation name (monospace), a QUERY/MUTATION tag, and a timestamp. Sample rows: `IssuesQuery` (QUERY), `IssueUpdate` (MUTATION), `ViewerQuery` (QUERY). First row selected (indigo left border).
> 3. **Detail panel (right two-thirds, full height):** header "Details: IssuesQuery" with a copy button; a syntax-highlighted monospace GraphQL code block; below it a "Variables (redacted)" label with a monospace JSON block; and a primary indigo "Promote to curated corpus" button bottom-right.

---

## Page 5 — Webhooks (replay + history)

> A tool to sign and replay webhooks to a target app, with delivery history. Mark the **Webhooks** sidebar row active.
>
> *(paste SHARED DESIGN SYSTEM + SHARED SHELL here)*
>
> **Page Structure:**
> 1. **Section header:** "Webhooks".
> 2. **Replay form (left half):** fields — Target URL (text, placeholder `http://localhost:4001/webhooks/linear`), Secret (masked monospace), Event Type dropdown (IssueCreated / IssueUpdated / CommentCreated), and a monospace JSON payload textarea; a primary "Sign & deliver" button.
> 3. **Delivery history (right half, scrollable table):** columns Timestamp (monospace), Event, Target, Status (colored pill — delivered / failed), HTTP code; clicking a row reveals signature, response body, and error reason in monospace.

---

## Page 6 — Settings

> Configuration for the running simulator instance. Mark the **Settings** sidebar row active.
>
> *(paste SHARED DESIGN SYSTEM + SHARED SHELL here)*
>
> **Page Structure:**
> 1. **Section header:** "Settings".
> 2. **Operation capture card:** a toggle "Capture incoming operations to disk", with a read-only path field `priv/linear/operations/captured/` and toggles "Include variables" and "Redact variables".
> 3. **GraphQL logging card:** toggles — "Log queries", "Log variables", "Redact Authorization header".
> 4. **Endpoint card:** read-only monospace rows — GraphQL `POST /graphql`, Admin reset `POST /admin/reset`, State dump `GET /admin/state`, Bearer token `user_hakan`.
> 5. **Danger zone card:** a red-outlined "Reset database to default scenario" button and a "Wipe all data" button.

---

## Accuracy reference (what the real simulator does)

- **8 scenarios:** `basic_workspace` (default), `empty_workspace`, `many_issues` (75 issues), `archived_issues`, `webhook_demo`, `rate_limited`, `invalid_token`, `permission_denied`.
- **Error scenarios return HTTP 200** with an `errors` array (`RATELIMITED` / `AUTHENTICATION_ERROR` / `FORBIDDEN`) — Linear never returns 429.
- **Seeded data:** org Acme, user Håkan Niska (hakan@example.test), team ENG, project Roadmap, 8 workflow states (Todo, In Progress, In Review, Merging, Rework, Done, Canceled, Duplicate).
- **Supported GraphQL ops:** queries `viewer`, `issues`, `issue`, `projects`, `team.states`; mutations `issueUpdate`, `commentCreate`, `commentUpdate`.
- **Admin endpoints:** `GET /health`, `POST /admin/reset`, `POST /admin/scenario/:name`, `GET /admin/state`, `POST /admin/webhooks/replay`.
- **Operation capture** writes `.graphql` + `.variables.json` + `.metadata.json` (redacted auth) to `priv/linear/operations/captured/`; captures get promoted into the curated corpus (validated by `mix linear_sim.validate_operations`).
</content>
