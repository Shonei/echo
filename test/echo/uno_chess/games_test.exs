defmodule Echo.UnoChess.GamesTest do
  use Echo.DataCase, async: true

  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Games

  @mate """
  8 . . . . . . . k
  7 . . . . . . . .
  6 . . . . . . Q .
  5 . . . . . . . .
  4 . . . . . . . .
  3 . . . . . . . .
  2 . . . . . . . .
  1 . . . . . . R K
  """

  test "a new game stores the deal and an empty black seat" do
    code = unique("room")

    assert {:ok, game} =
             Games.create_game(room_code: code, deck: [{:move, 1}, :reverse, "T"])

    assert game.room_code == code
    assert game.deck == ["1", "R", "T"]
    assert game.status == "active"
    assert game.winner == nil
    assert game.black_token == nil
    assert is_binary(game.white_token)
    assert Board.from_diagram(game.board) == Board.initial()
    assert Games.get_game_by_room_code(code).id == game.id
    assert Games.list_events(game.id) == []
  end

  test "the black seat can be claimed once" do
    {:ok, game} = Games.create_game(room_code: unique("room"), deck: ["1"])

    assert {:ok, token} = Games.claim_black(game)
    assert Games.get_game!(game.id).black_token == token
    assert {:error, :seat_taken} = Games.claim_black(game)
    assert Games.get_game!(game.id).black_token == token
  end

  test "a move is appended and a reload replays it" do
    {:ok, game} = Games.create_game(room_code: unique("room"), deck: [{:move, 1}])

    assert {:ok, game, [{:card_drawn, :white, {:move, 1}}]} =
             Games.play(game, {:draw, :white})

    assert {:error, :illegal_geometry} = Games.play(game, {:move, :white, "e2-e5"})
    assert length(Games.list_events(game.id)) == 1

    assert {:ok, game, [{:piece_moved, :white, "e2-e4", nil, 0}]} =
             Games.play(game, {:move, :white, "e2-e4"})

    events = Games.list_events(game.id)
    assert Enum.map(events, & &1.sequence) == [1, 2]
    assert Enum.map(events, & &1.type) == ["card_drawn", "piece_moved"]

    assert {:ok, restored} = Games.restore_game(game.id)
    assert restored.card == {:move, 1}
    assert restored.remaining == 0
    assert Board.get(restored.staged, "e4") == {:white, :pawn}
    assert Board.get(restored.board, "e2") == {:white, :pawn}
  end

  test "checkmate is stored as two facts and updates the cached result" do
    {:ok, game} = Games.create_game(room_code: unique("room"), board: @mate, deck: ["1"])

    {:ok, game, _} = Games.play(game, {:draw, :white})
    {:ok, game, _} = Games.play(game, {:move, :white, "g6-g7"})

    assert {:ok, game, [{:turn_ended, :white}, {:checkmate, :white}]} =
             Games.play(game, {:end_turn, :white})

    assert game.status == "checkmate"
    assert game.winner == "white"

    types = game.id |> Games.list_events() |> Enum.map(& &1.type)
    assert types == ["card_drawn", "piece_moved", "turn_ended", "checkmate"]

    assert {:ok, restored} = Games.restore_game(game.id)
    assert restored.status == :checkmate
    assert restored.winner == :white
    assert {:error, :game_over} = Games.play(game, {:draw, :black})
  end
end
