defmodule EchoWeb.SkillUIController do
  use EchoWeb, :controller

  alias Echo.Agents.Providers
  alias Echo.Agents.Tools
  alias Echo.Skills

  require Logger

  def index(conn, _params) do
    render(conn, :index, skills: Skills.list_skills())
  end

  def show(conn, %{"id" => id}) do
    skill = Skills.get_skill_by_id_or_slug!(id)
    {:ok, provider_module} = Providers.resolve(skill.provider)

    render(conn, :show,
      skill: skill,
      variables: Skills.list_variables(skill),
      runs: Skills.list_runs(skill, limit: 20),
      grantable: Echo.Skills.SkillTools.known_names(provider_module),
      gates: ~w(never mutations always)
    )
  end

  def bind(conn, %{"id" => id, "name" => name} = params) do
    skill = Skills.get_skill_by_id_or_slug!(id)
    value = presence(params["value"])

    case Skills.bind_variable(skill, name, %{"value" => value}) do
      {:ok, _variable} ->
        conn
        |> put_flash(:info, "Saved #{name}.")
        |> redirect(to: ~p"/skills/#{skill.id}")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "No variable named #{name}.")
        |> redirect(to: ~p"/skills/#{skill.id}")

      {:error, changeset} ->
        conn
        |> put_flash(:error, "#{name}: #{errors_sentence(changeset)}")
        |> redirect(to: ~p"/skills/#{skill.id}")
    end
  end

  @doc """
  Grants tools. The form posts every tool it offered, so an unticked one is an
  absent key rather than a removal that has to be spelled out.
  """
  def grant(conn, %{"id" => id} = params) do
    skill = Skills.get_skill_by_id_or_slug!(id)
    ticked = params["tools"] || %{}

    tool_config =
      ticked
      |> Enum.filter(fn {_name, settings} -> settings["granted"] == "true" end)
      |> Map.new(fn {name, settings} -> {name, %{"gate" => settings["gate"] || "never"}} end)

    case Skills.update_skill(skill, %{"tool_config" => tool_config}) do
      {:ok, _skill} ->
        conn
        |> put_flash(:info, "Tools updated.")
        |> redirect(to: ~p"/skills/#{skill.id}")

      {:error, changeset} ->
        conn
        |> put_flash(:error, errors_sentence(changeset))
        |> redirect(to: ~p"/skills/#{skill.id}")
    end
  end

  def run(conn, %{"id" => id} = params) do
    skill = Skills.get_skill_by_id_or_slug!(id)
    input = build_input(params["instructions"])

    case Skills.run_skill(skill, input) do
      {:ok, run} ->
        conn
        |> put_flash(:info, "Run ##{run.id} started.")
        |> redirect(to: ~p"/skills/#{skill.id}")

      {:error, {:unbound_variables, names}} ->
        conn
        |> put_flash(:error, "Still waiting on a value for: #{Enum.join(names, ", ")}.")
        |> redirect(to: ~p"/skills/#{skill.id}")

      {:error, :too_many_runs} ->
        conn
        |> put_flash(:error, "Too many runs are already in flight.")
        |> redirect(to: ~p"/skills/#{skill.id}")

      {:error, changeset} ->
        conn
        |> put_flash(:error, errors_sentence(changeset))
        |> redirect(to: ~p"/skills/#{skill.id}")
    end
  end

  defp build_input(nil), do: %{}

  defp build_input(instructions) do
    case String.trim(instructions) do
      "" -> %{}
      text -> %{"instructions" => text}
    end
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp errors_sentence(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  @doc """
  Every tool name a conversation could be given, for the grant form.
  """
  def all_tool_names, do: Tools.names()
end
