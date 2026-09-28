defmodule Echo.UnoChess.Scenario do
  @moduledoc """
  Assertions for Uno Chess positions.

  Copy a test and edit the diagram. Rank 8 is the first line. White's pieces
  are capitals, Black's are lowercase, and `.` is an empty square. A line may
  start with its rank number. Moves are written `"e2-e4"` or `"e7-e8q"`.

  Check and mate scenarios need both kings on the board. `in_check?/2` raises
  when the king it is asked about is missing.

      8 . . . . k . . .
      7 . . . . . . . .
      6 . . . . . . . .
      5 . . . . . . . .
      4 . . . . P . . .
      3 . . . . . . . .
      2 . . . . . . . .
      1 . . . . K . . .
        a b c d e f g h

  `assert_legal/4` accepts `:captured`, `:piece_at`, and `:empty`.
  `:captured` is `{color, kind}` or `nil`. `:piece_at` is
  `{"e5", {:white, :pawn}}`. `:empty` is the square the piece left.
  """

  import ExUnit.Assertions

  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Move
  alias Echo.UnoChess.Rules

  def assert_legal(diagram, color, move, opts \\ []) do
    board = Board.from_diagram(diagram)

    case Rules.apply_move(board, color, move) do
      {:ok, next, captured} ->
        if Keyword.has_key?(opts, :captured) do
          assert captured == opts[:captured], Board.to_diagram(next)
        end

        case Keyword.fetch(opts, :piece_at) do
          {:ok, {square, piece}} ->
            assert Board.get(next, square) == piece, Board.to_diagram(next)

          :error ->
            :ok
        end

        case Keyword.fetch(opts, :empty) do
          {:ok, square} ->
            assert Board.get(next, square) == nil, Board.to_diagram(next)

          :error ->
            :ok
        end

        next

      {:error, reason} ->
        flunk("""
        expected #{color} #{move} to be legal, got #{inspect(reason)}
        #{Board.to_diagram(board)}
        """)
    end
  end

  def assert_illegal(diagram, color, move, reason) do
    board = Board.from_diagram(diagram)

    assert {:error, ^reason} = Rules.apply_move(board, color, move), """
    #{color} #{move} against this board:
    #{Board.to_diagram(board)}
    """
  end

  def assert_check(diagram, color) do
    board = Board.from_diagram(diagram)

    assert Rules.in_check?(board, color), """
    expected #{color} to be in check
    #{Board.to_diagram(board)}
    """
  end

  def refute_check(diagram, color) do
    board = Board.from_diagram(diagram)

    refute Rules.in_check?(board, color), """
    expected #{color} to be safe
    #{Board.to_diagram(board)}
    """
  end

  def assert_mate(diagram, color) do
    board = Board.from_diagram(diagram)

    assert Rules.in_check?(board, color), """
    expected #{color} to be in check
    #{Board.to_diagram(board)}
    """

    assert Rules.checkmate?(board, color), """
    expected checkmate, legal replies: #{inspect(encoded(board, color, :legal))}
    #{Board.to_diagram(board)}
    """
  end

  def refute_mate(diagram, color) do
    board = Board.from_diagram(diagram)

    refute Rules.checkmate?(board, color), """
    expected #{color} to have a defense
    #{Board.to_diagram(board)}
    """
  end

  def assert_stalemate(diagram, color) do
    board = Board.from_diagram(diagram)

    refute Rules.in_check?(board, color), """
    expected #{color} to be safe
    #{Board.to_diagram(board)}
    """

    assert Rules.stalemate?(board, color), """
    expected stalemate, legal replies: #{inspect(encoded(board, color, :legal))}
    #{Board.to_diagram(board)}
    """
  end

  def assert_drop(diagram, color, kind, square) do
    board = Board.from_diagram(diagram)

    assert {:ok, next} = Rules.apply_drop(board, color, kind, square), Board.to_diagram(board)
    assert Board.get(next, square) == {color, kind}
    next
  end

  def assert_drop_illegal(diagram, color, kind, square, reason) do
    board = Board.from_diagram(diagram)

    assert {:error, ^reason} = Rules.apply_drop(board, color, kind, square),
           Board.to_diagram(board)
  end

  def encoded_moves(diagram, color, kind \\ :legal) do
    diagram
    |> Board.from_diagram()
    |> encoded(color, kind)
  end

  defp encoded(board, color, :legal),
    do: Enum.map(Rules.legal_moves(board, color), &Move.encode/1)

  defp encoded(board, color, :pseudo),
    do: Enum.map(Rules.pseudo_legal_moves(board, color), &Move.encode/1)
end
