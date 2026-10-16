defmodule EchoWeb.UnoChessChannelTest do
  use ExUnit.Case, async: true

  import Phoenix.ChannelTest
  import Echo.DataCase, only: [unique: 1]

  alias Echo.UnoChess.Games
  alias EchoWeb.UnoChessChannel
  alias EchoWeb.UserSocket

  @endpoint EchoWeb.Endpoint

  test "joining with a token sets the seat and pushes updates when actions occur" do
    {:ok, game} = Games.create_game(room_code: unique("room"), deck: ["1", "2"])

    {:ok, white_reply, white_socket} =
      UserSocket
      |> socket("white_user", %{})
      |> subscribe_and_join(UnoChessChannel, "uno_chess:" <> game.room_code, %{
        "token" => game.white_token
      })

    assert white_reply.game.you == "white"
    assert white_reply.game.seats == %{white: true, black: false}

    {:ok, spec_reply, _spec_socket} =
      UserSocket
      |> socket("spectator", %{})
      |> subscribe_and_join(UnoChessChannel, "uno_chess:" <> game.room_code, %{})

    assert spec_reply.game.you == nil

    # White draws over the channel
    ref = push(white_socket, "play", %{"action" => "draw"})
    assert_reply ref, :ok, %{game: %{card: %{code: "1"}}, events: [%{type: "card_drawn"}]}, 5_000

    # Both sockets receive the real-time game_updated push
    assert_push "game_updated",
                %{
                  game: %{card: %{code: "1"}, remaining: 1},
                  events: [%{type: "card_drawn"}]
                },
                5_000
  end

  test "spectator cannot play without claiming a seat" do
    {:ok, game} = Games.create_game(room_code: unique("room"), deck: ["1"])

    {:ok, _reply, socket} =
      UserSocket
      |> socket("guest", %{})
      |> subscribe_and_join(UnoChessChannel, "uno_chess:" <> game.room_code, %{})

    ref = push(socket, "play", %{"action" => "draw"})
    assert_reply ref, :error, %{reason: "invalid_token"}, 5_000

    join_ref = push(socket, "join_black", %{})
    assert_reply join_ref, :ok, %{seat: "black", token: token, game: %{you: "black"}}, 5_000
    assert is_binary(token)
  end
end
