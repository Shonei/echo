defmodule Echo.AuthUser do
  use GenServer

  @name __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  def init(state) do
    {:ok, state}
  end

  @doc """
  Stores a token with its time-to-live (in seconds).
  """
  def login(token, ttl) do
    expiry = System.system_time(:second) + ttl
    GenServer.call(@name, {:login, token, expiry})
  end

  @doc """
  Validates if a token exists and hasn't expired.
  Returns :ok if valid, {:error, :unauthorized} otherwise.
  """
  def validate_token(token) do
    GenServer.call(@name, {:validate, token})
  end

  # Callbacks

  def handle_call({:login, token, expiry}, _from, state) do
    new_state = Map.put(state, token, expiry)
    {:reply, :ok, new_state}
  end

  def handle_call({:validate, token}, _from, state) do
    case Map.get(state, token) do
      nil ->
        {:reply, {:error, :unauthorized}, state}

      expiry ->
        if System.system_time(:second) < expiry do
          {:reply, :ok, state}
        else
          # Optionally clean up expired token
          new_state = Map.delete(state, token)
          {:reply, {:error, :unauthorized}, new_state}
        end
    end
  end
end
