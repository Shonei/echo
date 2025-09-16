defmodule EchoWeb.UIHTML do
  @moduledoc """
  This module contains UI pages for viewing requests.
  """
  use EchoWeb, :html

  embed_templates "ui_html/*"

  def format_timestamp(timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_string()
  end

  def format_json(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, data} -> Jason.encode!(data, pretty: true)
      {:error, _} -> json_string
    end
  end

  def format_json(data), do: inspect(data, pretty: true)

  def truncate_string(string, max_length \\ 100) do
    if String.length(string) > max_length do
      String.slice(string, 0, max_length) <> "..."
    else
      string
    end
  end

  def method_badge_class(method) do
    case String.upcase(method) do
      "GET" -> "bg-green-100 text-green-800"
      "POST" -> "bg-blue-100 text-blue-800"
      "PUT" -> "bg-yellow-100 text-yellow-800"
      "PATCH" -> "bg-orange-100 text-orange-800"
      "DELETE" -> "bg-red-100 text-red-800"
      _ -> "bg-gray-100 text-gray-800"
    end
  end
end
