defmodule Echo.UnoChess.GamesIntegrationTest do
  @moduledoc """
  Plays games through Postgres. Rows are kept, so every room code and token
  comes from `unique/1`.
  """

  use Echo.DataCase, async: true

  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Deck
  alias Echo.UnoChess.Game, as: Engine
  alias Echo.UnoChess.Games

  @capture """
  8 . . . . k . . .
  7 . . . . . . . .
  6 . . . . . . . .
  5 . . . p . . . .
  4 . . . . P . . .
  3 . . . . . . . .
  2 . . . . . . . .
  1 . . . . K . . .
  """

  @stalemate """
  8 k . . . . . . .
  7 . . . . . . . .
  6 . . . . . . . .
  5 . . Q . . . . .
  4 . . . . . . . .
  3 . . . . . . . .
  2 . . . . . . . .
  1 . . . . . . . K
  """

  test "a full turn round-trips through the rows this test inserted" do
    room = unique("room")
    white = unique("white")
    deck = ["R", "1", "T"]

    {:ok, game} =
      Games.create_game(room_code: room, white_token: white, board: @capture, deck: deck)

    {:ok, black} = Games.claim_black(game)

    commands = [
      {:draw, :white},
      {:draw, :white},
      {:move, :white, "e4-d5"},
      {:undo, :white},
      {:move, :white, "e4-d5"},
      {:end_turn, :white},
      {:draw, :black},
      {:drop, :black, :pawn, "d6"},
      {:end_turn, :black}
    ]

    play!(game, commands)

    stored = Games.get_game_by_room_code(room)
    assert stored.id == game.id
    assert stored.white_token == white
    assert stored.black_token == black
    assert stored.status == "active"
    assert stored.winner == nil

    events = Games.list_events(stored.id)
    assert Enum.map(events, & &1.sequence) == Enum.to_list(1..length(events))

    assert Enum.map(events, & &1.type) == [
             "card_drawn",
             "card_drawn",
             "piece_moved",
             "move_undone",
             "piece_moved",
             "turn_ended",
             "card_drawn",
             "piece_dropped",
             "turn_ended"
           ]

    assert Enum.at(events, 0).payload == %{"color" => "white", "card" => "R"}

    assert Enum.at(events, 2).payload == %{
             "color" => "white",
             "move" => "e4-d5",
             "captured" => %{"color" => "black", "kind" => "pawn"},
             "remaining" => 0
           }

    assert Enum.at(events, 7).payload == %{
             "color" => "black",
             "kind" => "pawn",
             "square" => "d6",
             "remaining" => 1
           }

    assert {:ok, restored} = Games.restore_game(stored.id)
    assert restored == scripted(@capture, deck, commands)
    assert Board.get(restored.board, "d5") == {:white, :pawn}
    assert Board.get(restored.board, "d6") == {:black, :pawn}

    {:ok, other} =
      Games.create_game(room_code: unique("room"), white_token: unique("white"), deck: ["2"])

    assert Games.list_events(other.id) == []
  end

  test "stalemate is stored on this game and leaves the winner empty" do
    room = unique("room")
    deck = ["1"]

    {:ok, game} =
      Games.create_game(
        room_code: room,
        white_token: unique("white"),
        board: @stalemate,
        deck: deck
      )

    play!(game, [{:draw, :white}, {:move, :white, "c5-b6"}, {:end_turn, :white}])

    stored = Games.get_game_by_room_code(room)
    assert stored.status == "stalemate"
    assert stored.winner == nil

    events = Games.list_events(stored.id)
    assert List.last(events).type == "stalemate"
    assert List.last(events).payload == %{}

    assert {:ok, restored} = Games.restore_game(stored.id)
    assert restored.status == :stalemate
    assert restored.winner == nil
  end

  test "one black claim wins when several arrive together" do
    {:ok, game} =
      Games.create_game(room_code: unique("room"), white_token: unique("white"), deck: ["1"])

    results = Enum.map(1..8, fn _ -> Task.async(fn -> Games.claim_black(game) end) end)
    results = Enum.map(results, &Task.await(&1, 15_000))

    tokens = for {:ok, token} <- results, do: token
    assert length(tokens) == 1
    assert Enum.count(results, &(&1 == {:error, :seat_taken})) == 7
    assert Games.get_game!(game.id).black_token == hd(tokens)
  end

  test "two draws at once append a single card" do
    {:ok, game} =
      Games.create_game(room_code: unique("room"), white_token: unique("white"), deck: ["1", "2"])

    results =
      Enum.map(1..2, fn _ -> Task.async(fn -> Games.play(game, {:draw, :white}) end) end)

    results = Enum.map(results, &Task.await(&1, 15_000))

    assert Enum.count(results, &match?({:ok, _, [{:card_drawn, :white, {:move, 1}}]}, &1)) == 1
    assert {:error, :card_already_drawn} in results

    events = Games.list_events(game.id)
    assert Enum.map(events, & &1.type) == ["card_drawn"]
    assert hd(events).sequence == 1
    assert hd(events).payload == %{"color" => "white", "card" => "1"}
  end

  defp play!(game, commands) do
    Enum.reduce(commands, game, fn command, game ->
      {:ok, game, _events} = Games.play(game, command)
      game
    end)
  end

  defp scripted(diagram, deck, commands) do
    {:ok, deck} = Deck.decode(deck)

    commands
    |> Enum.reduce(Engine.new(board: Board.from_diagram(diagram), deck: deck), fn command, game ->
      {:ok, game, _events} = Engine.apply(game, command)
      game
    end)
  end
end
