# Re-bake every instance WORKFLOW.md *body* from the current template, deriving
# @base_branch from that instance's OWN front matter so the baked branch prose
# can never disagree with repo.base_branch. Front matter is preserved
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

        base =
          case Regex.run(~r/^\s*base_branch:\s*"?([^"\n]+?)"?\s*$/m, header) do
            [_, b] -> String.trim(b)
            _ -> nil
          end

        rendered = EEx.eval_string(template_body, assigns: [base_branch: base])
        label = "#{String.pad_trailing(name, 26)} base=#{inspect(base)}"

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
