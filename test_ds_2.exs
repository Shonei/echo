defmodule Srv do
  use GenServer
  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
  def init(arg), do: {:ok, arg}
end

{:ok, _sup} = DynamicSupervisor.start_link(name: DS2, strategy: :one_for_one)
IO.inspect(DynamicSupervisor.start_child(DS2, {Srv, %{a: 1}}))
IO.inspect(DynamicSupervisor.start_child(DS2, {Srv, %{b: 2}}))
IO.inspect(DynamicSupervisor.start_child(DS2, {Srv, %{b: 2}}))
