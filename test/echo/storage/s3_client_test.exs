defmodule Echo.Storage.S3ClientTest do
  use ExUnit.Case, async: true

  alias Echo.Storage.S3Client

  # A fake client. We never talk to S3 here — we only check the headers
  # sign_request would attach to a request.
  defp client do
    %S3Client{
      endpoint: "https://storage.example.com",
      region: "us-east-1",
      bucket: "echo-bucket",
      access_key_id: "AKIAEXAMPLE",
      secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    }
  end

  describe "sign_request/5" do
    test "adds host, payload hash, and an AWS4 authorization header" do
      headers = S3Client.sign_request(client(), "GET", "photos/cat.png", "", [])

      empty_body_hash = :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)

      assert {"host", "storage.example.com"} in headers
      assert {"x-amz-content-sha256", empty_body_hash} in headers

      {_, authorization} = List.keyfind(headers, "Authorization", 0)

      assert authorization =~ "AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/"
      assert authorization =~ "/us-east-1/s3/aws4_request"
      assert authorization =~ "SignedHeaders=host;x-amz-content-sha256;x-amz-date"
    end
  end
end
