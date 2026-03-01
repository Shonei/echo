defmodule Server do
  use GenServer
  def start_link(id), do: GenServer.start_link(__MODULE__, id)
  def init(id), do: {:ok, id}
end

{:ok, _sup} = DynamicSupervisor.start_link(name: DS, strategy: :one_for_one)
res1 = DynamicSupervisor.start_child(DS, {Server, 1})
res2 = DynamicSupervisor.start_child(DS, {Server, 2})
IO.inspect(res1, label: "res1")
IO.inspect(res2, label: "res2")
