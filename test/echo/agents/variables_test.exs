defmodule Echo.Agents.VariablesTest do
  # No DataCase: everything here is pure. That is the point of the split --
  # the security-critical logic should not need a skill, a database or a model
  # to test.
  use ExUnit.Case, async: true

  alias Echo.Agents.Variables

  defmodule StubResolver do
    @behaviour Echo.Agents.VariableResolver

    @values %{
      "repo_name" => {"echo-server", :plain},
      "token" => {"ghp_0123456789abcdef", :sensitive},
      "retries" => {3, :plain},
      "host" => {"api.example.com", :sensitive},
      "base_url" => {"https://api.example.com", :sensitive}
    }

    @impl true
    def fetch("scope:ok", names), do: {:ok, Map.take(@values, names)}
    def fetch("scope:down", _names), do: {:error, :store_unreachable}
    def fetch("scope:boom", _names), do: raise("resolver exploded")
  end

  describe "scan/1" do
    test "finds references in nested maps and lists, deduplicated" do
      args = %{
        "headers" => %{"Authorization" => "Bearer $.token"},
        "body" => ["retry $.retries", %{"deep" => "$.token"}]
      }

      # Order follows traversal, which for a map is term order rather than
      # source order, so compare as a set.
      assert Enum.sort(Variables.scan(args)) == ["retries", "token"]
    end

    test "a name repeated in one string is listed once, in order" do
      assert Variables.scan("$.a then $.b then $.a") == ["a", "b"]
    end

    test "an escaped reference is not a reference" do
      assert Variables.scan(%{"filter" => "$$.items"}) == []
    end
  end

  describe "substitute/2" do
    test "a whole-string reference keeps the value's type; an embedded one cannot" do
      values = %{"token" => "ghp_secret", "retries" => 3}

      args = %{
        "headers" => %{"Authorization" => "Bearer $.token"},
        "body" => ["retry $.retries", %{"deep" => "$.token"}],
        "count" => "$.retries",
        "timeout" => 5
      }

      assert Variables.substitute(args, values) == %{
               "headers" => %{"Authorization" => "Bearer ghp_secret"},
               "body" => ["retry 3", %{"deep" => "ghp_secret"}],
               "count" => 3,
               "timeout" => 5
             }
    end

    test "an unknown name is left exactly as written" do
      assert Variables.substitute(%{"a" => "$.missing"}, %{}) == %{"a" => "$.missing"}
    end

    test "$$. escapes to a literal $." do
      assert Variables.substitute(%{"jq" => "$$.items[0]"}, %{"items" => "x"}) ==
               %{"jq" => "$.items[0]"}
    end

    test "map keys are not substituted" do
      assert Variables.substitute(%{"$.token" => "v"}, %{"token" => "secret"}) ==
               %{"$.token" => "v"}
    end
  end

  describe "resolve/3" do
    test "returns the resolved args and only the sensitive pairs to undo" do
      args = %{"url" => "https://x/$.repo_name", "headers" => %{"A" => "Bearer $.token"}}

      assert {:ok, resolved, used} = Variables.resolve(args, "scope:ok", StubResolver)
      assert resolved["url"] == "https://x/echo-server"
      assert resolved["headers"]["A"] == "Bearer ghp_0123456789abcdef"

      # repo_name is :plain, so it is never undone -- scrubbing a config value
      # would corrupt the result rather than protect anything.
      assert used == [{"ghp_0123456789abcdef", "$.token"}]
    end

    test "a name the scope does not know comes back as something the model can act on" do
      assert {:error, :unresolved, message} =
               Variables.resolve(%{"url" => "https://x/$.repo_nmae"}, "scope:ok", StubResolver)

      assert message =~ "$.repo_nmae"
    end

    test "a scope that cannot be answered fails the turn instead" do
      assert {:error, :unavailable, :store_unreachable} =
               Variables.resolve(%{"url" => "$.token"}, "scope:down", StubResolver)
    end

    test "a resolver that raises fails the turn, not the conversation process" do
      assert {:error, :unavailable, {:resolver_raised, _}} =
               Variables.resolve(%{"url" => "$.token"}, "scope:boom", StubResolver)
    end

    test "no scope leaves $. alone, because jq exists and agent chat has http_request" do
      args = %{"filter" => "$.items[0].name"}
      assert {:ok, ^args, []} = Variables.resolve(args, nil, StubResolver)
    end

    test "args with no references never call the resolver" do
      args = %{"url" => "https://example.com"}
      assert {:ok, ^args, []} = Variables.resolve(args, "scope:boom", StubResolver)
    end
  end

  describe "scrub/2" do
    test "undoes the longest value first, so one cannot eat part of another" do
      used =
        Variables.merge([{"api.example.com", "$.host"}, {"https://api.example.com", "$.base"}])

      assert Variables.scrub(%{"body" => "hit https://api.example.com/x"}, used) ==
               %{"body" => "hit $.base/x"}
    end

    test "walks keys as well as values, because a tool can echo into either" do
      used = [{"secret", "$.token"}]

      assert Variables.scrub(%{"secret" => ["a secret here"]}, used) ==
               %{"$.token" => ["a $.token here"]}
    end

    test "with nothing to undo it is identity" do
      term = %{"a" => ["b", 1, true]}
      assert Variables.scrub(term, []) == term
    end
  end

  describe "scrubbable?/2" do
    test "only sensitive binaries are ever replaced" do
      assert Variables.scrubbable?("s3cr3t", :sensitive)
      refute Variables.scrubbable?("", :sensitive)

      # The case this rule exists for: a config variable holding "1" would
      # rewrite every 1 in every tool result, and nothing downstream could tell.
      refute Variables.scrubbable?("1", :plain)
      refute Variables.scrubbable?("echo-server", :plain)
      refute Variables.scrubbable?(3, :sensitive)
    end
  end
end
