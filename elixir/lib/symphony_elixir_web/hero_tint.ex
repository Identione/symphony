defmodule SymphonyElixirWeb.HeroTint do
  @moduledoc """
  Deterministic accent tint for the dashboard hero card, derived from the
  Linear project name.

  The same project name always maps to the same HSL hue, so dashboards
  belonging to a given project carry the same subtle wash across restarts
  and across operators. Saturation and lightness are fixed so the tint
  stays light enough to preserve text contrast on the card.
  """

  # Low saturation, high lightness keep the wash subtle so the dark hero
  # text stays readable. The border sits a few percent darker to define
  # the card edge without competing with the title.
  @saturation 70
  @background_lightness 96
  @border_lightness 84

  # Returns `nil` when no project is configured so the card falls back to
  # its default look via the CSS custom-property fallbacks.
  @spec inline_style(String.t() | nil) :: String.t() | nil
  def inline_style(nil), do: nil
  def inline_style(""), do: nil

  def inline_style(project_name) when is_binary(project_name) do
    hue = hue_for(project_name)

    "--hero-tint-bg: hsl(#{hue} #{@saturation}% #{@background_lightness}%); " <>
      "--hero-tint-border: hsl(#{hue} #{@saturation}% #{@border_lightness}%);"
  end

  @spec hue_for(String.t()) :: non_neg_integer()
  def hue_for(project_name) when is_binary(project_name) do
    <<value::unsigned-integer-size(32), _rest::binary>> =
      :crypto.hash(:sha256, project_name)

    rem(value, 360)
  end
end
