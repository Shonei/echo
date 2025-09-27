defmodule Echo.AIUserRegistry do
  @moduledoc """
  GenServer that maintains a registry of all AI users from the database.

  This registry keeps track of AI users and their metadata (model, system_props)
  to enable efficient lookup when processing @username mentions in chat messages.
  """

  use GenServer
  require Logger

  alias Echo.Accounts
  alias Echo.Accounts.User

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, opts ++ [name: __MODULE__])
  end

  @doc """
  Gets all AI users from the registry.

  Returns a map where keys are usernames and values are user structs with decoded metadata.
  """
  def get_all_ai_users do
    GenServer.call(__MODULE__, :get_all_ai_users)
  end

  @doc """
  Gets a specific AI user by username.

  Returns the user struct with decoded metadata, or nil if not found.
  """
  def get_ai_user(username) do
    GenServer.call(__MODULE__, {:get_ai_user, username})
  end

  @doc """
  Checks if a username belongs to an AI user.
  """
  def is_ai_user?(username) do
    GenServer.call(__MODULE__, {:is_ai_user, username})
  end

  @doc """
  Adds or updates an AI user in the registry.

  This should be called when a new AI user is created or updated.
  """
  def add_or_update_ai_user(%User{type: "ai"} = user) do
    GenServer.cast(__MODULE__, {:add_or_update_ai_user, user})
  end

  def add_or_update_ai_user(_user), do: :ok

  @doc """
  Removes an AI user from the registry.

  This should be called when an AI user is deleted or changed to non-AI type.
  """
  def remove_ai_user(username) do
    GenServer.cast(__MODULE__, {:remove_ai_user, username})
  end

  @doc """
  Reloads all AI users from the database.

  This can be used to refresh the registry if needed.
  """
  def reload_ai_users do
    GenServer.cast(__MODULE__, :reload_ai_users)
  end

  @doc """
  Finds AI users mentioned in a message content.

  Returns a list of AI user structs that are mentioned with @username in the content.
  """
  def find_mentioned_ai_users(content) do
    GenServer.call(__MODULE__, {:find_mentioned_ai_users, content})
  end

  # Server Callbacks

  @impl true
  def init(:ok) do
    # Load all AI users from database on startup
    ai_users = load_ai_users_from_db()

    Logger.info("AI User Registry started with #{map_size(ai_users)} AI users")

    {:ok, %{ai_users: ai_users}}
  end

  @impl true
  def handle_call(:get_all_ai_users, _from, state) do
    {:reply, state.ai_users, state}
  end

  @impl true
  def handle_call({:get_ai_user, username}, _from, state) do
    user = Map.get(state.ai_users, username)
    {:reply, user, state}
  end

  @impl true
  def handle_call({:is_ai_user, username}, _from, state) do
    is_ai = Map.has_key?(state.ai_users, username)
    {:reply, is_ai, state}
  end

  @impl true
  def handle_call({:find_mentioned_ai_users, content}, _from, state) do
    mentioned_users = find_mentioned_users_in_content(content, state.ai_users)
    {:reply, mentioned_users, state}
  end

  @impl true
  def handle_cast({:add_or_update_ai_user, user}, state) do
    # Decode metadata for the user
    user_with_metadata = %{user | metadata: User.decode_metadata(user)}

    new_ai_users = Map.put(state.ai_users, user.username, user_with_metadata)

    Logger.info("Added/updated AI user in registry: #{user.username}")

    {:noreply, %{state | ai_users: new_ai_users}}
  end

  @impl true
  def handle_cast({:remove_ai_user, username}, state) do
    new_ai_users = Map.delete(state.ai_users, username)

    Logger.info("Removed AI user from registry: #{username}")

    {:noreply, %{state | ai_users: new_ai_users}}
  end

  @impl true
  def handle_cast(:reload_ai_users, state) do
    ai_users = load_ai_users_from_db()

    Logger.info("Reloaded AI users registry with #{map_size(ai_users)} AI users")

    {:noreply, %{state | ai_users: ai_users}}
  end

  # Private functions

  defp load_ai_users_from_db do
    Accounts.list_ai_users()
    |> Enum.map(fn user ->
      # Decode metadata for efficient access
      user_with_metadata = %{user | metadata: User.decode_metadata(user)}
      {user.username, user_with_metadata}
    end)
    |> Map.new()
  end

  defp find_mentioned_users_in_content(content, ai_users) do
    # Find all @username mentions in the content
    mentions = Regex.scan(~r/@(\w+)/, content, capture: :all_but_first)

    # Extract usernames and check if they're AI users
    mentions
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.filter(fn username -> Map.has_key?(ai_users, username) end)
    |> Enum.map(fn username -> Map.get(ai_users, username) end)
  end
end
