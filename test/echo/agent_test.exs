defmodule Echo.AgentTest do
  use Echo.DataCase, async: true

  alias Echo.Agent
  alias Echo.Agent.ConversationRecord

  describe "create_conversation/2" do
    test "persists the config and the one system-prompt message" do
      id = unique("convo")

      assert {:ok, %ConversationRecord{} = record} =
               Agent.create_conversation(id, %{
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

      assert {:ok, _record} = Agent.create_conversation(id)
      assert Agent.list_messages_by_session(id) == []
    end

    test "accepts atom keys too" do
      id = unique("convo")

      assert {:ok, record} = Agent.create_conversation(id, %{model: "gemini-3.7-flash"})

      assert record.model == "gemini-3.7-flash"
    end

    test "the id argument always wins, even if opts also carries a session_id" do
      id = unique("convo")
      other_id = unique("other-convo")

      assert {:ok, record} = Agent.create_conversation(id, %{session_id: other_id})

      assert record.session_id == id
      assert Agent.get_conversation(other_id) == nil
    end
  end

  describe "get_conversation/1" do
    test "returns the record, or nil once deleted" do
      id = unique("convo")
      {:ok, _record} = Agent.create_conversation(id)

      assert %ConversationRecord{session_id: ^id} = Agent.get_conversation(id)

      Agent.delete_conversation(id)

      assert Agent.get_conversation(id) == nil
    end
  end

  describe "delete_conversation/1" do
    test "leaves message history alone" do
      id = unique("convo")
      {:ok, _record} = Agent.create_conversation(id, %{"system_prompt" => "hi"})

      Agent.delete_conversation(id)

      assert Agent.get_conversation(id) == nil
      assert [%{role: "system"}] = Agent.list_messages_by_session(id)
    end

    test "is a no-op for an id that never existed" do
      assert Agent.delete_conversation(unique("convo")) == :ok
    end
  end

  describe "list_conversations/0" do
    test "flags a conversation as resumable only while its durable record exists" do
      id = unique("convo")
      {:ok, _record} = Agent.create_conversation(id, %{"system_prompt" => "hi"})

      assert %{resumable: true} = Enum.find(Agent.list_conversations(), &(&1.session_id == id))

      Agent.delete_conversation(id)

      assert %{resumable: false} = Enum.find(Agent.list_conversations(), &(&1.session_id == id))
    end
  end
end
