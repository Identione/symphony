defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  require Logger

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
      field(:required_labels, {:array, :string}, default: [])
      field(:excluded_labels, {:array, :string}, default: [])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :project_slug,
          :assignee,
          :active_states,
          :terminal_states,
          :required_labels,
          :excluded_labels
        ],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Repo do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # `url` is the clone URL Symphony hands to `hooks.after_create` for fresh
      # workspaces. Preflight uses it for an unauthenticated `git ls-remote`
      # reachability check. Optional so legacy workflows that hardcode the URL
      # in `hooks.after_create` keep parsing.
      field(:url, :string)
      # `path` is an optional pointer to a local copy of the repo. Symphony
      # itself never reads or writes through this — it exists for skills that
      # need to inspect or modify project-local files outside the per-issue
      # workspace.
      field(:path, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:url, :path], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Quota do
    @moduledoc """
    Per-provider account-quota tracking config, shared by `agent.codex.quota`
    and `agent.claude.quota`.

    `enabled`/`stale_after_ms`/`dispatch_pause_percent` apply to both providers.
    The remaining fields (`endpoint`, `anthropic_beta`, `refresh_ms`,
    `token_source`, `cli_refresh_command`, `cli_refresh_margin_ms`) drive the
    Claude OAuth usage poller only — Codex quota is derived from the app-server
    rate-limit stream, so those fields are ignored for `agent.codex.quota`.

    `token_source` controls how the Claude OAuth access token is obtained:
    `credentials_file` reads it read-only; `claude_cli_refresh` additionally
    runs `cli_refresh_command` (a zero-inference `claude` CLI startup) when the
    cached token is within `cli_refresh_margin_ms` of expiry, letting the CLI
    perform the OAuth refresh in place. `$CLAUDE_CODE_OAUTH_TOKEN` always wins
    and skips both.
    """
    use Ecto.Schema
    import Ecto.Changeset

    @token_sources ~w(credentials_file claude_cli_refresh)

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:endpoint, :string, default: "https://api.anthropic.com/api/oauth/usage")
      field(:anthropic_beta, :string, default: "oauth-2025-04-20")
      field(:refresh_ms, :integer, default: 60_000)
      field(:stale_after_ms, :integer, default: 180_000)
      field(:dispatch_pause_percent, :float, default: 95.0)
      field(:token_source, :string, default: "credentials_file")
      field(:cli_refresh_command, :string, default: "claude -p /exit")
      field(:cli_refresh_margin_ms, :integer, default: 300_000)
    end

    @spec token_sources() :: [String.t()]
    def token_sources, do: @token_sources

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :endpoint,
          :anthropic_beta,
          :refresh_ms,
          :stale_after_ms,
          :dispatch_pause_percent,
          :token_source,
          :cli_refresh_command,
          :cli_refresh_margin_ms
        ],
        empty_values: []
      )
      |> validate_required([:endpoint, :anthropic_beta, :token_source, :cli_refresh_command])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:stale_after_ms, greater_than: 0)
      |> validate_number(:dispatch_pause_percent, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
      |> validate_number(:cli_refresh_margin_ms, greater_than: 0)
      |> validate_inclusion(:token_source, @token_sources)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema.Quota

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:use_configured_permissions, :boolean, default: false)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      embeds_one(:quota, Quota, on_replace: :update, defaults_to_struct: true)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :use_configured_permissions,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> cast_embed(:quota, with: &Quota.changeset/2)
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Claude do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema
    alias SymphonyElixir.Config.Schema.Quota

    @permission_modes ~w(default acceptEdits plan dontAsk bypassPermissions)
    @system_prompt_presets ~w(claude_code minimal)
    # Claude Agent SDK reasoning-effort levels (ClaudeAgentOptions.effort). The
    # parallel to Codex's `model_reasoning_effort`. `xhigh` is Opus 4.7-only and
    # falls back to `high` on other models. Unset → the SDK default (`high`).
    @efforts ~w(low medium high xhigh max)

    # The sidecar Port spawns with `cd: workspace`, so a workspace-relative
    # path here would not resolve to the priv dir. `$SYMPHONY_CLAUDE_PRIV_DIR`
    # is injected by `Claude.AppServer` (resolves to this app's
    # `priv/claude_agent`) and expanded by bash. The default ships with a
    # `jai` prefix so the recommended Approach A — outer sandbox containment
    # via jai (Linux 6.13+) — works out of the box; hosts without jai must
    # override `agent.claude.command` to drop the prefix (Approach B).
    @default_command "jai uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent"

    @primary_key false
    embedded_schema do
      field(:command, :string, default: @default_command)
      field(:model, :string)
      field(:permission_mode, :string, default: "dontAsk")
      field(:allowed_tools, {:array, :string}, default: [])
      field(:disallowed_tools, {:array, :string}, default: [])
      field(:system_prompt_preset, :string, default: "claude_code")
      # Which filesystem settings layers the underlying `claude` CLI loads.
      # Unset (nil) — the default — means "load the CLI defaults"
      # (user/project/local), so a Claude agent inherits the target repo's
      # `.claude/settings.json`, `enableAllProjectMcpServers`, project
      # `.mcp.json` servers (e.g. `lsp`), and `CLAUDE.md`, exactly like an
      # interactive `claude` run in that checkout. The sidecar omits the field
      # entirely when nil so the SDK applies its own all-sources default. Set
      # this to `[]` to restore deterministic isolation (load no host-level
      # settings), or to a subset like `["project"]`. Safety for the inherited
      # surface (repo hooks, repo permission rules) rests on the jai sandbox in
      # the default `command` + the workspace-cwd invariant, not on isolation.
      field(:setting_sources, {:array, :string})
      # Level-1 belt (P0.4): the SDK caps model turns *within a single
      # continuation* at this value. Left unset the SDK is unbounded, so a
      # non-rate-limit within-query tool runaway is bounded only by
      # `max_budget_usd` (also unset by default). 40 sits well above the
      # observed 2–4 turns/continuation norm without truncating legitimate long
      # turns. Rate-limit waste is braked separately at the error path; this is
      # the generic within-session ceiling.
      field(:max_turns, :integer, default: 40)
      field(:max_budget_usd, :float)
      # R2b: per-call cap (bytes) on native-tool output (Read/Bash/Grep/Glob),
      # enforced by a PostToolUse hook in the sidecar. A returned tool result is
      # re-sent as `cache_read` on every later turn, so an uncapped large output
      # is paid for ~Σ(turns) times. The hook shrinks oversized string leaves
      # head+tail (preserving the tool's output schema) and tells the model it
      # can re-read a narrower slice. Default 16 KiB; 0 disables the hook.
      field(:tool_output_limit, :integer, default: 16_384)
      # Reasoning effort forwarded to the sidecar's ClaudeAgentOptions. No
      # default — when unset Symphony sends nothing and the SDK picks its own
      # default (`high`).
      field(:effort, :string)
      # Per-issue-state overrides for `model`/`effort`, keyed by lowercased
      # Linear state name (e.g. `merging`). When the issue's current state has
      # an entry it wins over the top-level `model`/`effort`; otherwise the
      # global value (or SDK default) applies. Mirrors
      # `agent.max_concurrent_agents_by_state`. Lets mechanical states (the
      # merge/land run) drop to a cheaper model + lower reasoning effort.
      field(:model_by_state, :map, default: %{})
      field(:effort_by_state, :map, default: %{})
      field(:extra_env, :map, default: %{})
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      # Cold sidecar startup (uv → Python interpreter → claude_agent_sdk
      # import → SDK __aenter__) takes ~6 s on a warm cache, more under load.
      # 30 s gives comfortable headroom over that without masking real hangs.
      field(:read_timeout_ms, :integer, default: 30_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      # While a native tool (e.g. a long `Bash` build) is in flight the agent
      # legitimately emits no events, so the idle `stall_timeout_ms` would
      # misread it as a hang. `tool_stall_timeout_ms` grants the in-flight
      # window a longer leash (default 30 min); raise it for builds that run
      # longer. Bounded in practice by `turn_timeout_ms` (a tool can't outlive
      # its turn). Codex needs no analogue — it streams exec output natively.
      field(:tool_stall_timeout_ms, :integer, default: 1_800_000)
      # When set, Symphony scopes Claude auth to this CLAUDE_CONFIG_DIR — both
      # for preflight (looks for `<config_dir>/.credentials.json`) and at run
      # time (sidecar Port inherits CLAUDE_CONFIG_DIR=<config_dir>). Useful
      # for users with multiple Claude logins on one machine.
      field(:config_dir, :string)
      # When true, opts into the verbose Claude debug feed:
      #   - the sidecar enables `include_partial_messages` and
      #     `include_hook_events` on ClaudeAgentOptions for richer tracing,
      #   - the sidecar forwards the underlying `claude` CLI's stderr (always
      #     `--verbose` under the SDK) back to Symphony as `log` envelopes,
      #   - Symphony's `AgentRunner` emits per-envelope `claude tool_call` /
      #     `assistant_message` / `turn_completed` / `permission_request` /
      #     `system_init` log lines.
      # Off by default — these streams together flood symphony.log and
      # drown out per-issue orchestration output during normal runs.
      field(:verbose_logging, :boolean, default: false)
      embeds_one(:quota, Quota, on_replace: :update, defaults_to_struct: true)
    end

    @spec permission_modes() :: [String.t()]
    def permission_modes, do: @permission_modes

    @spec system_prompt_presets() :: [String.t()]
    def system_prompt_presets, do: @system_prompt_presets

    @spec efforts() :: [String.t()]
    def efforts, do: @efforts

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :model,
          :permission_mode,
          :allowed_tools,
          :disallowed_tools,
          :system_prompt_preset,
          :setting_sources,
          :max_turns,
          :max_budget_usd,
          :tool_output_limit,
          :effort,
          :model_by_state,
          :effort_by_state,
          :extra_env,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :tool_stall_timeout_ms,
          :config_dir,
          :verbose_logging
        ],
        empty_values: []
      )
      |> cast_embed(:quota, with: &Quota.changeset/2)
      |> validate_required([:command])
      |> validate_inclusion(:permission_mode, @permission_modes)
      |> validate_inclusion(:system_prompt_preset, @system_prompt_presets)
      |> validate_inclusion(:effort, @efforts)
      |> update_change(:model_by_state, &Schema.normalize_state_map/1)
      |> update_change(:effort_by_state, &Schema.normalize_state_map/1)
      |> Schema.validate_state_strings(:model_by_state)
      |> validate_state_efforts(:effort_by_state)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:tool_stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:tool_output_limit, greater_than_or_equal_to: 0)
    end

    # Like `Schema.validate_state_strings/2`, but additionally constrains each
    # value to the `@efforts` whitelist (the validator lives here so it can see
    # the module-local list).
    defp validate_state_efforts(changeset, field) do
      validate_change(changeset, field, fn ^field, mapping ->
        Enum.flat_map(mapping, fn {state_name, effort} ->
          cond do
            to_string(state_name) == "" ->
              [{field, "state names must not be blank"}]

            effort not in @efforts ->
              [{field, "effort must be one of: #{Enum.join(@efforts, ", ")}"}]

            true ->
              []
          end
        end)
      end)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @kinds ~w(codex claude)

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:retry_policy, :map, default: %{})
      field(:kind, :string, default: "codex")
      # Deterministic-failure escalation (IDE-73). Tracks consecutive failures
      # carrying the same structured `error_code` (IDE-71 taxonomy) — quota
      # exhaustion, context-window overflow, sidecar binary missing, etc.
      # Transient codes (`rate_limited`, `overloaded`) reset the counter and
      # never trip these thresholds.
      field(:deterministic_failure_alert_threshold, :integer, default: 3)
      field(:deterministic_failure_escalation_threshold, :integer, default: 5)
      field(:deterministic_failure_escalation_state, :string, default: "Human Review")
      # Cumulative, episode-scoped ceiling on how many agent sessions a single
      # issue may run before the orchestrator escalates it (P1/R1(a)). Unlike
      # the deterministic-failure streak — which only counts *consecutive
      # same-code* failures and resets on a clean `:normal` exit or a transient
      # blip — this is failure-mode-agnostic: it catches an issue that keeps
      # finishing turns cleanly yet never leaves the active set (the
      # poll-only/blocked-parent loop). The count is persisted per issue (DETS
      # under the instance `run/`) so it survives a daemon restart / `make
      # upgrade`, and resets when the issue leaves the active set (terminal,
      # escalated, or human-moved). Default 8 sits well above a normal
      # multi-turn issue.
      field(:max_sessions_per_issue, :integer, default: 8)
      # Budget-pressure steering + non-destructive cutoff (IDE-189 / Layer 0).
      # These knobs are global `agent.*` (not per-adapter) because both
      # mechanisms live in the adapter-agnostic shared turn loop / orchestrator,
      # so codex and claude are covered by construction.
      #
      # Inject budget-pressure steering into continuation prompts when within
      # this many turns of `agent.max_turns`. The threshold must leave >=1
      # actionable turn (the directive rides the *next* turn's prompt); `0`
      # disables steering entirely.
      field(:budget_pressure_turns, :integer, default: 2)
      # Master switch for non-destructive cutoff: snapshot a dirty working tree
      # to a `refs/symphony/wip/<id>` commit before any session stop or
      # `max_turns` cutoff, so converging work is never silently discarded.
      field(:preserve_uncommitted_work, :boolean, default: true)
      # Also create a visible/diffable `symphony/wip/<id>` branch alongside the
      # ref (the ref is always created when preservation runs).
      field(:preserve_uncommitted_work_branch, :boolean, default: false)
      # Timeout for the preservation git-shell invocation.
      field(:cutoff_timeout_ms, :integer, default: 60_000)
      # Deterministic per-turn progress signals (IDE-211 / Layer 1). Computed
      # once per turn boundary from a cheap non-mutating git probe; reported &
      # logged only — never acted on by this layer.
      #
      # Master switch for the per-turn probe + assessment.
      field(:progress_signal_enabled, :boolean, default: true)
      # Window K: consecutive-turn count before `:stuck_state`/`:repeated_error`
      # fire and the turn floor for `at_risk_no_commits`. Tuned from the IDE-189
      # replay (fires by turn 4 of a 20-turn budget). Validated `>= 2`.
      field(:progress_signal_window_k, :integer, default: 4)
      # Timeout for the per-turn progress git probe; a slow/locked repo degrades
      # to "unknown" (assessment unchanged) rather than stalling the loop.
      field(:progress_signal_git_timeout_ms, :integer, default: 2_000)
      # Turn floor for the `at_risk_no_commits` arm of the Layer-2 trigger
      # predicate (`ProgressSignal.trigger?/2`).
      field(:progress_trigger_min_turns, :integer, default: 4)
      embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
      embeds_one(:claude, Claude, on_replace: :update, defaults_to_struct: true)
    end

    @spec kinds() :: [String.t()]
    def kinds, do: @kinds

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state,
          :retry_policy,
          :kind,
          :deterministic_failure_alert_threshold,
          :deterministic_failure_escalation_threshold,
          :deterministic_failure_escalation_state,
          :max_sessions_per_issue,
          :budget_pressure_turns,
          :preserve_uncommitted_work,
          :preserve_uncommitted_work_branch,
          :cutoff_timeout_ms,
          :progress_signal_enabled,
          :progress_signal_window_k,
          :progress_signal_git_timeout_ms,
          :progress_trigger_min_turns
        ],
        empty_values: []
      )
      |> cast_embed(:codex, with: &Codex.changeset/2)
      |> cast_embed(:claude, with: &Claude.changeset/2)
      |> validate_inclusion(:kind, @kinds)
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:deterministic_failure_alert_threshold, greater_than: 0)
      |> validate_number(:deterministic_failure_escalation_threshold, greater_than: 0)
      |> validate_number(:max_sessions_per_issue, greater_than: 0)
      |> validate_number(:budget_pressure_turns, greater_than_or_equal_to: 0)
      |> validate_number(:cutoff_timeout_ms, greater_than: 0)
      |> validate_number(:progress_signal_window_k, greater_than_or_equal_to: 2)
      |> validate_number(:progress_signal_git_timeout_ms, greater_than: 0)
      |> validate_number(:progress_trigger_min_turns, greater_than_or_equal_to: 1)
      |> validate_thresholds_order()
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
      |> update_change(:retry_policy, &Schema.normalize_retry_policy/1)
      |> Schema.validate_retry_policy(:retry_policy)
    end

    defp validate_thresholds_order(changeset) do
      alert = get_field(changeset, :deterministic_failure_alert_threshold)
      escalate = get_field(changeset, :deterministic_failure_escalation_threshold)

      if is_integer(alert) and is_integer(escalate) and escalate < alert do
        add_error(
          changeset,
          :deterministic_failure_escalation_threshold,
          "must be >= deterministic_failure_alert_threshold"
        )
      else
        changeset
      end
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:repo, Repo, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> apply_legacy_codex_alias()
    |> apply_legacy_claude_verbose_alias()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  # Several runtime call sites still read `settings.codex.*` rather than
  # `settings.agent.codex.*`. Mirror in both directions so the two layouts
  # stay in sync; when both are present, nested wins (matches
  # Agent.changeset/2's preference at the schema layer).
  defp apply_legacy_codex_alias(config) when is_map(config) do
    agent_block =
      case Map.get(config, "agent") do
        block when is_map(block) -> block
        _ -> %{}
      end

    top_codex = Map.get(config, "codex")
    nested_codex = Map.get(agent_block, "codex")

    case {top_codex, nested_codex} do
      {top, nil} when is_map(top) ->
        Map.put(config, "agent", Map.put(agent_block, "codex", top))

      {_, nested} when is_map(nested) ->
        config
        |> Map.put("codex", nested)
        |> Map.put("agent", agent_block)

      _ ->
        config
    end
  end

  # `agent.claude.verbose` was the original toggle; it was renamed to
  # `agent.claude.verbose_logging` so the name covers all three noise sources
  # (SDK partial/hook streams, forwarded `claude_cli` stderr, Symphony's
  # per-envelope log lines). `Ecto.Changeset.cast/3` would otherwise drop the
  # legacy key silently and switch users to quiet mode without warning.
  # Accept it for one release: warn loudly, then map onto `verbose_logging`
  # when the new key is absent.
  defp apply_legacy_claude_verbose_alias(config) when is_map(config) do
    with %{"agent" => agent_block} <- config,
         %{"claude" => claude_block} when is_map(claude_block) <- agent_block,
         true <- Map.has_key?(claude_block, "verbose") do
      legacy_value = Map.get(claude_block, "verbose")
      claude_block_pruned = Map.delete(claude_block, "verbose")

      claude_block_final =
        if Map.has_key?(claude_block_pruned, "verbose_logging") do
          Logger.warning(
            "agent.claude.verbose is deprecated; agent.claude.verbose_logging takes " <>
              "precedence. Remove the legacy `verbose` key from WORKFLOW.md."
          )

          claude_block_pruned
        else
          Logger.warning(
            "agent.claude.verbose is deprecated; rename to agent.claude.verbose_logging. " <>
              "Honoring the legacy value (#{inspect(legacy_value)}) for this release."
          )

          Map.put(claude_block_pruned, "verbose_logging", legacy_value)
        end

      Map.put(config, "agent", Map.put(agent_block, "claude", claude_block_final))
    else
      _ -> config
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map() | nil
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    if settings.codex.use_configured_permissions do
      nil
    else
      case settings.codex.turn_sandbox_policy do
        %{} = policy ->
          policy

        _ ->
          workspace
          |> default_workspace_root(settings.workspace.root)
          |> expand_local_workspace_root()
          |> default_turn_sandbox_policy()
      end
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    if settings.codex.use_configured_permissions do
      {:ok, nil}
    else
      case settings.codex.turn_sandbox_policy do
        %{} = policy ->
          {:ok, ensure_workspace_write_root(policy, workspace, opts)}

        _ ->
          workspace
          |> default_workspace_root(settings.workspace.root)
          |> default_runtime_turn_sandbox_policy(opts)
      end
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec normalize_state_map(nil | map()) :: map()
  def normalize_state_map(nil), do: %{}

  def normalize_state_map(mapping) when is_map(mapping) do
    Enum.reduce(mapping, %{}, fn {state_name, value}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), value)
    end)
  end

  @doc false
  @spec validate_state_strings(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_strings(changeset, field) do
    validate_change(changeset, field, fn ^field, mapping ->
      Enum.flat_map(mapping, fn {state_name, value} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_binary(value) or value == "" ->
            [{field, "values must be non-empty strings"}]

          true ->
            []
        end
      end)
    end)
  end

  # Per-error-code retry policy overrides; see WORKFLOW.md `agent.retry_policy`
  # for the operator-facing surface and `Orchestrator.RetryPolicy` for the
  # built-in defaults.
  @retry_policy_strategies ~w(backoff no_retry)
  @retry_policy_codes ~w(
    rate_limited
    overloaded
    context_window_exhausted
    quota_exceeded
    invalid_request
    max_turns_reached
    unknown
  )
  @retry_policy_keys ~w(strategy base_ms max_ms honor_retry_after)

  @doc false
  @spec normalize_retry_policy(nil | map()) :: map()
  def normalize_retry_policy(nil), do: %{}

  def normalize_retry_policy(policy) when is_map(policy) do
    Enum.reduce(policy, %{}, fn {code, settings}, acc ->
      Map.put(acc, to_string(code), normalize_retry_policy_entry(settings))
    end)
  end

  defp normalize_retry_policy_entry(settings) when is_map(settings) do
    Enum.reduce(settings, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_retry_policy_entry(settings), do: settings

  @doc false
  @spec validate_retry_policy(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_retry_policy(changeset, field) do
    validate_change(changeset, field, fn ^field, policy ->
      Enum.flat_map(policy, fn {code, settings} -> retry_policy_errors(field, code, settings) end)
    end)
  end

  defp retry_policy_errors(field, code, _settings) when code not in @retry_policy_codes do
    [{field, "unknown error code: #{inspect(code)}"}]
  end

  defp retry_policy_errors(field, _code, settings) when not is_map(settings) do
    [{field, "policy entry must be a map, got: #{inspect(settings)}"}]
  end

  defp retry_policy_errors(field, _code, settings) do
    Enum.flat_map(settings, fn {key, value} -> retry_policy_field_errors(field, key, value) end)
  end

  defp retry_policy_field_errors(field, key, _value) when key not in @retry_policy_keys do
    [{field, "unknown policy key: #{inspect(key)}"}]
  end

  defp retry_policy_field_errors(field, "strategy", value)
       when value not in @retry_policy_strategies do
    [{field, "strategy must be one of #{Enum.join(@retry_policy_strategies, ", ")}"}]
  end

  defp retry_policy_field_errors(field, key, value) when key in ["base_ms", "max_ms"] do
    if is_integer(value) and value > 0 do
      []
    else
      [{field, "#{key} must be a positive integer, got: #{inspect(value)}"}]
    end
  end

  defp retry_policy_field_errors(field, "honor_retry_after", value)
       when not is_boolean(value) do
    [{field, "honor_retry_after must be a boolean, got: #{inspect(value)}"}]
  end

  defp retry_policy_field_errors(_field, _key, _value), do: []

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:repo, with: &Repo.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> validate_deterministic_escalation_state_disjoint()
  end

  # If the escalation state is still listed in `tracker.active_states`, the
  # polling loop would re-claim the escalated issue on the next tick — the
  # exact infinite loop the escalation exists to break.
  defp validate_deterministic_escalation_state_disjoint(changeset) do
    with %Agent{deterministic_failure_escalation_state: escalation_state} when is_binary(escalation_state) <-
           get_field(changeset, :agent),
         %Tracker{active_states: active_states} when is_list(active_states) <-
           get_field(changeset, :tracker),
         true <- escalation_state_in_active_states?(escalation_state, active_states) do
      add_error(
        changeset,
        :agent,
        "deterministic_failure_escalation_state must not appear in tracker.active_states " <>
          "(escalation_state=#{inspect(escalation_state)}, active_states=#{inspect(active_states)})"
      )
    else
      _ -> changeset
    end
  end

  defp escalation_state_in_active_states?(escalation_state, active_states)
       when is_binary(escalation_state) and is_list(active_states) do
    normalized_escalation = normalize_issue_state(escalation_state)

    Enum.any?(active_states, fn active ->
      is_binary(active) and normalize_issue_state(active) == normalized_escalation
    end)
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(nil, default), do: default

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp ensure_workspace_write_root(%{"type" => "workspaceWrite"} = policy, workspace, opts) do
    case runtime_workspace_write_root(workspace, opts) do
      nil ->
        policy

      workspace_root ->
        writable_roots =
          policy
          |> Map.get("writableRoots", [])
          |> normalize_writable_roots()
          |> List.insert_at(0, workspace_root)
          |> Enum.uniq()

        Map.put(policy, "writableRoots", writable_roots)
    end
  end

  defp ensure_workspace_write_root(policy, _workspace, _opts), do: policy

  defp runtime_workspace_write_root(workspace, opts)
       when is_binary(workspace) and workspace != "" do
    if Keyword.get(opts, :remote, false), do: workspace, else: Path.expand(workspace)
  end

  defp runtime_workspace_write_root(_workspace, _opts), do: nil

  defp normalize_writable_roots(roots) when is_list(roots), do: roots
  defp normalize_writable_roots(_roots), do: []

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
