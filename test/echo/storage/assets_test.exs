defmodule Echo.Storage.AssetsTest do
  use Echo.DataCase, async: true

  alias Echo.Storage.Asset
  alias Echo.Storage.Assets
  alias Vix.Vips.{Image, Operation}

  @jpeg_fixture Path.expand("test.jpeg", __DIR__)

  defmodule FakeS3 do
    def upload_object(_path, _body, _content_type), do: :ok
  end

  defp png_bytes(width, height) do
    {:ok, image} = Operation.black(width, height)
    {:ok, buffer} = Image.write_to_buffer(image, ".png")
    buffer
  end

  defp asset_attrs(overrides) do
    path = "#{unique("files")}.txt"

    Map.merge(
      %{
        name: path,
        url: "https://example.com/bucket/#{path}",
        url_suffix: "/#{path}",
        content_type: "text/plain"
      },
      overrides
    )
  end

  describe "Asset.changeset/2" do
    test "accepts file metadata" do
      changeset =
        Asset.changeset(
          %Asset{},
          asset_attrs(%{
            filename: "#{unique("notes")}.txt",
            byte_size: 12,
            variant: "original",
            content_hash: String.duplicate("a", 64)
          })
        )

      assert changeset.valid?
    end

    test "rejects an unknown variant" do
      changeset = Asset.changeset(%Asset{}, asset_attrs(%{variant: "tiny"}))

      assert %{variant: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects a negative byte size" do
      changeset = Asset.changeset(%Asset{}, asset_attrs(%{byte_size: -1}))

      assert %{byte_size: ["must be greater than or equal to 0"]} = errors_on(changeset)
    end
  end

  describe "create_asset/1" do
    test "persists file metadata" do
      filename = "#{unique("hero")}.png"

      attrs =
        asset_attrs(%{
          filename: filename,
          byte_size: 2048,
          width: 800,
          height: 600,
          variant: "content",
          content_hash: unique("hash")
        })

      assert {:ok, asset} = Assets.create_asset(attrs)
      assert asset.filename == filename
      assert asset.byte_size == 2048
      assert asset.width == 800
      assert asset.height == 600
      assert asset.variant == "content"
      assert asset.content_hash == attrs.content_hash
    end
  end

  describe "upload_asset/4" do
    test "records filename, size, and content hash for a non-image" do
      body = unique("body")
      path = "#{unique("docs")}.txt"
      filename = "#{unique("readme")}.txt"

      assert {:ok, [asset]} =
               Assets.upload_asset(path, body, "text/plain",
                 filename: filename,
                 storage: FakeS3
               )

      assert asset.filename == filename
      assert asset.byte_size == byte_size(body)
      assert asset.variant == "original"
      assert asset.width == nil
      assert asset.height == nil

      expected_hash =
        :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      assert asset.content_hash == expected_hash
    end

    test "defaults filename to the path basename" do
      path = "#{unique("docs")}.txt"

      assert {:ok, [asset]} =
               Assets.upload_asset(path, "hi", "text/plain", storage: FakeS3)

      assert asset.filename == Path.basename(path)
    end

    test "stores four image variants with shared filename and per-file dimensions" do
      body = png_bytes(64, 32)
      filename = "#{unique("cat")}.png"
      path = "#{unique("photos")}.png"

      assert {:ok, assets} =
               Assets.upload_asset(path, body, "image/png",
                 filename: filename,
                 storage: FakeS3
               )

      by_variant = Map.new(assets, &{&1.variant, &1})

      assert map_size(by_variant) == 4
      assert Enum.all?(assets, &(&1.filename == filename))

      original = by_variant["original"]
      assert original.width == 64
      assert original.height == 32
      assert original.byte_size == byte_size(body)
      assert original.content_hash == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      thumbnail = by_variant["thumbnail"]
      assert thumbnail.content_type == "image/jpeg"
      assert thumbnail.width <= 400
      assert thumbnail.height <= 400
      assert thumbnail.byte_size > 0
      assert thumbnail.content_hash != original.content_hash
    end

    test "handle_image_upload stores JPEG variants with suffixed paths" do
      body = File.read!(@jpeg_fixture)
      filename = "#{unique("office")}.jpeg"
      path = "#{unique("photos")}.jpeg"
      ext = Path.extname(path)
      base = String.replace_suffix(path, ext, "")

      {:ok, source} = Image.new_from_buffer(body)
      source_width = Image.width(source)
      source_height = Image.height(source)

      assert {:ok, assets} =
               Assets.upload_asset(path, body, "image/jpeg",
                 filename: filename,
                 storage: FakeS3
               )

      by_variant = Map.new(assets, &{&1.variant, &1})
      assert Map.keys(by_variant) |> Enum.sort() == ~w(background content original thumbnail)

      original = by_variant["original"]
      assert original.name == base <> "-original.jpeg"
      assert original.content_type == "image/jpeg"
      assert original.filename == filename
      assert original.width == source_width
      assert original.height == source_height
      assert original.byte_size == byte_size(body)
      assert original.content_hash == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      background = by_variant["background"]
      assert background.name == base <> "-background.jpeg"
      assert background.content_type == "image/jpeg"
      assert background.width <= 1920

      content = by_variant["content"]
      assert content.name == base <> "-content.jpeg"
      assert content.content_type == "image/jpeg"
      assert content.width <= 800
      assert content.width < original.width

      thumbnail = by_variant["thumbnail"]
      assert thumbnail.name == base <> "-thumbnail.jpeg"
      assert thumbnail.content_type == "image/jpeg"
      assert thumbnail.width <= 400
      assert thumbnail.width < original.width
      assert thumbnail.content_hash != original.content_hash

      assert {:error, :already_exists} =
               Assets.upload_asset(path, body, "image/jpeg",
                 filename: filename,
                 storage: FakeS3
               )
    end
  end
end
