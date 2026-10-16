defmodule Echo.UnoChess.GameTest do
  use ExUnit.Case, async: true

  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Deck
  alias Echo.UnoChess.Game

  # A game test supplies the deck in draw order. Nothing here is random.
  # Copy a test, pass a diagram and a short deck, then apply one action.

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

  @in_check """
  8 k . . . . . . .
  7 . . . . . . . .
  6 . . . . . . . .
  5 . . . . . . . .
  4 . . . . . . . .
  3 . . . . . . . .
  2 . . . . P . . .
  1 r . . . K . . .
  """

  @mate_in_one """
  8 . . . . . . . k
  7 . . . . . . . .
  6 . . . . . . Q .
  5 . . . . . . . .
  4 . . . . . . . .
  3 . . . . . . . .
  2 . . . . . . . .
  1 . . . . . . R K
  """

  @stalemate_in_one """
  8 k . . . . . . .
  7 . . . . . . . .
  6 . . . . . . . .
  5 . . Q . . . . .
  4 . . . . . . . .
  3 . . . . . . . .
  2 . . . . . . . .
  1 . . . . . . . K
  """

  describe "draw" do
    test "a move card is shown to both players and arms that many sub-moves" do
      game = Game.new(deck: [{:move, 2}, :reverse])

      assert {:ok, game, [{:card_drawn, :white, {:move, 2}}]} = Game.apply(game, {:draw, :white})
      assert game.card == {:move, 2}
      assert game.remaining == 2
      assert game.deck == [:reverse]
    end

    test "reverse is discarded and the same player draws again" do
      game = Game.new(deck: [:reverse, {:move, 1}])

      assert {:ok, game, [{:card_drawn, :white, :reverse}]} = Game.apply(game, {:draw, :white})
      assert game.card == nil
      assert game.remaining == 0
      assert game.discard == [:reverse]
      assert game.turn == :white

      assert {:ok, game, [{:card_drawn, :white, {:move, 1}}]} = Game.apply(game, {:draw, :white})
      assert game.card == {:move, 1}
    end

    test "an empty deck is rebuilt from the discard with the game's rng" do
      game = Game.new(deck: [], discard: [{:move, 1}, {:restore, 2}], rng: &Enum.reverse/1)

      assert {:ok, game, [{:card_drawn, :white, {:restore, 2}}]} =
               Game.apply(game, {:draw, :white})

      assert game.deck == [{:move, 1}]
      assert game.discard == []
    end

    test "draw is refused when it is not that player's action" do
      game = Game.new(deck: [{:move, 1}])

      assert {:error, :not_your_turn} = Game.apply(game, {:draw, :black})
      assert {:error, :must_draw} = Game.apply(game, {:move, :white, "e2-e4"})

      {:ok, game, _} = Game.apply(game, {:draw, :white})
      assert {:error, :card_already_drawn} = Game.apply(game, {:draw, :white})
      assert {:error, :empty_deck} = Game.apply(Game.new(deck: [], discard: []), {:draw, :white})
    end
  end

  describe "moves" do
    test "a move-2 turn plays two sub-moves, then commits" do
      game = Game.new(deck: [{:move, 2}])
      {:ok, game, _} = Game.apply(game, {:draw, :white})

      assert {:ok, game, [{:piece_moved, :white, "e2-e4", nil, 1}]} =
               Game.apply(game, {:move, :white, "e2-e4"})

      assert {:error, :turn_incomplete} = Game.apply(game, {:end_turn, :white})

      assert {:ok, game, [{:piece_moved, :white, "e4-e5", nil, 0}]} =
               Game.apply(game, {:move, :white, "e4-e5"})

      assert {:ok, game, [{:turn_ended, :white}]} = Game.apply(game, {:end_turn, :white})
      assert game.turn == :black
      assert game.card == nil
      assert game.discard == [{:move, 2}]
      assert Board.get(game.board, "e5") == {:white, :pawn}
      assert game.board == game.staged
    end

    test "an illegal sub-move does not spend a charge" do
      game = drawn(:white, [{:move, 1}])

      assert {:error, :illegal_geometry} = Game.apply(game, {:move, :white, "e2-e5"})
      assert game.remaining == 1
      assert Board.get(game.staged, "e2") == {:white, :pawn}
    end

    test "a capture lands in the victim's graveyard and undo puts it back" do
      game = drawn(:white, [{:move, 1}], @capture)

      assert {:ok, game, [{:piece_moved, :white, "e4-d5", {:black, :pawn}, 0}]} =
               Game.apply(game, {:move, :white, "e4-d5"})

      assert game.graveyard.black == [:pawn]
      assert Board.get(game.staged, "d5") == {:white, :pawn}

      assert {:ok, game, [{:move_undone, :white, 1}]} = Game.apply(game, {:undo, :white})
      assert game.graveyard.black == []
      assert Board.get(game.staged, "e4") == {:white, :pawn}
      assert Board.get(game.staged, "d5") == {:black, :pawn}
      assert {:error, :nothing_to_undo} = Game.apply(game, {:undo, :white})
    end

    test "ending in check keeps the staged moves so the player can undo" do
      game = drawn(:white, [{:move, 1}], @in_check)

      {:ok, game, _} = Game.apply(game, {:move, :white, "e2-e4"})
      assert {:error, :king_in_check} = Game.apply(game, {:end_turn, :white})
      assert game.card == {:move, 1}
      assert Board.get(game.staged, "e4") == {:white, :pawn}

      {:ok, game, _} = Game.apply(game, {:undo, :white})

      assert {:ok, game, _} = Game.apply(game, {:move, :white, "e1-d2"})
      assert {:ok, game, [{:turn_ended, :white}]} = Game.apply(game, {:end_turn, :white})
      assert game.turn == :black
    end
  end

  describe "drops" do
    test "a restore card spends charges from the graveyard and forfeits the rest" do
      diagram = """
      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . . . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
      """

      game = drawn(:white, [{:restore, 2}], diagram, graveyard: %{white: [:queen]})

      assert {:error, :off_home_half} = Game.apply(game, {:drop, :white, :queen, "e5"})
      assert game.remaining == 2
      assert game.graveyard.white == [:queen]

      assert {:error, :not_in_graveyard} = Game.apply(game, {:drop, :white, :rook, "d4"})

      assert {:ok, game, [{:piece_dropped, :white, :queen, "d4", 1}]} =
               Game.apply(game, {:drop, :white, :queen, "d4"})

      assert game.graveyard.white == []
      assert {:error, :not_in_graveyard} = Game.apply(game, {:drop, :white, :queen, "c4"})

      assert {:ok, game, [{:turn_ended, :white}]} = Game.apply(game, {:end_turn, :white})
      assert Board.get(game.board, "d4") == {:white, :queen}
      assert game.turn == :black
    end

    test "a move card does not drop, and a restore card does not move" do
      game = drawn(:white, [{:move, 1}])
      assert {:error, :wrong_card} = Game.apply(game, {:drop, :white, :queen, "d4"})

      game = drawn(:white, [{:restore, 2}], graveyard: %{white: [:queen]})
      assert {:error, :wrong_card} = Game.apply(game, {:move, :white, "e2-e4"})
    end
  end

  describe "restore" do
    test "events plus the initial board and deck rebuild the game, including a half-finished turn" do
      board = Board.initial()
      deck = [{:move, 3}, {:move, 1}]
      game = Game.new(board: board, deck: deck)

      {game, events} =
        play(game, [
          {:draw, :white},
          {:move, :white, "e2-e4"},
          {:move, :white, "e4-e5"},
          {:undo, :white}
        ])

      assert {:ok, restored} = Game.restore(Board.to_diagram(board), Deck.encode(deck), events)
      assert restored == game
      assert restored.remaining == 2
      assert Board.get(restored.staged, "e4") == {:white, :pawn}

      assert {:ok, restored, [{:move_undone, :white, 3}]} =
               Game.apply(restored, {:undo, :white})

      assert Board.get(restored.staged, "e2") == {:white, :pawn}
    end

    test "the deck left after a cycle is rebuilt" do
      board = Board.initial()
      deck = [{:move, 1}]
      game = Game.new(board: board, deck: deck)

      {game, events} =
        play(game, [
          {:draw, :white},
          {:move, :white, "e2-e4"},
          {:end_turn, :white},
          {:draw, :black}
        ])

      assert game.deck == []
      assert game.card == {:move, 1}
      assert game.turn == :black
      assert {:ok, restored} = Game.restore(board, ["1"], events)
      assert restored == game
    end

    test "checkmate in the log comes back as a finished game" do
      board = Board.from_diagram(@mate_in_one)
      deck = [{:move, 1}]
      game = Game.new(board: board, deck: deck)

      {game, events} =
        play(game, [
          {:draw, :white},
          {:move, :white, "g6-g7"},
          {:end_turn, :white}
        ])

      assert {:ok, restored} = Game.restore(board, deck, events)
      assert restored.status == :checkmate
      assert restored.winner == :white
      assert restored == game
    end

    test "a log that disagrees with the rules is rejected" do
      board = Board.initial()
      deck = [{:move, 1}]
      game = Game.new(board: board, deck: deck)
      {_game, [drawn, moved]} = play(game, [{:draw, :white}, {:move, :white, "e2-e4"}])

      assert {:error, {:diverged, ^moved, _forged}} =
               Game.restore(board, deck, [drawn, put_elem(moved, 4, 9)])
    end
  end

  describe "game over" do
    test "checkmate ends the game on the mover's commit" do
      game = drawn(:white, [{:move, 1}], @mate_in_one)
      {:ok, game, _} = Game.apply(game, {:move, :white, "g6-g7"})

      assert {:ok, game, [{:turn_ended, :white}, {:checkmate, :white}]} =
               Game.apply(game, {:end_turn, :white})

      assert game.status == :checkmate
      assert game.winner == :white
      assert {:error, :game_over} = Game.apply(game, {:draw, :black})
    end

    test "a move that leaves the opponent with no move and an empty graveyard is stalemate" do
      game = drawn(:white, [{:move, 1}], @stalemate_in_one)
      {:ok, game, _} = Game.apply(game, {:move, :white, "c5-b6"})

      assert {:ok, game, [{:turn_ended, :white}, {:stalemate}]} =
               Game.apply(game, {:end_turn, :white})

      assert game.status == :stalemate
      assert game.winner == nil
    end

    test "a non-empty graveyard keeps a stuck position going" do
      game =
        drawn(:white, [{:move, 1}], @stalemate_in_one, graveyard: %{black: [:pawn]})

      {:ok, game, _} = Game.apply(game, {:move, :white, "c5-b6"})

      assert {:ok, game, [{:turn_ended, :white}]} = Game.apply(game, {:end_turn, :white})
      assert game.status == :active
      assert game.turn == :black
      assert game.graveyard.black == [:pawn]
    end
  end

  defp play(game, commands) do
    Enum.reduce(commands, {game, []}, fn command, {game, events} ->
      {:ok, game, produced} = Game.apply(game, command)
      {game, events ++ produced}
    end)
  end

  defp drawn(color, deck, diagram \\ nil, opts \\ [])

  defp drawn(color, deck, diagram, opts) when is_binary(diagram) do
    drawn(color, deck, nil, Keyword.put(opts, :board, Board.from_diagram(diagram)))
  end

  defp drawn(color, deck, opts, []) when is_list(opts) do
    drawn(color, deck, nil, opts)
  end

  defp drawn(color, deck, nil, opts) when is_list(opts) do
    game = Game.new([deck: deck] ++ opts)
    {:ok, game, [{:card_drawn, ^color, _}]} = Game.apply(game, {:draw, color})
    game
  end
end
