defmodule Echo.Agents.Tools.SkillRunsTest do
  # async: false -- FakeHTTPClient's stub lives in the application environment.
  use Echo.DataCase, async: false

  alias Echo.Agents.Providers.Gemini
  alias Echo.Agents.Tools
  alias Echo.FakeHTTPClient
  alias Echo.Skills

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

  defp run(name, args), do: Tools.backend(name).run(args)

  defp stub_reply(text) do
    FakeHTTPClient.stub(%{
      "candidates" => [
        %{"content" => %{"parts" => [%{"text" => text}]}, "finishReason" => "STOP"}
      ]
    })
  end

  describe "run_skill" do
    test "runs one and waits, so the agent sees the outcome in the same turn" do
      stub_reply("the report")
      skill = skill_fixture(slug: unique("skill"))

      result = run("run_skill", %{"slug" => skill.slug})

      assert result["status"] == "succeeded"
      assert result["result"] == "the report"
      assert result["session_id"]
      assert is_integer(result["run_id"])
    end

    test "passes an instruction through to the run" do
      stub_reply("ok")
      skill = skill_fixture(slug: unique("skill"), instructions: "Do it. $.instructions")

      run("run_skill", %{"slug" => skill.slug, "instructions" => "carefully"})

      prompt = FakeHTTPClient.last_request().body["systemInstruction"]["parts"] |> hd()
      assert prompt["text"] =~ "Do it. carefully"
    end

    test "a failed run comes back with the error, not an exception" do
      FakeHTTPClient.stub({:ok, %{status: 500, body: "boom"}})
      skill = skill_fixture(slug: unique("skill"))

      result = run("run_skill", %{"slug" => skill.slug})

      assert result["status"] == "failed"
      assert result["error"] =~ "api_error"
      assert result["note"] =~ "fix the skill"
    end

    test "an unset value is reported as the operator's to fix, and nothing runs" do
      skill = skill_fixture(slug: unique("skill"))
      variable_fixture(skill, %{name: "api_key", kind: "secret", required: true})

      result = run("run_skill", %{"slug" => skill.slug})

      assert result["waiting_on_an_operator"] == ["api_key"]
      assert result["error"] =~ "Only the operator"
      assert FakeHTTPClient.requests() == []
      assert Skills.list_runs(skill) == []
    end

    test "an unknown slug is an error the model can read" do
      assert run("run_skill", %{"slug" => "no-such-skill"})["error"] =~ "no-such-skill"
    end

    test "a run parked on a gated call says so rather than looking finished" do
      skill = skill_fixture(tool_config: %{"http_request" => %{"gate" => "always"}})

      call = %{
        "functionCall" => %{"name" => "http_request", "args" => %{"url" => "https://example.com"}}
      }

      FakeHTTPClient.stub(%{
        "candidates" => [%{"content" => %{"parts" => [call]}, "finishReason" => "STOP"}]
      })

      result = run("run_skill", %{"slug" => skill.slug})

      assert result["status"] == "awaiting_approval"
      assert result["note"] =~ "waiting on the operator"
    end
  end

  describe "get_skill_run" do
    test "reads a run back without running it again" do
      stub_reply("done")
      skill = skill_fixture(slug: unique("skill"))
      %{"run_id" => run_id} = run("run_skill", %{"slug" => skill.slug})

      before = length(FakeHTTPClient.requests())
      result = run("get_skill_run", %{"run_id" => run_id})

      assert result["status"] == "succeeded"
      assert result["result"] == "done"
      assert length(FakeHTTPClient.requests()) == before
    end

    test "an unknown id is an error, not a crash" do
      assert run("get_skill_run", %{"run_id" => 0})["error"] =~ "No run"
    end
  end

  describe "the boundary" do
    test "a skill can never be granted the tools that run skills" do
      for name <- ~w(run_skill get_skill_run) do
        assert name in Tools.names()
        refute name in Tools.skill_grantable_names()
      end
    end

    test "so a skill cannot run another skill" do
      assert {:error, changeset} =
               Skills.create_skill(%{
                 "slug" => unique("skill"),
                 "name" => "n",
                 "tool_config" => %{"run_skill" => %{}}
               })

      assert %{tool_config: [message]} = errors_on(changeset)
      assert message =~ "run_skill"
    end
  end
end
