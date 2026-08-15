defmodule Echo.Storage.AssetsIntegrationTest do
  use Echo.DataCase, async: false

  alias Echo.Repo
  alias Echo.Storage.{Asset, Assets, S3Client}
  alias Vix.Vips.Image

  @jpeg_fixture Path.expand("test.jpeg", __DIR__)
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

  test "handle_image_upload stores four JPEG variants in S3 and the database" do
    prefix = "echo-test/#{unique("run")}"
    path = "#{prefix}/#{unique("photo")}.jpeg"
    filename = "#{unique("office")}.jpeg"
    body = File.read!(@jpeg_fixture)
    ext = Path.extname(path)
    base = String.replace_suffix(path, ext, "")
    cleanup_prefix(prefix)

    {:ok, source} = Image.new_from_buffer(body)
    source_width = Image.width(source)
    source_height = Image.height(source)

    assert {:ok, assets} =
             Assets.upload_asset(path, body, "image/jpeg", filename: filename)

    by_variant = Map.new(assets, &{&1.variant, &1})
    assert Map.keys(by_variant) |> Enum.sort() == ~w(background content original thumbnail)

    original = by_variant["original"]
    assert original.name == base <> "-original.jpeg"
    assert original.width == source_width
    assert original.height == source_height
    assert original.byte_size == byte_size(body)
    assert original.content_type == "image/jpeg"

    assert by_variant["background"].name == base <> "-background.jpeg"
    assert by_variant["background"].width <= 1920
    assert by_variant["content"].name == base <> "-content.jpeg"
    assert by_variant["content"].width <= 800
    assert by_variant["content"].width < original.width
    assert by_variant["thumbnail"].name == base <> "-thumbnail.jpeg"
    assert by_variant["thumbnail"].content_type == "image/jpeg"
    assert by_variant["thumbnail"].width <= 400

    for asset <- assets do
      assert asset.filename == filename
      assert Repo.get!(Asset, asset.id).name == asset.name
      assert {:ok, stored, _} = S3Client.get_object(asset.name)
      assert byte_size(stored) == asset.byte_size
    end

    assert {:ok, ^body, _} = S3Client.get_object(original.name)

    assert {:error, :already_exists} =
             Assets.upload_asset(path, body, "image/jpeg", filename: filename)
  end

  defp cleanup_prefix(prefix) do
    on_exit(fn ->
      case S3Client.list_objects(prefix) do
        {:ok, objects} -> Enum.each(objects, &S3Client.delete_object(&1.key))
        _ -> :ok
      end
    end)
  end

  defp present?(value), do: is_binary(value) and value != ""
end
