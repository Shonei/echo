defmodule TestUpload do
  alias Echo.Storage.Assets
  alias Echo.Repo

  def run do
    # Ensure app is started (it should be since we run this with mix run)
    path = "/tmp/test-image.jpg"
    body = File.read!(path)
    content_type = "image/jpeg"

    # Clean up test files first if they exist
    hash = :crypto.hash(:sha256, "#{content_type}+test-upload.jpg") |> Base.encode16(case: :lower)
    import Ecto.Query
    Echo.Storage.Asset |> where([a], a.original_hash == ^hash) |> Repo.delete_all()

    # Try upload
    IO.puts("Uploading test-image.jpg...")

    case Assets.upload_asset("test-upload.jpg", body, content_type) do
      {:ok, assets} ->
        IO.puts("SUCCESS! Created #{length(assets)} assets:")
        Enum.each(assets, fn a -> IO.puts(" - #{a.url}") end)

        # Test duplicate
        IO.puts("\nTrying duplicate upload...")

        case Assets.upload_asset("test-upload.jpg", body, content_type) do
          {:error, :already_exists} ->
            IO.puts("SUCCESS! Caught duplicate upload properly.")

          other ->
            IO.puts(
              "FAILED duplicate test: expected {:error, :already_exists}, got: #{inspect(other)}"
            )
        end

      {:error, reason} ->
        IO.puts("FAILED upload: #{inspect(reason)}")
    end
  end
end

TestUpload.run()
