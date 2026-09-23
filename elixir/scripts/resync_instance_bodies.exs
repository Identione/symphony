# Re-bake every instance WORKFLOW.md *body* from the current template, deriving
# @base_branch, @gate_command and @worker_notes from that instance's OWN front
# matter (`repo.*`) so the baked prose can never disagree with it. Front matter is preserved
# byte-for-byte (this is the "body-only init" that `make init --force` is not —
# --force regenerates the whole file and clobbers hand-tuned front matter).
#
#   Run (resync every instance, writes files):
#     cd elixir && mise exec -- elixir scripts/resync_instance_bodies.exs
#   Check only (no writes; exits 1 on drift — use in preflight/CI):
#     cd elixir && mise exec -- elixir scripts/resync_instance_bodies.exs --check
#   Scope to specific file(s) (e.g. one instance's preflight checks itself):
#     ... scripts/resync_instance_bodies.exs --check /abs/instances/<name>/WORKFLOW.md

elixir_dir = Path.expand("..", __DIR__)
repo_root = Path.expand("..", elixir_dir)
template_path = Path.join(elixir_dir, "priv/templates/workflow.md.eex")
instances_glob = Path.join(repo_root, "instances/*/WORKFLOW.md")

argv = System.argv()
check_only? = "--check" in argv
# Bare positional args are explicit WORKFLOW.md path(s); default to every
# discovered instance. The instance preflight passes its own absolute
# $(WORKFLOW) so it validates just itself.
explicit_paths = argv |> Enum.reject(&String.starts_with?(&1, "--")) |> Enum.map(&Path.expand/1)

marker = "You are working on a Linear ticket"

# Minimal front-matter readers (stdlib only — no YAML dep): a scalar `key:` line
# (optionally double-quoted) and a `key: |` literal block scalar whose body is
# every following line indented deeper than the key (blank lines kept, common
# 4-space indent stripped, trailing blank lines dropped).
scalar = fn header, key ->
  case Regex.run(~r/^\s*#{key}:\s*"?([^"\n]+?)"?\s*$/m, header) do
    [_, v] -> String.trim(v)
    _ -> nil
  end
end

block = fn header, key ->
  lines = String.split(header, "\n")

  case Enum.find_index(lines, &Regex.match?(~r/^\s*#{key}:\s*\|\s*$/, &1)) do
    nil ->
      nil

    idx ->
      key_indent = lines |> Enum.at(idx) |> then(&(String.length(&1) - String.length(String.trim_leading(&1))))

      body =
        lines
        |> Enum.drop(idx + 1)
        |> Enum.take_while(fn line ->
          String.trim(line) == "" or
            String.length(line) - String.length(String.trim_leading(line)) > key_indent
        end)
        |> Enum.map(&String.replace_prefix(&1, String.duplicate(" ", key_indent + 2), ""))
        |> Enum.join("\n")
        |> String.trim_trailing()

      if body == "", do: nil, else: body
  end
end

template = File.read!(template_path)
[_front_matter, template_rest] = String.split(template, marker, parts: 2)
template_body = marker <> template_rest

paths =
  case explicit_paths do
    [] -> instances_glob |> Path.wildcard() |> Enum.sort()
    given -> given
  end

if paths == [] do
  IO.puts("No instance WORKFLOW.md files found under #{instances_glob}")
  System.halt(0)
end

IO.puts((check_only? && "Checking instance bodies...") || "Resyncing instance bodies...")

drift =
  Enum.reduce(paths, [], fn path, acc ->
    name = path |> Path.dirname() |> Path.basename()
    content = File.read!(path)

    case String.split(content, marker, parts: 2) do
      [header, body_rest] ->
        oldbody = marker <> body_rest

        base = scalar.(header, "base_branch")
        gate = scalar.(header, "gate_command")
        notes = block.(header, "worker_notes")

        rendered =
          EEx.eval_string(template_body,
            assigns: [base_branch: base, gate_command: gate, worker_notes: notes]
          )

        label =
          "#{String.pad_trailing(name, 26)} base=#{inspect(base)} gate=#{inspect(gate)} notes=#{(notes && "yes") || "no"}"

        cond do
          oldbody == rendered ->
            IO.puts("  #{label}  in sync ✓")
            acc

          check_only? ->
            IO.puts("  #{label}  DRIFT ✗")
            [name | acc]

          true ->
            File.write!(path, header <> rendered)
            IO.puts("  #{label}  RESYNCED")
            acc
        end

      _ ->
        IO.puts("  #{name}: no body marker, skipped")
        acc
    end
  end)

if check_only? and drift != [] do
  IO.puts("\nOut of sync (run without --check to fix): #{Enum.join(Enum.reverse(drift), ", ")}")
  System.halt(1)
end
