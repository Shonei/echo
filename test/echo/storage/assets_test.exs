defmodule Echo.Storage.AssetsTest do
  use Echo.DataCase, async: true

  alias Echo.Storage.Asset
  alias Echo.Storage.Assets
  alias Vix.Vips.{Image, Operation}

  defmodule FakeS3 do
    def upload_object(_path, _body, _content_type), do: :ok
  end

  defp png_bytes(width, height) do
    {:ok, image} = Operation.black(width, height)
    {:ok, buffer} = Image.write_to_buffer(image, ".png")
    buffer
  end

  defp asset_attrs(overrides) do
    path = "files/doc-#{System.unique_integer([:positive])}.txt"

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
            filename: "notes.txt",
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
      attrs =
        asset_attrs(%{
          filename: "hero.png",
          byte_size: 2048,
          width: 800,
          height: 600,
          variant: "content",
          content_hash: "abc123"
        })

      assert {:ok, asset} = Assets.create_asset(attrs)
      assert asset.filename == "hero.png"
      assert asset.byte_size == 2048
      assert asset.width == 800
      assert asset.height == 600
      assert asset.variant == "content"
      assert asset.content_hash == "abc123"
    end
  end

  describe "upload_asset/4" do
    test "records filename, size, and content hash for a non-image" do
      body = "hello world"
      path = "docs/readme-#{System.unique_integer([:positive])}.txt"

      assert {:ok, [asset]} =
               Assets.upload_asset(path, body, "text/plain",
                 filename: "README.txt",
                 storage: FakeS3
               )

      assert asset.filename == "README.txt"
      assert asset.byte_size == byte_size(body)
      assert asset.variant == "original"
      assert asset.width == nil
      assert asset.height == nil

      expected_hash =
        :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      assert asset.content_hash == expected_hash
    end

    test "defaults filename to the path basename" do
      path = "docs/notes-#{System.unique_integer([:positive])}.txt"

      assert {:ok, [asset]} =
               Assets.upload_asset(path, "hi", "text/plain", storage: FakeS3)

      assert asset.filename == Path.basename(path)
    end

    test "stores four image variants with shared filename and per-file dimensions" do
      body = png_bytes(64, 32)
      path = "photos/cat-#{System.unique_integer([:positive])}.png"

      assert {:ok, assets} =
               Assets.upload_asset(path, body, "image/png",
                 filename: "cat.png",
                 storage: FakeS3
               )

      by_variant = Map.new(assets, &{&1.variant, &1})

      assert map_size(by_variant) == 4
      assert Enum.all?(assets, &(&1.filename == "cat.png"))

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
  end
end
