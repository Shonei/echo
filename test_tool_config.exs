Application.ensure_all_started(:echo)

opts = [
  model: "gemini-3-pro-image-preview", # or whichever model
  tools: [
    %{"google_search" => %{}},
    %{"functionDeclarations" => [%{"name" => "my_func", "description" => "desc"}]}
  ]
]
contents = [%{"role" => "user", "parts" => [%{"text" => "Search google for current weather and then call my_func"}]}]

# Let's test with includeServerSideToolInvocations directly in toolConfig vs inside functionCallingConfig

payload1 = %{
  "contents" => contents,
  "tools" => opts[:tools],
  "toolConfig" => %{
    "functionCallingConfig" => %{
      "mode" => "AUTO"
    }
  }
}

# The actual API expects camelCase. Let's see if we can just test raw json payload.
api_key = Application.get_env(:echo, Echo.Agents.API) |> Keyword.get(:api_key)
url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.7-flash:generateContent"
headers = [{"Content-Type", "application/json"}, {"x-goog-api-key", api_key}]

# Test 1: Just tools
req1 = Finch.build(:post, url, headers, Jason.encode!(payload1))
{_, resp1} = Finch.request(req1, Echo.Finch)
IO.puts("TEST 1 (No flag):")
IO.puts(resp1.body |> String.slice(0, 500))

# Test 2: Flag in toolConfig
payload2 = put_in(payload1, ["toolConfig", "includeServerSideToolInvocations"], true)
req2 = Finch.build(:post, url, headers, Jason.encode!(payload2))
{_, resp2} = Finch.request(req2, Echo.Finch)
IO.puts("TEST 2 (Flag in toolConfig):")
IO.puts(resp2.body |> String.slice(0, 500))

# Test 3: Flag in functionCallingConfig
payload3 = %{payload1 | "toolConfig" => %{"functionCallingConfig" => %{"mode" => "AUTO", "includeServerSideToolInvocations" => true}}}
req3 = Finch.build(:post, url, headers, Jason.encode!(payload3))
{_, resp3} = Finch.request(req3, Echo.Finch)
IO.puts("TEST 3 (Flag in functionCallingConfig):")
IO.puts(resp3.body |> String.slice(0, 500))
