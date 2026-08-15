defmodule Echo.Storage.AssetsIntegrationTest do
  use Echo.DataCase, async: false

  alias Echo.Repo
  alias Echo.Storage.{Asset, Assets, S3Client}
  alias Vix.Vips.{Image, Operation}

  @required_env ~w(S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY)

  setup do
    missing = Enum.reject(@required_env, fn name -> present?(System.get_env(name)) end)

    if missing != [] do
      {:skip, "set #{Enum.join(missing, ", ")} to run Assets integration tests"}
    else
      :ok
    end
  end

  test "upload_asset writes the file to S3 and a row to the database" do
    prefix = "echo-test/#{unique("run")}"
    path = "#{prefix}/#{unique("doc")}.txt"
    body = unique("payload")
    filename = "#{unique("notes")}.txt"
    cleanup_prefix(prefix)

    assert {:ok, [asset]} =
             Assets.upload_asset(path, body, "text/plain", filename: filename)

    assert asset.name == path
    assert asset.filename == filename
    assert asset.byte_size == byte_size(body)
    assert asset.variant == "original"
    assert Repo.get!(Asset, asset.id).id == asset.id

    assert {:ok, ^body, content_type} = Assets.get_asset_content(path)
    assert content_type =~ "text/plain"

    found = Assets.get_asset_by_path(path)
    assert found.id == asset.id
  end

  test "delete_asset removes the database row and the S3 object" do
    prefix = "echo-test/#{unique("run")}"
    path = "#{prefix}/#{unique("doc")}.txt"
    cleanup_prefix(prefix)

    assert {:ok, [asset]} = Assets.upload_asset(path, unique("payload"), "text/plain")
    assert {:ok, _} = Assets.delete_asset(asset)

    assert Repo.get(Asset, asset.id) == nil
    assert {:error, :not_found} = S3Client.get_object(path)
  end

  test "upload_asset stores four image variants in S3 and the database" do
    prefix = "echo-test/#{unique("run")}"
    path = "#{prefix}/#{unique("photo")}.png"
    filename = "#{unique("cat")}.png"
    body = png_bytes(64, 32)
    cleanup_prefix(prefix)

    assert {:ok, assets} =
             Assets.upload_asset(path, body, "image/png", filename: filename)

    by_variant = Map.new(assets, &{&1.variant, &1})
    assert Map.keys(by_variant) |> Enum.sort() == ~w(background content original thumbnail)

    for asset <- assets do
      assert asset.filename == filename
      assert Repo.get!(Asset, asset.id).name == asset.name
      assert {:ok, stored, _} = S3Client.get_object(asset.name)
      assert byte_size(stored) == asset.byte_size
    end

    original = by_variant["original"]
    assert original.width == 64
    assert original.height == 32
  end

  defp cleanup_prefix(prefix) do
    on_exit(fn ->
      case S3Client.list_objects(prefix) do
        {:ok, objects} -> Enum.each(objects, &S3Client.delete_object(&1.key))
        _ -> :ok
      end
    end)
  end

  defp png_bytes(width, height) do
    {:ok, image} = Operation.black(width, height)
    {:ok, buffer} = Image.write_to_buffer(image, ".png")
    buffer
  end

  defp present?(value), do: is_binary(value) and value != ""
end
