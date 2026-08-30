defmodule EchoWeb.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  See `Phoenix.Controller.action_fallback/1` for more details.
  """
  use EchoWeb, :controller

  # This clause handles errors returned by Ecto's insert/update/delete.
  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: EchoWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  # This clause is an example of how to handle resources that cannot be found.
  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: EchoWeb.ErrorHTML, json: EchoWeb.ErrorJSON)
    |> render(:"404")
  end

  # This clause handles a required top-level key missing from the request body.
  def call(conn, {:error, :missing_param, param}) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{param => ["is required"]}})
  end

  # A run cannot start with a required variable unbound. Reported with the names
  # rather than as a 202 the caller has to poll to discover failed.
  def call(conn, {:error, {:unbound_variables, names}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{variables: Enum.map(names, &"#{&1} is required but unbound")}})
  end

  # A run's `input` must be an object; it becomes the run's first message.
  def call(conn, {:error, :invalid_input}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{input: ["must be an object"]}})
  end

  # Echo.Skills.RunSupervisor is at max_children.
  def call(conn, {:error, :too_many_runs}) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{errors: %{run: ["too many runs are already in flight"]}})
  end

  # This clause handles invalid tags format errors.
  def call(conn, {:error, :invalid_tags}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: EchoWeb.ErrorJSON)
    |> json(%{errors: %{tags: ["must be an empty object or a map of string/string values"]}})
  end
end
