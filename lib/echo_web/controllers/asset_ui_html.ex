defmodule EchoWeb.AssetUIHTML do
  use EchoWeb, :html

  embed_templates "asset_ui_html/*"

  def format_bytes(nil), do: "—"
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  def format_bytes(bytes) when bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  def format_bytes(bytes) do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  def format_dimensions(nil, nil), do: "—"
  def format_dimensions(width, height), do: "#{width} × #{height}"
end
