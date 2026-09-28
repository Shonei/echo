defmodule Echo.UnoChess.Square do
  @moduledoc """
  A board square as `{file, rank}`.

  File `0` is the a-file and rank `0` is rank 1. Names are one file letter
  and a rank of one or two digits, from `"a1"` through `"z99"`.
  `on_board?/1` is narrower: it uses the live board size from
  `Echo.UnoChess.Board`.
  """

  alias Echo.UnoChess.Board

  @max_files 26
  @max_rank 99
  @last_file ?a + @max_files - 1
  @last_file_index @max_files - 1
  @last_rank_index @max_rank - 1
  @rank_pattern ~r/\A[1-9]\d?\z/

  @type t :: {0..25, 0..98}

  @doc """
  Decodes `"e4"` or `"e10"`. Ranks run from 1 to #{@max_rank}. A second file
  letter, a third rank digit, and a leading zero are rejected.
  """
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(notation) when is_binary(notation) do
    case String.downcase(String.trim(notation)) do
      <<file, rank::binary>> when file in ?a..@last_file ->
        parse_rank(file, rank)

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  @doc """
  Decodes an algebraic square, raising `ArgumentError` when it is not one.
  """
  @spec parse!(binary()) :: t()
  def parse!(notation) do
    case parse(notation) do
      {:ok, square} -> square
      :error -> raise ArgumentError, "invalid square: #{inspect(notation)}"
    end
  end

  @doc """
  Encodes a square as algebraic notation. Rank 10 is `"e10"`, not `"e010"`.
  """
  @spec encode(t()) :: String.t()
  def encode({file, rank})
      when file in 0..@last_file_index and rank in 0..@last_rank_index do
    <<file + ?a>> <> Integer.to_string(rank + 1)
  end

  @doc """
  Whether the coordinates sit on the live board (`Board.files/0` by `Board.ranks/0`).
  """
  @spec on_board?(term()) :: boolean()
  def on_board?({file, rank}) when is_integer(file) and is_integer(rank) do
    file in 0..(Board.files() - 1) and rank in 0..(Board.ranks() - 1)
  end

  def on_board?(_), do: false

  defp parse_rank(file, rank) do
    with true <- Regex.match?(@rank_pattern, rank),
         {number, ""} <- Integer.parse(rank),
         true <- number in 1..@max_rank do
      {:ok, {file - ?a, number - 1}}
    else
      _ -> :error
    end
  end
end
