defmodule SymphonyElixir.CLI.LinearProject do
  @moduledoc """
  Parses the `--linear-project` value supplied to `symphony init`/`symphony preflight`.

  Linear's GraphQL filter `project: {slugId: {eq: ...}}` accepts both the URL
  slug (e.g. `symphony-2e32f5d86d8c`) and the trailing 12-hex slug id alone
  (`2e32f5d86d8c`). We preserve whichever form the operator supplied so the
  generated `WORKFLOW.md` stays human-readable, but we also expose the
  hex-only slug id for callers that need to verify the project exists.
  """

  @type parsed :: %{slug: String.t(), slug_id: String.t() | nil}

  @url_pattern ~r"^https?://[^/]+/[^/]+/project/(?<slug>[A-Za-z0-9._-]+)"
  @slug_pattern ~r"^[A-Za-z0-9._-]+$"
  # Anchor on the start of the slug or a `-` separator so a longer hex run
  # (e.g. a hypothetical 16-hex slug) does not silently surface its trailing
  # 12 chars as a "slug id". Today's Linear slugs are always `<name>-<12hex>`
  # or the bare 12-hex form, but the anchor keeps the parse defensive.
  @hex_id_pattern ~r"(?:^|-)([0-9a-f]{12})$"

  @spec parse(String.t() | nil) :: {:ok, parsed()} | {:error, String.t()}
  def parse(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, "missing Linear project URL or slug"}

      String.starts_with?(trimmed, ["http://", "https://"]) ->
        from_url(trimmed)

      Regex.match?(@slug_pattern, trimmed) ->
        {:ok, build(trimmed)}

      true ->
        {:error, "expected a Linear project URL or slug; got #{inspect(value)}"}
    end
  end

  def parse(_value), do: {:error, "missing Linear project URL or slug"}

  defp from_url(url) do
    case Regex.named_captures(@url_pattern, url) do
      %{"slug" => slug} when slug != "" ->
        {:ok, build(slug)}

      _ ->
        {:error, "could not parse Linear project URL: #{inspect(url)}"}
    end
  end

  defp build(slug) do
    %{slug: slug, slug_id: extract_slug_id(slug)}
  end

  defp extract_slug_id(slug) do
    case Regex.run(@hex_id_pattern, slug) do
      [_match, hex] -> hex
      _ -> nil
    end
  end
end
