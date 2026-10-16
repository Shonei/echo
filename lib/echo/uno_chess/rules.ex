defmodule Echo.UnoChess.Rules do
  @moduledoc """
  Referee for one chess relocation or one graveyard drop.

  `apply_move/3` checks piece shape, a clear path, and captures. It accepts a
  move that leaves the mover's king in check. Call `in_check?/2` when a turn
  commits. Castling and en passant are not part of this ruleset.

  `:path_blocked` means a sliding piece's intervening square is occupied, or
  the square a pawn skips on a double step is occupied. A pawn step onto an
  occupied square is `:illegal_geometry`.
  """

  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Move
  alias Echo.UnoChess.Square

  @type reason ::
          :invalid_move
          | :off_board
          | :no_piece
          | :wrong_color
          | :friendly_fire
          | :cannot_capture_king
          | :illegal_geometry
          | :path_blocked
          | :promotion_required
          | :promotion_illegal
          | :occupied
          | :off_home_half
          | :illegal_pawn_drop
          | :invalid_piece

  @drop_kinds [:queen, :rook, :bishop, :knight, :pawn]
  @promotion_kinds [:queen, :rook, :bishop, :knight]

  @doc """
  Applies a pseudo-legal move for `color`.

  `move` is a `Move` or algebraic text such as `"e2-e4"` or `"e7-e8q"`.
  Returns the updated board and the captured piece, or `nil` when the
  destination was empty.
  """
  @spec apply_move(Board.t(), Board.color(), Move.t() | binary()) ::
          {:ok, Board.t(), Board.piece() | nil} | {:error, reason()}
  def apply_move(%Board{} = board, color, move) when is_binary(move) do
    case Move.parse(move) do
      {:ok, move} -> apply_move(board, color, move)
      :error -> {:error, :invalid_move}
    end
  end

  def apply_move(%Board{} = board, color, %Move{} = move) when color in [:white, :black] do
    with :ok <- validate_squares(move),
         {:ok, kind} <- own_piece(board, color, move.from),
         :ok <- destination(board, color, move.to),
         :ok <- geometry(board, color, kind, move),
         :ok <- promotion(kind, color, move) do
      captured = Board.get(board, move.to)

      next =
        board
        |> Board.put(move.from, nil)
        |> Board.put(move.to, {color, placed_kind(kind, move)})

      {:ok, next, captured}
    end
  end

  @doc """
  Places `kind` on an empty square in that color's home half.

  White drops on the lower half of the board and Black on the upper half.
  Pawns cannot be dropped on the first or last rank. The graveyard check
  belongs to the caller.
  """
  @spec apply_drop(Board.t(), Board.color(), Board.kind(), Square.t() | binary()) ::
          {:ok, Board.t()} | {:error, reason()}
  def apply_drop(%Board{} = board, color, kind, square) when is_binary(square) do
    case Square.parse(square) do
      {:ok, square} -> apply_drop(board, color, kind, square)
      :error -> {:error, :off_board}
    end
  end

  def apply_drop(%Board{} = board, color, kind, square) do
    cond do
      color not in [:white, :black] or kind not in @drop_kinds ->
        {:error, :invalid_piece}

      not Square.on_board?(square) ->
        {:error, :off_board}

      Board.get(board, square) != nil ->
        {:error, :occupied}

      not home_half?(color, square) ->
        {:error, :off_home_half}

      kind == :pawn and not pawn_drop_rank?(square) ->
        {:error, :illegal_pawn_drop}

      true ->
        {:ok, Board.put(board, square, {color, kind})}
    end
  end

  @doc """
  Whether any piece of `by_color` attacks `square`.

  The square may be empty. Pawn attacks are the diagonal captures, not pushes.
  """
  @spec square_attacked?(Board.t(), Square.t() | binary(), Board.color()) :: boolean()
  def square_attacked?(%Board{} = board, square, by_color) when is_binary(square) do
    square_attacked?(board, Square.parse!(square), by_color)
  end

  def square_attacked?(%Board{} = board, square, by_color) when by_color in [:white, :black] do
    Enum.any?(Board.pieces(board, by_color), fn {from, kind} ->
      attacks?(board, by_color, kind, from, square)
    end)
  end

  @doc """
  Whether `color`'s king is attacked. Raises if that king is missing.
  """
  @spec in_check?(Board.t(), Board.color()) :: boolean()
  def in_check?(%Board{} = board, color) when color in [:white, :black] do
    square_attacked?(board, king_square!(board, color), opposite(color))
  end

  @doc """
  Every geometrically legal move for `color`, including moves that leave the king in check.
  """
  @spec pseudo_legal_moves(Board.t(), Board.color()) :: [Move.t()]
  def pseudo_legal_moves(%Board{} = board, color) when color in [:white, :black] do
    board
    |> Board.pieces(color)
    |> Enum.flat_map(fn {from, kind} ->
      kind
      |> candidates(color, from, board)
      |> Enum.filter(&match?({:ok, _, _}, apply_move(board, color, &1)))
    end)
    |> Enum.sort_by(&Move.encode/1)
  end

  @doc """
  Pseudo-legal moves that still leave `color`'s king safe.
  """
  @spec legal_moves(Board.t(), Board.color()) :: [Move.t()]
  def legal_moves(%Board{} = board, color) when color in [:white, :black] do
    Enum.filter(pseudo_legal_moves(board, color), fn move ->
      {:ok, next, _} = apply_move(board, color, move)
      not in_check?(next, color)
    end)
  end

  @doc """
  Whether `color` is in check and every reply still leaves the king in check.
  """
  @spec checkmate?(Board.t(), Board.color()) :: boolean()
  def checkmate?(%Board{} = board, color) when color in [:white, :black] do
    in_check?(board, color) and legal_moves(board, color) == []
  end

  @doc """
  Whether `color` is not in check and has no legal move.

  The graveyard is not on the board. A game treats this as a draw only when
  that side's graveyard is also empty.
  """
  @spec stalemate?(Board.t(), Board.color()) :: boolean()
  def stalemate?(%Board{} = board, color) when color in [:white, :black] do
    not in_check?(board, color) and legal_moves(board, color) == []
  end

  @doc """
  The other color.
  """
  @spec opposite(Board.color()) :: Board.color()
  def opposite(:white), do: :black
  def opposite(:black), do: :white

  defp validate_squares(%Move{from: from, to: to}) do
    cond do
      not Square.on_board?(from) or not Square.on_board?(to) -> {:error, :off_board}
      from == to -> {:error, :illegal_geometry}
      true -> :ok
    end
  end

  defp own_piece(board, color, from) do
    case Board.get(board, from) do
      {^color, kind} -> {:ok, kind}
      {_other, _kind} -> {:error, :wrong_color}
      nil -> {:error, :no_piece}
    end
  end

  defp destination(board, color, to) do
    case Board.get(board, to) do
      nil -> :ok
      {^color, _} -> {:error, :friendly_fire}
      {_other, :king} -> {:error, :cannot_capture_king}
      {_other, _kind} -> :ok
    end
  end

  defp geometry(board, color, :pawn, %Move{from: from, to: to}) do
    pawn_geometry(board, color, from, to)
  end

  defp geometry(_board, _color, kind, %Move{from: from, to: to}) when kind in [:king, :knight] do
    if shape?(kind, from, to), do: :ok, else: {:error, :illegal_geometry}
  end

  defp geometry(board, _color, kind, %Move{from: from, to: to}) do
    cond do
      not shape?(kind, from, to) -> {:error, :illegal_geometry}
      not path_clear?(board, from, to) -> {:error, :path_blocked}
      true -> :ok
    end
  end

  defp pawn_geometry(board, color, {file, rank}, {to_file, to_rank}) do
    forward = forward(color)
    file_delta = to_file - file
    rank_delta = to_rank - rank
    target = Board.get(board, {to_file, to_rank})

    cond do
      file_delta == 0 and rank_delta == forward and target == nil ->
        :ok

      file_delta == 0 and rank_delta == forward * 2 and rank == pawn_home(color) ->
        cond do
          Board.get(board, {file, rank + forward}) != nil -> {:error, :path_blocked}
          target != nil -> {:error, :illegal_geometry}
          true -> :ok
        end

      abs(file_delta) == 1 and rank_delta == forward and enemy?(target, color) ->
        :ok

      true ->
        {:error, :illegal_geometry}
    end
  end

  defp enemy?({color, _kind}, color), do: false
  defp enemy?({_other, _kind}, _color), do: true
  defp enemy?(nil, _color), do: false

  defp promotion(:pawn, color, %Move{to: {_file, rank}, promotion: promotion}) do
    cond do
      promotion_rank?(color, rank) and promotion in @promotion_kinds -> :ok
      promotion_rank?(color, rank) -> {:error, :promotion_required}
      promotion == nil -> :ok
      true -> {:error, :promotion_illegal}
    end
  end

  defp promotion(_kind, _color, %Move{promotion: nil}), do: :ok
  defp promotion(_kind, _color, %Move{}), do: {:error, :promotion_illegal}

  defp placed_kind(:pawn, %Move{promotion: promotion}) when promotion != nil, do: promotion
  defp placed_kind(kind, _move), do: kind

  defp shape?(:king, from, to), do: chebyshev(from, to) == 1

  defp shape?(:knight, {file, rank}, {to_file, to_rank}) do
    {abs(to_file - file), abs(to_rank - rank)} in [{1, 2}, {2, 1}]
  end

  defp shape?(:bishop, from, to), do: diagonal?(from, to)
  defp shape?(:rook, from, to), do: orthogonal?(from, to)
  defp shape?(:queen, from, to), do: diagonal?(from, to) or orthogonal?(from, to)

  defp diagonal?({file, rank}, {to_file, to_rank}) do
    file_delta = abs(to_file - file)
    rank_delta = abs(to_rank - rank)
    file_delta == rank_delta and file_delta > 0
  end

  defp orthogonal?({file, rank}, {file, to_rank}), do: rank != to_rank
  defp orthogonal?({file, rank}, {to_file, rank}), do: file != to_file
  defp orthogonal?(_from, _to), do: false

  defp chebyshev({file, rank}, {to_file, to_rank}) do
    max(abs(to_file - file), abs(to_rank - rank))
  end

  defp path_clear?(board, from, to) do
    Enum.all?(between(from, to), &(Board.get(board, &1) == nil))
  end

  defp between({file, rank}, {to_file, to_rank}) do
    file_step = sign(to_file - file)
    rank_step = sign(to_rank - rank)

    Stream.iterate({file + file_step, rank + rank_step}, fn {next_file, next_rank} ->
      {next_file + file_step, next_rank + rank_step}
    end)
    |> Enum.take_while(&(&1 != {to_file, to_rank}))
  end

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_n), do: -1

  defp attacks?(_board, color, :pawn, from, target), do: pawn_attacks?(color, from, target)

  defp attacks?(_board, _color, kind, from, target) when kind in [:king, :knight] do
    shape?(kind, from, target)
  end

  defp attacks?(board, _color, kind, from, target) do
    shape?(kind, from, target) and path_clear?(board, from, target)
  end

  defp pawn_attacks?(color, {file, rank}, {to_file, to_rank}) do
    abs(to_file - file) == 1 and to_rank - rank == forward(color)
  end

  defp forward(:white), do: 1
  defp forward(:black), do: -1
  defp pawn_home(:white), do: 1
  defp pawn_home(:black), do: Board.ranks() - 2

  defp promotion_rank?(:white, rank), do: rank == Board.ranks() - 1
  defp promotion_rank?(:black, 0), do: true
  defp promotion_rank?(_color, _rank), do: false

  defp home_half?(:white, {_file, rank}), do: rank in 0..(div(Board.ranks(), 2) - 1)
  defp home_half?(:black, {_file, rank}), do: rank in div(Board.ranks(), 2)..(Board.ranks() - 1)
  defp pawn_drop_rank?({_file, rank}), do: rank in 1..(Board.ranks() - 2)

  defp king_square!(board, color) do
    Enum.find_value(board.squares, fn
      {square, {^color, :king}} -> square
      _other -> nil
    end) || raise ArgumentError, "#{color} king is missing from the board"
  end

  defp candidates(:pawn, color, {file, rank} = from, _board) do
    step = forward(color)

    [{0, step}, {0, step * 2}, {-1, step}, {1, step}]
    |> Enum.map(fn {file_delta, rank_delta} -> {file + file_delta, rank + rank_delta} end)
    |> Enum.filter(&Square.on_board?/1)
    |> Enum.flat_map(&promotion_moves(color, from, &1))
  end

  defp candidates(:knight, _color, from, _board) do
    [{1, 2}, {2, 1}, {1, -2}, {2, -1}, {-1, 2}, {-2, 1}, {-1, -2}, {-2, -1}]
    |> Enum.map(fn {file_delta, rank_delta} -> shift(from, file_delta, rank_delta) end)
    |> onboard_moves(from)
  end

  defp candidates(:king, _color, from, _board) do
    for file_delta <- -1..1,
        rank_delta <- -1..1,
        {file_delta, rank_delta} != {0, 0} do
      shift(from, file_delta, rank_delta)
    end
    |> onboard_moves(from)
  end

  defp candidates(kind, _color, from, board) when kind in [:bishop, :rook, :queen] do
    kind
    |> directions()
    |> Enum.flat_map(&ray(board, from, &1))
    |> Enum.map(&%Move{from: from, to: &1})
  end

  defp promotion_moves(color, from, {_file, rank} = to) do
    if promotion_rank?(color, rank) do
      Enum.map(@promotion_kinds, &%Move{from: from, to: to, promotion: &1})
    else
      [%Move{from: from, to: to}]
    end
  end

  defp onboard_moves(squares, from) do
    squares
    |> Enum.filter(&Square.on_board?/1)
    |> Enum.map(&%Move{from: from, to: &1})
  end

  defp ray(board, from, {file_step, rank_step}) do
    from
    |> Stream.iterate(&shift(&1, file_step, rank_step))
    |> Stream.drop(1)
    |> Enum.reduce_while([], fn square, acc ->
      cond do
        not Square.on_board?(square) -> {:halt, acc}
        Board.get(board, square) == nil -> {:cont, [square | acc]}
        true -> {:halt, [square | acc]}
      end
    end)
  end

  defp directions(:bishop), do: [{1, 1}, {1, -1}, {-1, 1}, {-1, -1}]
  defp directions(:rook), do: [{1, 0}, {-1, 0}, {0, 1}, {0, -1}]
  defp directions(:queen), do: directions(:bishop) ++ directions(:rook)

  defp shift({file, rank}, file_delta, rank_delta) do
    {file + file_delta, rank + rank_delta}
  end
end
