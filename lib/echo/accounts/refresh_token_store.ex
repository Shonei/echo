defmodule Echo.Accounts.RefreshTokenStore do
  @moduledoc """
  GenServer for storing refresh tokens in memory.
  Stores the mapping between refresh tokens and their associated user/access token info.
  Tokens are automatically cleaned up when they expire.
  """
  use GenServer

  # 30 days in milliseconds
  @cleanup_interval :timer.hours(1)

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores a refresh token with associated user and access token info.
  """
  def store(refresh_token, user_id, access_token) do
    GenServer.call(__MODULE__, {:store, refresh_token, user_id, access_token})
  end

  @doc """
  Gets the stored info for a refresh token.
  Returns {:ok, %{user_id: user_id, access_token: access_token}} or {:error, :not_found}.
  """
  def get(refresh_token) do
    GenServer.call(__MODULE__, {:get, refresh_token})
  end

  @doc """
  Invalidates (removes) a refresh token.
  """
  def invalidate(refresh_token) do
    GenServer.call(__MODULE__, {:invalidate, refresh_token})
  end

  @doc """
  Invalidates all refresh tokens for a given user.
  """
  def invalidate_all_for_user(user_id) do
    GenServer.call(__MODULE__, {:invalidate_all_for_user, user_id})
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic cleanup
    schedule_cleanup()

    # State is a map: %{refresh_token => %{user_id, access_token, expires_at}}
    {:ok, %{tokens: %{}, user_tokens: %{}}}
  end

  @impl true
  def handle_call({:store, refresh_token, user_id, access_token}, _from, state) do
    # Tokens expire in 30 days
    expires_at = DateTime.add(DateTime.utc_now(), 30 * 24 * 60 * 60, :second)

    token_info = %{
      user_id: user_id,
      access_token: access_token,
      expires_at: expires_at
    }

    # Update tokens map
    new_tokens = Map.put(state.tokens, refresh_token, token_info)

    # Update user_tokens index (user_id => list of refresh_tokens)
    user_id_str = to_string(user_id)
    existing_tokens = Map.get(state.user_tokens, user_id_str, [])
    new_user_tokens = Map.put(state.user_tokens, user_id_str, [refresh_token | existing_tokens])

    {:reply, :ok, %{state | tokens: new_tokens, user_tokens: new_user_tokens}}
  end

  @impl true
  def handle_call({:get, refresh_token}, _from, state) do
    case Map.get(state.tokens, refresh_token) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{expires_at: expires_at} = info ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:reply, {:ok, Map.take(info, [:user_id, :access_token])}, state}
        else
          # Token expired, clean it up
          new_state = remove_token(state, refresh_token, info.user_id)
          {:reply, {:error, :not_found}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:invalidate, refresh_token}, _from, state) do
    case Map.get(state.tokens, refresh_token) do
      nil ->
        {:reply, :ok, state}

      %{user_id: user_id} ->
        new_state = remove_token(state, refresh_token, user_id)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:invalidate_all_for_user, user_id}, _from, state) do
    user_id_str = to_string(user_id)

    case Map.get(state.user_tokens, user_id_str) do
      nil ->
        {:reply, :ok, state}

      tokens ->
        new_tokens = Map.drop(state.tokens, tokens)
        new_user_tokens = Map.delete(state.user_tokens, user_id_str)
        {:reply, :ok, %{state | tokens: new_tokens, user_tokens: new_user_tokens}}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()

    # Find and remove expired tokens
    {valid_tokens, expired} =
      Enum.split_with(state.tokens, fn {_token, %{expires_at: exp}} ->
        DateTime.compare(now, exp) == :lt
      end)

    new_tokens = Map.new(valid_tokens)

    # Clean up user_tokens index
    expired_token_keys = Enum.map(expired, fn {token, _} -> token end)

    new_user_tokens =
      Enum.reduce(state.user_tokens, %{}, fn {user_id, tokens}, acc ->
        remaining = Enum.reject(tokens, &(&1 in expired_token_keys))
        if remaining == [], do: acc, else: Map.put(acc, user_id, remaining)
      end)

    schedule_cleanup()
    {:noreply, %{state | tokens: new_tokens, user_tokens: new_user_tokens}}
  end

  # Private helpers

  defp remove_token(state, refresh_token, user_id) do
    user_id_str = to_string(user_id)
    new_tokens = Map.delete(state.tokens, refresh_token)

    new_user_tokens =
      Map.update(state.user_tokens, user_id_str, [], fn tokens ->
        Enum.reject(tokens, &(&1 == refresh_token))
      end)
      |> Enum.reject(fn {_k, v} -> v == [] end)
      |> Map.new()

    %{state | tokens: new_tokens, user_tokens: new_user_tokens}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end

