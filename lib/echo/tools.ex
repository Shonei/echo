defmodule Echo.Tools do
  @moduledoc """
  The Tools context.
  """

  import Ecto.Query, warn: false
  alias Echo.Repo

  alias Echo.Tools.ToolConfig

  @doc """
  Returns the list of tool_configs.

  ## Examples

      iex> list_tool_configs()
      [%ToolConfig{}, ...]

  """
  def list_tool_configs do
    Repo.all(ToolConfig)
  end

  @doc """
  Returns the list of tool_configs for a specific user.

  ## Examples

      iex> list_tool_configs_by_user(123)
      [%ToolConfig{}, ...]

  """
  def list_tool_configs_by_user(user_id) do
    ToolConfig
    |> where([t], t.user_id == ^user_id)
    |> Repo.all()
  end

  @doc """
  Returns the list of tool_configs for a specific user and function type.

  ## Examples

      iex> list_tool_configs_by_user_and_type(123, "calculator")
      [%ToolConfig{}, ...]

  """
  def list_tool_configs_by_user_and_type(user_id, function_type) do
    ToolConfig
    |> where([t], t.user_id == ^user_id and t.function_type == ^function_type)
    |> Repo.all()
  end

  @doc """
  Gets a single tool_config.

  Raises `Ecto.NoResultsError` if the Tool config does not exist.

  ## Examples

      iex> get_tool_config!(123)
      %ToolConfig{}

      iex> get_tool_config!(456)
      ** (Ecto.NoResultsError)

  """
  def get_tool_config!(id), do: Repo.get!(ToolConfig, id)

  @doc """
  Gets a single tool_config.

  Returns nil if the Tool config does not exist.

  ## Examples

      iex> get_tool_config(123)
      %ToolConfig{}

      iex> get_tool_config(456)
      nil

  """
  def get_tool_config(id), do: Repo.get(ToolConfig, id)

  @doc """
  Creates a tool_config.

  ## Examples

      iex> create_tool_config(%{field: value})
      {:ok, %ToolConfig{}}

      iex> create_tool_config(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_tool_config(attrs \\ %{}) do
    %ToolConfig{}
    |> ToolConfig.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a tool_config.

  ## Examples

      iex> update_tool_config(tool_config, %{field: new_value})
      {:ok, %ToolConfig{}}

      iex> update_tool_config(tool_config, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_tool_config(%ToolConfig{} = tool_config, attrs) do
    tool_config
    |> ToolConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a tool_config.

  ## Examples

      iex> delete_tool_config(tool_config)
      {:ok, %ToolConfig{}}

      iex> delete_tool_config(tool_config)
      {:error, %Ecto.Changeset{}}

  """
  def delete_tool_config(%ToolConfig{} = tool_config) do
    Repo.delete(tool_config)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking tool_config changes.

  ## Examples

      iex> change_tool_config(tool_config)
      %Ecto.Changeset{data: %ToolConfig{}}

  """
  def change_tool_config(%ToolConfig{} = tool_config, attrs \\ %{}) do
    ToolConfig.changeset(tool_config, attrs)
  end
end

