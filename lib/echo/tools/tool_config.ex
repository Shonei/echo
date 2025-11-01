defmodule Echo.Tools.ToolConfig do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tool_configs" do
    field :function_type, :string
    field :http_method, :string
    field :http_url, :string
    field :description, :string
    belongs_to :user, Echo.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(tool_config, attrs) do
    tool_config
    |> cast(attrs, [:user_id, :function_type, :http_method, :http_url, :description])
    |> validate_required([:user_id, :function_type, :description])
    |> validate_inclusion(:function_type, ["calculator", "http"])
    |> validate_http_fields()
    |> foreign_key_constraint(:user_id)
  end

  defp validate_http_fields(changeset) do
    function_type = get_field(changeset, :function_type)

    case function_type do
      "http" ->
        changeset
        |> validate_required([:http_method, :http_url])
        |> validate_inclusion(:http_method, ["GET", "POST", "PUT", "PATCH", "DELETE"])
        |> validate_format(:http_url, ~r/^https?:\/\/.+/, message: "must be a valid HTTP(S) URL")

      "calculator" ->
        changeset

      _ ->
        changeset
    end
  end
end

