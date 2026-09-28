defmodule Echo.UnoChess.Board do
  @moduledoc """
  A chess position: which piece sits on which square.

  Empty squares are absent. The map does not record whose turn it is, the
  deck, or the graveyard. Those belong to the game that owns this board.
  """

  alias Echo.UnoChess.Square

  @files 8
  @ranks 8
  @last_file @files - 1
  @last_rank @ranks - 1

  defstruct squares: %{}

  @type color :: :white | :black
  @type kind :: :king | :queen | :rook | :bishop | :knight | :pawn
  @type piece :: {color, kind}
  @type t :: %__MODULE__{squares: %{Square.t() => piece()}}

  @glyphs %{
    {:white, :king} => "K",
    {:white, :queen} => "Q",
    {:white, :rook} => "R",
    {:white, :bishop} => "B",
    {:white, :knight} => "N",
    {:white, :pawn} => "P",
    {:black, :king} => "k",
    {:black, :queen} => "q",
    {:black, :rook} => "r",
    {:black, :bishop} => "b",
    {:black, :knight} => "n",
    {:black, :pawn} => "p"
  }

  @by_glyph Map.new(@glyphs, fn {piece, glyph} -> {glyph, piece} end)

  @doc """
  Files on the live board. The a-file is index 0.
  """
  @spec files() :: pos_integer()
  def files, do: @files

  @doc """
  Ranks on the live board. Rank 1 is index 0.
  """
  @spec ranks() :: pos_integer()
  def ranks, do: @ranks

  @doc """
  The standard opening position.
  """
  @spec initial() :: t()
  def initial do
    from_diagram("""
    rnbqkbnr
    pppppppp
    ........
    ........
    ........
    ........
    PPPPPPPP
    RNBQKBNR
    """)
  end

  @doc """
  The piece on `square`, or `nil` when the square is empty.

  `square` may be `{file, rank}` or algebraic notation.
  """
  @spec get(t(), Square.t() | binary()) :: piece() | nil
  def get(%__MODULE__{squares: squares}, {file, rank})
      when file in 0..@last_file and rank in 0..@last_rank do
    Map.get(squares, {file, rank})
  end

  def get(%__MODULE__{}, {file, rank}) when is_integer(file) and is_integer(rank), do: nil

  def get(%__MODULE__{} = board, notation) when is_binary(notation) do
    get(board, Square.parse!(notation))
  end

  @doc """
  Puts `piece` on `square`. `nil` clears the square.
  """
  @spec put(t(), Square.t() | binary(), piece() | nil) :: t()
  def put(%__MODULE__{} = board, square, nil) do
    %{board | squares: Map.delete(board.squares, normalize!(square))}
  end

  def put(%__MODULE__{} = board, square, {color, kind} = piece)
      when color in [:white, :black] and
             kind in [:king, :queen, :rook, :bishop, :knight, :pawn] do
    %{board | squares: Map.put(board.squares, normalize!(square), piece)}
  end

  @doc """
  Pieces of `color` as `{square, kind}` pairs.
  """
  @spec pieces(t(), color()) :: [{Square.t(), kind()}]
  def pieces(%__MODULE__{squares: squares}, color) when color in [:white, :black] do
    for {square, {^color, kind}} <- squares, do: {square, kind}
  end

  @doc """
  Builds a board from a diagram, rank #{@ranks} first, as seen by White.

  Uppercase glyphs are White and lowercase glyphs are Black. `.` is empty.
  Cells may be packed (`rnbqkbnr`) or separated by spaces. A line may start
  with a rank number, and a trailing `a b c d e f g h` line is ignored.
  Lines that are blank or start with `#` are ignored.
  """
  @spec from_diagram(binary()) :: t()
  def from_diagram(text) when is_binary(text) do
    squares =
      text
      |> diagram_rows()
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {glyphs, index}, acc ->
        rank = @last_rank - index

        glyphs
        |> Enum.with_index()
        |> Enum.reduce(acc, fn
          {".", _file}, acc -> acc
          {glyph, file}, acc -> Map.put(acc, {file, rank}, Map.fetch!(@by_glyph, glyph))
        end)
      end)

    %__MODULE__{squares: squares}
  end

  @doc """
  Renders a board in the same diagram form `from_diagram/1` accepts.
  """
  @spec to_diagram(t()) :: String.t()
  def to_diagram(%__MODULE__{} = board) do
    label_width = @ranks |> Integer.to_string() |> byte_size()

    ranks =
      for rank <- @last_rank..0//-1 do
        cells =
          for file <- 0..@last_file do
            case get(board, {file, rank}) do
              nil -> "."
              piece -> Map.fetch!(@glyphs, piece)
            end
          end

        label = rank + 1 |> Integer.to_string() |> String.pad_leading(label_width)
        "#{label} #{Enum.join(cells, " ")}"
      end

    indent = String.duplicate(" ", label_width)
    Enum.join(ranks ++ ["#{indent} #{file_footer()}"], "\n")
  end

  defp diagram_rows(text) do
    rows =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&blank_or_comment?/1)
      |> Enum.reject(&file_labels?/1)
      |> Enum.map(&strip_rank/1)
      |> Enum.map(&cells/1)

    if length(rows) != @ranks do
      raise ArgumentError, "diagram must have #{@ranks} ranks, got #{length(rows)}"
    end

    rows
  end

  defp blank_or_comment?(""), do: true
  defp blank_or_comment?("#" <> _), do: true
  defp blank_or_comment?(_), do: false

  defp file_labels?(line), do: line == file_footer()

  defp file_footer do
    Enum.map_join(0..@last_file, " ", fn file -> <<file + ?a>> end)
  end

  defp strip_rank(line) do
    case Regex.run(~r/^(\d+)\s+/, line) do
      [prefix, number] ->
        case Integer.parse(number) do
          {n, ""} when n in 1..@ranks -> String.replace_prefix(line, prefix, "")
          _ -> line
        end

      _ ->
        line
    end
  end

  defp cells(line) do
    glyphs =
      case String.split(line, ~r/\s+/, trim: true) do
        [packed] when byte_size(packed) == @files -> String.graphemes(packed)
        parts -> parts
      end

    if length(glyphs) != @files do
      raise ArgumentError, "diagram rank must have #{@files} squares, got #{inspect(line)}"
    end

    Enum.map(glyphs, fn glyph ->
      cond do
        glyph == "." -> "."
        Map.has_key?(@by_glyph, glyph) -> glyph
        true -> raise ArgumentError, "unknown piece #{inspect(glyph)} in #{inspect(line)}"
      end
    end)
  end

  defp normalize!(square) when is_binary(square), do: Square.parse!(square)

  defp normalize!({file, rank} = square) when file in 0..@last_file and rank in 0..@last_rank,
    do: square
end
