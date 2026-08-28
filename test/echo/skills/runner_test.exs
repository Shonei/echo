defmodule Echo.Skills.RunnerTest do
  # async: false -- FakeHTTPClient's stub lives in the application environment,
  # because the process that sets it is not the one that makes the call.
  use Echo.DataCase, async: false

  alias Echo.Agents.Providers.Gemini
  alias Echo.FakeHTTPClient
  alias Echo.Skills
  alias Echo.Skills.Runner

  setup do
    FakeHTTPClient.reset()
    previous = Application.get_env(:echo, Gemini, [])

    Application.put_env(
      :echo,
      Gemini,
      Keyword.merge(previous, api_key: "test-key", http_client: FakeHTTPClient)
    )

    on_exit(fn ->
      Application.put_env(:echo, Gemini, previous)
      FakeHTTPClient.reset()
    end)
  end

  defp stub_reply(text) do
    FakeHTTPClient.stub(%{
      "candidates" => [
        %{"content" => %{"parts" => [%{"text" => text}]}, "finishReason" => "STOP"}
      ]
    })
  end

  describe "execute/1" do
    test "runs a skill and records the outcome" do
      stub_reply("done")
      run = run_fixture(skill_fixture())

      Runner.execute(run.id)

      run = Skills.get_run!(run.id)
      assert run.status == "succeeded"
      assert run.result == "done"
      assert run.session_id
      assert run.started_at
      assert run.finished_at
      assert run.error == nil
    end

    test "leaves a conversation readable at /ai-messages" do
      stub_reply("done")
      run = run_fixture(skill_fixture(instructions: "Do the thing."))

      Runner.execute(run.id)
      run = Skills.get_run!(run.id)

      assert Echo.Agent.get_conversation(run.session_id)
      rows = Echo.Agent.list_messages_by_session(run.session_id)
      assert Enum.any?(rows, &(&1.role == "system" and &1.content == "Do the thing."))
      assert Enum.any?(rows, &(&1.role == "user"))
    end

    test "the skill's markdown becomes the system prompt verbatim" do
      stub_reply("ok")
      run = run_fixture(skill_fixture(instructions: "Fetch the releases."))

      Runner.execute(run.id)

      prompt = FakeHTTPClient.last_request().body["systemInstruction"]["parts"]
      assert [%{"text" => "Fetch the releases."}] = prompt
    end

    test "declared variables are described to the model; their values are not" do
      stub_reply("ok")
      skill = skill_fixture(instructions: "Report on the repo.")
      variable_fixture(skill, %{name: "repo_name", description: "which repo", value: "echo-srv"})
      run = run_fixture(skill)

      Runner.execute(run.id)

      prompt = FakeHTTPClient.last_request().body["systemInstruction"]["parts"] |> hd()
      assert prompt["text"] =~ "$.repo_name"
      assert prompt["text"] =~ "which repo"
      refute prompt["text"] =~ "echo-srv"
    end

    test "tools are rendered for the provider, not copied from the column" do
      stub_reply("ok")
      skill = skill_fixture(tools: ["http_request"])
      run = run_fixture(skill)

      Runner.execute(run.id)

      assert [%{"functionDeclarations" => declarations}] =
               FakeHTTPClient.last_request().body["tools"]

      assert Enum.any?(declarations, &(&1["name"] == "http_request"))
      # The column still holds names, never declarations.
      assert Skills.get_skill!(skill.id).tools == ["http_request"]
    end

    test "no tools sends no tools key at all, because [] breaks Gemini" do
      stub_reply("ok")
      run = run_fixture(skill_fixture(tools: []))

      Runner.execute(run.id)

      refute Map.has_key?(FakeHTTPClient.last_request().body, "tools")
    end

    test "an empty input still sends a non-empty first message" do
      stub_reply("ok")
      run = run_fixture(skill_fixture(), %{"input" => %{}})

      Runner.execute(run.id)

      [user_turn] =
        FakeHTTPClient.last_request().body["contents"]
        |> Enum.filter(&(&1["role"] == "user"))

      assert [%{"text" => text}] = user_turn["parts"]
      assert text != ""
    end

    test "a bare message input is sent verbatim" do
      stub_reply("ok")
      run = run_fixture(skill_fixture(), %{"input" => %{"message" => "summarise this"}})

      Runner.execute(run.id)

      assert %{"parts" => [%{"text" => "summarise this"}]} =
               FakeHTTPClient.last_request().body["contents"] |> List.last()
    end

    test "a payload input is framed as material, not instructions" do
      stub_reply("ok")
      run = run_fixture(skill_fixture(), %{"input" => %{"issue" => 42, "title" => "Bug"}})

      Runner.execute(run.id)

      text =
        FakeHTTPClient.last_request().body["contents"]
        |> List.last()
        |> get_in(["parts", Access.at(0), "text"])

      assert text =~ "<input>"
      assert text =~ "42"
      assert text =~ "material to act on"
    end

    test "a run's own input is substituted into the instructions" do
      stub_reply("ok")
      skill = skill_fixture(instructions: "Review the repo. $.instructions")
      run = run_fixture(skill, %{"input" => %{"instructions" => "focus on security"}})

      Runner.execute(run.id)

      prompt = FakeHTTPClient.last_request().body["systemInstruction"]["parts"] |> hd()
      assert prompt["text"] =~ "Review the repo. focus on security"
    end

    test "an input key consumed by the prompt is not repeated as a message" do
      stub_reply("ok")
      skill = skill_fixture(instructions: "Do it. $.instructions")
      run = run_fixture(skill, %{"input" => %{"instructions" => "carefully"}})

      Runner.execute(run.id)

      [user_turn] =
        FakeHTTPClient.last_request().body["contents"] |> Enum.filter(&(&1["role"] == "user"))

      refute get_in(user_turn, ["parts", Access.at(0), "text"]) =~ "carefully"
    end

    test "an input key the prompt did not use still becomes the first message" do
      stub_reply("ok")
      skill = skill_fixture(instructions: "Do it. $.instructions")

      run =
        run_fixture(skill, %{
          "input" => %{"instructions" => "was-consumed", "extra" => "left-over"}
        })

      Runner.execute(run.id)

      text =
        FakeHTTPClient.last_request().body["contents"]
        |> List.last()
        |> get_in(["parts", Access.at(0), "text"])

      assert text =~ "left-over"
      refute text =~ "was-consumed"
    end

    test "a skill variable's placeholder survives into the prompt untouched" do
      stub_reply("ok")
      skill = skill_fixture(instructions: "Report on $.repo_name.")
      variable_fixture(skill, %{name: "repo_name", value: "echo-srv"})
      run = run_fixture(skill)

      Runner.execute(run.id)

      prompt = FakeHTTPClient.last_request().body["systemInstruction"]["parts"] |> hd()
      # A variable resolves inside a tool call and nowhere else, so the value
      # never reaches the system prompt -- which is stored once and replayed
      # into every later request.
      assert prompt["text"] =~ "Report on $.repo_name."
      refute prompt["text"] =~ "echo-srv"
    end

    test "run input cannot write over a declared variable's placeholder" do
      stub_reply("ok")
      skill = skill_fixture(instructions: "Use $.token now.")
      variable_fixture(skill, %{name: "token", kind: "secret", value: "ghp_real"})
      run = run_fixture(skill, %{"input" => %{"token" => "attacker supplied"}})

      Runner.execute(run.id)

      prompt = FakeHTTPClient.last_request().body["systemInstruction"]["parts"] |> hd()
      assert prompt["text"] =~ "Use $.token now."
      refute prompt["text"] =~ "attacker supplied"
    end

    test "a secret reaches the tool and is scrubbed back out of its result" do
      skill = skill_fixture(tools: ["http_request"])
      variable_fixture(skill, %{name: "internal_host", kind: "secret", value: "localhost"})
      run = run_fixture(skill)

      call = %{
        "functionCall" => %{
          "name" => "http_request",
          "args" => %{"url" => "http://$.internal_host/status"}
        }
      }

      FakeHTTPClient.stub_sequence([
        %{"candidates" => [%{"content" => %{"parts" => [call]}, "finishReason" => "STOP"}]},
        %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => "done"}]}, "finishReason" => "STOP"}
          ]
        }
      ])

      Runner.execute(run.id)
      session_id = Skills.get_run!(run.id).session_id
      rows = Echo.Agent.list_messages_by_session(session_id)

      # `validate_url/1` refuses a loopback host without touching the network,
      # and quotes the host it refused -- so the tool's own error is proof the
      # resolved value reached it, and that the scrubber took it back out.
      call_row = Enum.find(rows, &(&1.type == "functionCall"))
      response_row = Enum.find(rows, &(&1.type == "functionResponse"))

      assert call_row.payload["args"]["url"] == "http://$.internal_host/status"
      assert response_row.payload["response"]["error"] =~ "$.internal_host"
      refute response_row.payload["response"]["error"] =~ "localhost"
    end

    test "a config value is not scrubbed, because that would corrupt results" do
      skill = skill_fixture(tools: ["http_request"])
      variable_fixture(skill, %{name: "internal_host", value: "localhost"})
      run = run_fixture(skill)

      call = %{
        "functionCall" => %{
          "name" => "http_request",
          "args" => %{"url" => "http://$.internal_host/status"}
        }
      }

      FakeHTTPClient.stub_sequence([
        %{"candidates" => [%{"content" => %{"parts" => [call]}, "finishReason" => "STOP"}]},
        %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => "done"}]}, "finishReason" => "STOP"}
          ]
        }
      ])

      Runner.execute(run.id)
      session_id = Skills.get_run!(run.id).session_id

      response_row =
        session_id
        |> Echo.Agent.list_messages_by_session()
        |> Enum.find(&(&1.type == "functionResponse"))

      assert response_row.payload["response"]["error"] =~ "localhost"
    end

    test "a model error fails the run and says why" do
      FakeHTTPClient.stub({:ok, %{status: 500, body: "boom"}})
      run = run_fixture(skill_fixture())

      Runner.execute(run.id)

      run = Skills.get_run!(run.id)
      assert run.status == "failed"
      assert run.error =~ "api_error"
      assert run.finished_at
      assert run.result == nil
    end

    test "an unbound required variable fails before the first model call" do
      stub_reply("should never be sent")
      skill = skill_fixture()
      variable_fixture(skill, %{name: "api_key", kind: "secret", required: true})
      run = run_fixture(skill)

      Runner.execute(run.id)

      run = Skills.get_run!(run.id)
      assert run.status == "failed"
      assert run.error =~ "api_key"
      assert run.session_id == nil
      # The point of checking early: no turn was burned.
      assert FakeHTTPClient.requests() == []
    end

    test "an exception still leaves the row terminal, never running" do
      run = run_fixture(skill_fixture())

      # A provider the changeset would have rejected, written straight to the
      # row -- the shape a bad migration or a hand-edit leaves behind. Deleting
      # the skill would not do: that cascades and takes the run with it.
      Repo.update_all(from(s in Skills.Skill, where: s.id == ^run.skill_id),
        set: [provider: "hal9000"]
      )

      Runner.execute(run.id)

      run = Skills.get_run!(run.id)
      assert run.status == "failed"
      assert run.finished_at
    end
  end

  describe "run_skill/2" do
    test "returns a queued run immediately and the task finishes it" do
      stub_reply("done")
      skill = skill_fixture()

      assert {:ok, run} = Skills.run_skill(skill, %{})
      assert run.status == "queued"
      assert run.session_id == nil

      finished = wait_for_terminal(run.id)
      assert finished.status == "succeeded"
      assert finished.result == "done"
    end

    test "refuses before inserting a row when a required variable is unbound" do
      skill = skill_fixture()
      variable_fixture(skill, %{name: "api_key", required: true})

      assert {:error, {:unbound_variables, ["api_key"]}} = Skills.run_skill(skill, %{})
      assert Skills.list_runs(skill) == []
      assert FakeHTTPClient.requests() == []
    end
  end

  # A test must never end with a task still in flight: the stub is global, and
  # the next test's reset/0 would pull the rug out and blame the wrong test.
  defp wait_for_terminal(run_id, attempts \\ 100) do
    run = Skills.get_run!(run_id)

    cond do
      run.status in ~w(succeeded failed awaiting_approval) -> run
      attempts > 0 -> Process.sleep(10) && wait_for_terminal(run_id, attempts - 1)
      true -> flunk("run #{run_id} never reached a terminal status (#{run.status})")
    end
  end
end
