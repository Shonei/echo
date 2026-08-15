defmodule Echo.Storage.S3ClientIntegrationTest do
  use ExUnit.Case, async: false

  import Echo.DataCase, only: [unique: 1]

  alias Echo.Storage.S3Client

  @required_env ~w(S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY)

  setup do
    missing = Enum.reject(@required_env, fn name -> present?(System.get_env(name)) end)

    if missing != [] do
      {:skip, "set #{Enum.join(missing, ", ")} to run S3 integration tests"}
    else
      :ok
    end
  end

  test "uploads, reads, lists, and deletes an object" do
    prefix = "echo-test/#{unique("run")}"
    path = "#{prefix}/#{unique("obj")}.txt"
    body = unique("payload")
    on_exit(fn -> S3Client.delete_object(path) end)

    assert :ok = S3Client.upload_object(path, body, "text/plain")

    assert {:ok, ^body, content_type} = S3Client.get_object(path)
    assert content_type =~ "text/plain"

    # Prefix is unique to this run, so leftover bucket keys cannot hide ours.
    assert {:ok, objects} = S3Client.list_objects(prefix)
    keys = Enum.map(objects, & &1.key)
    assert path in keys, "expected #{inspect(path)} in #{inspect(keys)}"
    assert Enum.any?(objects, &(&1.key == path and &1.size == byte_size(body)))

    assert :ok = S3Client.delete_object(path)
    assert {:error, :not_found} = S3Client.get_object(path)
  end

  test "get_object/1 returns :not_found for a missing key" do
    assert {:error, :not_found} = S3Client.get_object("echo-test/#{unique("missing")}.txt")
  end

  defp present?(value), do: is_binary(value) and value != ""
end
