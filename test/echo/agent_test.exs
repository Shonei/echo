defmodule Echo.AgentTest do
  use Echo.DataCase, async: true

  alias Echo.Agent
  alias Echo.Agent.ConversationRecord

  describe "create_conversation/1" do
    test "persists the config and the one system-prompt message" do
      id = unique("convo")

      assert {:ok, %ConversationRecord{} = record} =
               Agent.create_conversation(%{
                 "session_id" => id,
                 "system_prompt" => "be nice",
                 "temperature" => 0.2,
                 "model" => "gemini-3.7-flash",
                 "tools" => [%{"google_search" => %{}}]
               })

      assert record.session_id == id
      assert record.system_prompt == "be nice"
      assert record.temperature == 0.2
      assert record.tools == [%{"google_search" => %{}}]

      assert [%{role: "system", content: "be nice", type: "text"}] =
               Agent.list_messages_by_session(id)
    end

    test "writes no system message when no system prompt is given" do
      id = unique("convo")

      assert {:ok, _record} = Agent.create_conversation(%{"session_id" => id})
      assert Agent.list_messages_by_session(id) == []
    end

    test "accepts atom keys too" do
      id = unique("convo")

      assert {:ok, record} =
               Agent.create_conversation(%{session_id: id, model: "gemini-3.7-flash"})

      assert record.model == "gemini-3.7-flash"
    end
  end

  describe "get_conversation/1" do
    test "returns the record, or nil once deleted" do
      id = unique("convo")
      {:ok, _record} = Agent.create_conversation(%{"session_id" => id})

      assert %ConversationRecord{session_id: ^id} = Agent.get_conversation(id)

      Agent.delete_conversation(id)

      assert Agent.get_conversation(id) == nil
    end
  end

  describe "delete_conversation/1" do
    test "leaves message history alone" do
      id = unique("convo")
      {:ok, _record} = Agent.create_conversation(%{"session_id" => id, "system_prompt" => "hi"})

      Agent.delete_conversation(id)

      assert Agent.get_conversation(id) == nil
      assert [%{role: "system"}] = Agent.list_messages_by_session(id)
    end

    test "is a no-op for an id that never existed" do
      assert Agent.delete_conversation(unique("convo")) == :ok
    end
  end
end
