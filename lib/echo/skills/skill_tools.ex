defmodule Echo.Skills.SkillTools do
  @moduledoc """
  Turns a skill's stored tool *names* into the declarations
  `Echo.Agents.ConversationManager.start_conversation/1` wants.

  Echo's own tools go through `Echo.Agents.Tools.tool_config/2`, which renders
  one canonical declaration into whichever dialect the provider speaks.
  Provider built-ins cannot: `google_search` and `openrouter:web_search` are
  different services reached differently and reporting differently, not two
  spellings of one capability. So each provider's set, and each set's shape, is
  listed here.

  That list is duplicated from `EchoWeb.AgentChatController`, which is where it
  lived first. The right long-term home is a `builtin_tools/0` callback on
  `Echo.Agents.Provider`; that is a behaviour change with two implementations,
  so it is deliberately not being made here. When a third consumer appears,
  make it.
  """

  alias Echo.Agents.Providers.Gemini
  alias Echo.Agents.Providers.OpenRouter
  alias Echo.Agents.Tools

  # Gemini declares its own tools as empty objects; OpenRouter as typed server
  # tools it resolves itself, whose results come back as `annotations` rather
  # than as tool calls Echo runs.
  @builtins %{
    Gemini => %{
      "google_search" => %{"google_search" => %{}},
      "url_context" => %{"url_context" => %{}}
    },
    OpenRouter => %{
      "openrouter:web_search" => %{"type" => "openrouter:web_search"},
      "openrouter:web_fetch" => %{"type" => "openrouter:web_fetch"}
    }
  }

  @doc """
  Built-in tool names this provider offers.
  """
  def builtin_names(provider_module) do
    @builtins |> Map.get(provider_module, %{}) |> Map.keys() |> Enum.sort()
  end

  @doc """
  Every name a skill on this provider may declare.

  This is the allow-list a skill's `tools` column is validated against, which is
  also what keeps `run_elixir` and the skill-writing tools out of a skill's own
  list: they are not registered in `Echo.Agents.Tools` and are not built-ins, so
  they are rejected by construction rather than by a denylist.
  """
  def known_names(provider_module), do: Tools.names() ++ builtin_names(provider_module)

  @doc """
  Renders a skill's `tool_config` into the `tools` conversation opt, or `nil`
  when there are none.

  `nil` rather than `[]` on purpose: an empty tools list is not the same as no
  tools -- sending `"tools": []` to a model that cannot use tools at all makes
  Gemini fail.

  Only the names matter here. What each tool is *allowed* to do travels
  separately, on the conversation's own `tool_config`, because it is Echo's
  business and not the model's.
  """
  def render(tool_config, provider_module \\ Gemini)
  def render(nil, _provider_module), do: nil
  def render(tool_config, _provider_module) when tool_config == %{}, do: nil

  def render(tool_config, provider_module) when is_map(tool_config),
    do: render(Map.keys(tool_config), provider_module)

  def render([], _provider_module), do: nil

  def render(names, provider_module) when is_list(names) do
    builtin_map = Map.get(@builtins, provider_module, %{})

    builtins =
      names
      |> Enum.filter(&Map.has_key?(builtin_map, &1))
      |> Enum.map(&Map.fetch!(builtin_map, &1))

    # `tool_config/2` returns a map on Gemini, a list on OpenRouter, and nil
    # when nothing matched. `List.wrap/1` flattens all three.
    echo_tools =
      names
      |> Enum.filter(&(&1 in Tools.names()))
      |> Tools.declarations(provider_module)
      |> List.wrap()

    case builtins ++ echo_tools do
      [] -> nil
      list -> list
    end
  end
end
