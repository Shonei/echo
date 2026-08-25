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

    test "lists a conversation started without a system prompt" do
      # The bug this guards: listing used to key off a message with role
      # "system", and none is written when there's no system prompt, so these
      # conversations were invisible in the UI no matter how many turns they had.
      id = unique("convo")
      {:ok, _record} = Agent.create_conversation(id, %{"model" => "openai/gpt-5.6-luna"})

      assert %{resumable: true, content: nil} =
               Enum.find(Agent.list_conversations(), &(&1.session_id == id))
    end

    test "previews the first user message when there is no system prompt" do
      id = unique("convo")
      {:ok, _record} = Agent.create_conversation(id, %{})

      {:ok, _} =
        Agent.create_message(%{session_id: id, role: "user", type: "text", content: "hi"})

      {:ok, _} =
        Agent.create_message(%{session_id: id, role: "model", type: "text", content: "hello"})

      assert %{content: "hi", preview_role: "user", message_count: 2} =
               Enum.find(Agent.list_conversations(), &(&1.session_id == id))
    end

    test "reports the provider, treating a null one as the Gemini default" do
      gemini = unique("convo")
      openrouter = unique("convo")

      {:ok, _} = Agent.create_conversation(gemini, %{})
      {:ok, _} = Agent.create_conversation(openrouter, %{"provider" => "openrouter"})

      conversations = Agent.list_conversations()

      assert %{provider: "gemini"} = Enum.find(conversations, &(&1.session_id == gemini))
      assert %{provider: "openrouter"} = Enum.find(conversations, &(&1.session_id == openrouter))
    end

    test "keeps a deleted conversation's history listed, with an unknown provider" do
      id = unique("convo")
      {:ok, _} = Agent.create_conversation(id, %{"provider" => "openrouter"})

      {:ok, _} =
        Agent.create_message(%{session_id: id, role: "user", type: "text", content: "hi"})

      Agent.delete_conversation(id)

      # The record carried the provider, so with it gone we genuinely don't
      # know -- better blank than mislabelled as Gemini.
      assert %{resumable: false, provider: nil, content: "hi"} =
               Enum.find(Agent.list_conversations(), &(&1.session_id == id))
    end
  end
end
