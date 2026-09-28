defmodule Echo.UnoChess.BoardTest do
  use ExUnit.Case, async: true

  alias Echo.UnoChess.Board

  test "initial position places the armies on their home ranks" do
    board = Board.initial()

    assert Board.get(board, "a1") == {:white, :rook}
    assert Board.get(board, "e1") == {:white, :king}
    assert Board.get(board, "a2") == {:white, :pawn}
    assert Board.get(board, "e8") == {:black, :king}
    assert Board.get(board, "a7") == {:black, :pawn}
    assert Board.get(board, "e4") == nil
  end

  test "a diagram survives a round trip through text" do
    board = Board.initial()

    assert Board.from_diagram(Board.to_diagram(board)) == board
  end

  test "a short diagram is rejected" do
    assert_raise ArgumentError, ~r/8 ranks/, fn ->
      Board.from_diagram("""
      8 k . . . . . . .
      7 . . . . . . . .
      """)
    end
  end
end
