defmodule EchoWeb.SkillUIHTML do
  use EchoWeb, :html

  embed_templates "skill_ui_html/*"

  @doc """
  Colour for a run status, so a failure is visible without reading.
  """
  def status_class("succeeded"), do: "bg-green-100 text-green-800"
  def status_class("failed"), do: "bg-red-100 text-red-800"
  def status_class("awaiting_approval"), do: "bg-amber-100 text-amber-800"
  def status_class("running"), do: "bg-blue-100 text-blue-800"
  def status_class(_queued), do: "bg-gray-100 text-gray-800"

  @doc """
  What a variable is still waiting on, for the binding form.
  """
  def variable_state(%{required: true, value: nil}), do: {"needs a value", "text-red-600"}
  def variable_state(%{value: nil}), do: {"optional, unset", "text-gray-500"}
  def variable_state(%{kind: "secret"}), do: {"set", "text-gray-500"}
  def variable_state(_variable), do: {"set", "text-gray-500"}
end
