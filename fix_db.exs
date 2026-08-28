Application.ensure_all_started(:echo)
import Ecto.Query

Echo.Agent.Message
|> where([m], m.type == "unknown")
|> Echo.Repo.all()
|> Enum.each(fn msg ->
  if Map.has_key?(msg.payload || %{}, "toolCall") do
    msg
    |> Ecto.Changeset.change(type: "toolCall")
    |> Echo.Repo.update!()
  end

  if Map.has_key?(msg.payload || %{}, "toolResponse") do
    msg
    |> Ecto.Changeset.change(type: "toolResponse")
    |> Echo.Repo.update!()
  end
end)

IO.puts("Fixed historical DB records")
