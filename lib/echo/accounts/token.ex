defmodule Echo.Accounts.Token do
  @moduledoc """
  JWT token generation and verification using Joken.
  Access tokens have an 8 hour TTL.
  Refresh tokens have a 30 day TTL.
  """

  use Joken.Config

  # 8 hours in seconds
  @access_token_ttl 8 * 60 * 60
  # 30 days in seconds
  @refresh_token_ttl 30 * 24 * 60 * 60

  @impl true
  def token_config do
    default_claims(skip: [:aud, :iss], default_exp: @access_token_ttl)
  end

  @doc """
  Generates an access token for the given user.
  Token expires in 8 hours.
  """
  def generate_access_token(user) do
    extra_claims = %{
      "sub" => to_string(user.id),
      "username" => user.username,
      "type" => "access"
    }

    generate_and_sign(extra_claims, signer())
  end

  @doc """
  Generates a refresh token for the given user.
  Token expires in 30 days.
  """
  def generate_refresh_token(user) do
    # For refresh tokens, we manually set the exp claim to 30 days
    now = DateTime.utc_now() |> DateTime.to_unix()

    extra_claims = %{
      "sub" => to_string(user.id),
      "username" => user.username,
      "type" => "refresh",
      "exp" => now + @refresh_token_ttl,
      "iat" => now,
      "nbf" => now
    }

    Joken.encode_and_sign(extra_claims, signer())
  end

  @doc """
  Verifies an access token and returns the claims if valid.
  Returns {:ok, claims} or {:error, reason}.
  """
  def verify_access_token(token) do
    case verify_and_validate(token, signer()) do
      {:ok, claims} ->
        if claims["type"] == "access" do
          {:ok, claims}
        else
          {:error, :invalid_token_type}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Verifies a refresh token and returns the claims if valid.
  Returns {:ok, claims} or {:error, reason}.
  """
  def verify_refresh_token(token) do
    case Joken.verify(token, signer()) do
      {:ok, claims} ->
        # Manually check expiration
        now = DateTime.utc_now() |> DateTime.to_unix()

        cond do
          claims["type"] != "refresh" ->
            {:error, :invalid_token_type}

          claims["exp"] && claims["exp"] < now ->
            {:error, :token_expired}

          true ->
            {:ok, claims}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp signer do
    secret = get_jwt_secret()
    Joken.Signer.create("HS256", secret)
  end

  defp get_jwt_secret do
    Application.get_env(:echo, :jwt_secret) ||
      raise """
      JWT secret is not configured!
      Set the JWT_SECRET environment variable or configure :jwt_secret in config.
      """
  end
end
