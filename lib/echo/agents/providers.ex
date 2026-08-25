defmodule Echo.Agents.Providers do
  @moduledoc """
  Resolves a provider name to the module implementing `Echo.Agents.Provider`.

  A conversation's provider is fixed when it's created and stored on its
  `Echo.Agent.ConversationRecord`, so it survives the process being restarted
  or a redeploy wiping the registry. Nothing here is per-turn.
  """

  alias Echo.Agents.Providers.Gemini
  alias Echo.Agents.Providers.OpenRouter

  @providers %{
    "gemini" => Gemini,
    "openrouter" => OpenRouter
  }

  @default Gemini

  @doc """
  The provider used when a caller doesn't name one.

  Blogs (the only real client) never sends `provider`, so this is what keeps
  every existing conversation on Gemini, unchanged.
  """
  def default, do: @default

  @doc """
  Every provider name that can be requested.
  """
  def names, do: Map.keys(@providers)

  @doc """
  Resolves a provider name. `nil` means "the default", not "invalid".

      iex> Echo.Agents.Providers.resolve("openrouter")
      {:ok, Echo.Agents.Providers.OpenRouter}

      iex> Echo.Agents.Providers.resolve("hal9000")
      {:error, {:unknown_provider, "hal9000"}}
  """
  def resolve(nil), do: {:ok, @default}

  def resolve(name) when is_binary(name) do
    case Map.fetch(@providers, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_provider, name}}
    end
  end

  def resolve(other), do: {:error, {:unknown_provider, other}}
end
