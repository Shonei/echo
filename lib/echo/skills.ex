defmodule Echo.Skills do
  @moduledoc """
  The Skills context.

  A skill is a preset in a row — instructions, tool names, generation config —
  that can be run without a person at a keyboard. A run starts an ordinary
  conversation, so everything a run does is readable at `/ai-messages` like any
  other; `skill_runs` is the index and the log, not a second record of the work.

  """

  import Ecto.Query, warn: false

  alias Echo.Repo
  alias Echo.Skills.Run
  alias Echo.Skills.Skill
  alias Echo.Skills.Variable
  alias Echo.Skills.Variables

  # --- Skills ---

  @doc """
  Returns the list of skills, newest first.

  Accepts an optional `:enabled` filter.
  """
  def list_skills(params \\ %{}) do
    Skill
    |> build_skill_search(params)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  defp build_skill_search(query, filters) do
    Enum.reduce(filters, query, fn
      {:enabled, enabled}, query when is_boolean(enabled) ->
        from s in query, where: s.enabled == ^enabled

      _filter, query ->
        query
    end)
  end

  @doc """
  Gets a single skill. Raises `Ecto.NoResultsError` if it does not exist.
  """
  def get_skill!(id), do: Repo.get!(Skill, id)

  @doc """
  Gets a single skill, or `nil`.
  """
  def get_skill(id), do: Repo.get(Skill, id)

  @doc """
  Gets a skill by id or slug.

  A numeric identifier is tried as an id first and then as a slug, so a skill
  whose slug happens to be all digits stays reachable — the same rule
  `Echo.Content.get_blog_by_id_or_slug!/1` follows.
  """
  def get_skill_by_id_or_slug!(identifier) do
    case Integer.parse(identifier) do
      {id, ""} -> Repo.get(Skill, id) || Repo.get_by!(Skill, slug: identifier)
      _ -> Repo.get_by!(Skill, slug: identifier)
    end
  end

  @doc """
  Gets a skill by slug, or `nil`.
  """
  def get_skill_by_slug(slug), do: Repo.get_by(Skill, slug: slug)

  @doc """
  Creates a skill. The only path that can set `provider`.
  """
  def create_skill(attrs \\ %{}) do
    %Skill{}
    |> Skill.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a skill's metadata.

  A `provider` or `instructions` key in `attrs` is ignored: the provider is
  fixed at creation, and the body is saved through
  `update_skill_instructions/2`.
  """
  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a skill's markdown body.
  """
  def update_skill_instructions(%Skill{} = skill, instructions) do
    skill
    |> Skill.instructions_changeset(%{instructions: instructions})
    |> Repo.update()
  end

  @doc """
  Deletes a skill, and with it its runs and variables.
  """
  def delete_skill(%Skill{} = skill), do: Repo.delete(skill)

  @doc """
  Returns a changeset for tracking skill changes.
  """
  def change_skill(%Skill{} = skill, attrs \\ %{}), do: Skill.create_changeset(skill, attrs)

  # --- Variables ---

  @doc """
  A skill's declared variables, in display order.
  """
  def list_variables(%Skill{} = skill) do
    Repo.all(from v in Variable, where: v.skill_id == ^skill.id, order_by: [asc: v.position])
  end

  @doc """
  Replaces a skill's whole declaration set.

  Declarative rather than a sequence of add/update/remove calls, because that is
  easier for an agent to get right than a sequence of add/update/remove calls,
  and it is idempotent on a retry.

  Values survive for any variable whose `name` is unchanged — the row is
  updated, and `declaration_changeset/2` does not cast `value`, so a value is
  never in the changeset to be lost. A variable that disappears takes its value
  with it.

  One narrow exception: redeclaring a `secret` as a `config` clears the value.
  This path is reachable by an agent, which could otherwise expose a stored
  secret through the API by rewriting its kind. Going the other way keeps the
  value, since that only ever adds protection.

  `position` comes from list order, so ordering is a property of the call.

  Returns which bindings were dropped and which required variables are now
  unbound, so a caller can tell the operator what still needs filling in.
  """
  def define_variables(%Skill{} = skill, declarations) when is_list(declarations) do
    Repo.transaction(fn ->
      existing = Map.new(list_variables(skill), &{&1.name, &1})
      incoming = Enum.map(declarations, &stringify/1)
      names = Enum.map(incoming, &Map.get(&1, "name"))

      dropped =
        existing
        |> Enum.filter(fn {name, variable} -> name not in names and bound?(variable) end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      Repo.delete_all(from v in Variable, where: v.skill_id == ^skill.id and v.name not in ^names)

      variables =
        incoming
        |> Enum.with_index()
        |> Enum.map(fn {attrs, index} ->
          base = Map.get(existing, Map.get(attrs, "name")) || %Variable{skill_id: skill.id}

          base
          |> Variable.declaration_changeset(Map.put(attrs, "position", index))
          |> clear_binding_on_kind_change(base)
          |> Repo.insert_or_update()
          |> case do
            {:ok, variable} -> variable
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      %{
        variables: variables,
        dropped_bindings: dropped,
        unbound: for(v <- variables, v.required and not bound?(v), do: v.name)
      }
    end)
  end

  # Only ever clears a value, never sets one, so the write split still holds.
  # Only secret-to-config: the other direction cannot expose anything.
  defp clear_binding_on_kind_change(changeset, %Variable{kind: "secret"}) do
    case Ecto.Changeset.get_change(changeset, :kind) do
      nil -> changeset
      "secret" -> changeset
      _downgraded -> Ecto.Changeset.force_change(changeset, :value, nil)
    end
  end

  defp clear_binding_on_kind_change(changeset, _base), do: changeset

  defp bound?(%Variable{value: value}), do: not is_nil(value)

  defp stringify(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  @doc """
  Gives a variable its value.

  Operator-only. No agent tool reaches this — see `Echo.Skills.Variable`.
  """
  def bind_variable(%Skill{} = skill, name, attrs) do
    case Repo.get_by(Variable, skill_id: skill.id, name: name) do
      nil ->
        {:error, :not_found}

      variable ->
        variable
        |> Variable.binding_changeset(attrs)
        |> Repo.update()
    end
  end

  # --- Runs ---

  @doc """
  Queues a run and returns immediately. Never waits for the model.

  The existing message path blocks for up to 300s
  (`Echo.Agents.ConversationManager.message/3`), which is fine for a person at a
  keyboard and useless for a webhook — so the caller gets a run id and reads the
  outcome from the row, or from the conversation at `/ai-messages`.

  Required variables are resolved *before* the row is inserted. That is what
  lets the API answer 422 with the missing names rather than 202 and a row the
  caller has to poll to discover was doomed. `Echo.Skills.Runner` checks again,
  because a binding can be removed between the two.

  `enabled` is deliberately not consulted, so a skill can be taken off its
  schedule and still be run by hand. Triggers are what check it.
  """
  def run_skill(%Skill{} = skill, input \\ %{}) when is_map(input) do
    skill = Repo.preload(skill, :variables)

    with :ok <- Variables.check_required(skill),
         {:ok, run} <- insert_run(skill, input),
         {:ok, _pid} <- Echo.Skills.Runner.start(run) do
      {:ok, run}
    else
      {:error, {:unbound_variables, names}} -> {:error, {:unbound_variables, names}}
      {:error, :max_children} -> {:error, :too_many_runs}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp insert_run(%Skill{} = skill, input) do
    %Run{skill_id: skill.id}
    |> Run.create_changeset(%{"input" => input, "status" => "queued"})
    |> Repo.insert()
  end

  @doc """
  A skill's runs, newest first. Accepts `:limit`.
  """
  def list_runs(%Skill{} = skill, opts \\ []) do
    query = from r in Run, where: r.skill_id == ^skill.id, order_by: [desc: r.id]

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> from r in query, limit: ^limit
      end

    Repo.all(query)
  end

  @doc """
  Gets a run. Raises `Ecto.NoResultsError` if it does not exist.
  """
  def get_run!(id), do: Repo.get!(Run, id)

  @doc """
  Gets a run, or `nil`.
  """
  def get_run(id), do: Repo.get(Run, id)

  @doc """
  Gets a run scoped to its skill, so a nested route cannot read another
  skill's run by guessing an id.
  """
  def get_run_for_skill!(%Skill{} = skill, id), do: Repo.get_by!(Run, id: id, skill_id: skill.id)

  @doc """
  The run a conversation belongs to, or `nil` for a conversation with no skill
  behind it — which the plain agent chat is.
  """
  def get_run_by_session(session_id) when is_binary(session_id),
    do: Repo.get_by(Run, session_id: session_id)

  def get_run_by_session(_session_id), do: nil

  @doc """
  Records that a run's conversation exists and work has started.
  """
  def mark_running(%Run{} = run, session_id) do
    run
    |> Run.progress_changeset(%{
      "status" => "running",
      "session_id" => session_id,
      "started_at" => DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  @doc """
  Moves a run to a terminal state. `attrs` carries `:result` or `:error`.
  """
  def finish_run(%Run{} = run, status, attrs \\ []) do
    base = %{
      "status" => status,
      "finished_at" => DateTime.utc_now() |> DateTime.truncate(:second)
    }

    run
    |> Run.progress_changeset(Map.merge(base, stringify(Map.new(attrs))))
    |> Repo.update()
  end
end
