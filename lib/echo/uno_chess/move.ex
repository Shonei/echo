defmodule Echo.UnoChess.Move do
  @moduledoc """
  A piece relocation. `promotion` is set when a pawn promotes.
  """

  alias Echo.UnoChess.Square

  defstruct [:from, :to, promotion: nil]

  @type t :: %__MODULE__{
          from: Square.t(),
          to: Square.t(),
          promotion: :queen | :rook | :bishop | :knight | nil
        }

  @promotions %{"q" => :queen, "r" => :rook, "b" => :bishop, "n" => :knight}
  @promotion_letters Map.new(@promotions, fn {letter, kind} -> {kind, letter} end)

  @doc """
  Decodes `"e2-e4"`, `"e4 - e5"`, `"e7-e8q"`, or `"e10-e11"`.

  The hyphen keeps a two-digit rank unambiguous. A promotion is a trailing
  `q`, `r`, `b`, or `n` on the destination square.
  """
  @spec parse(term()) :: {:ok, t()} | :error
  def parse(notation) when is_binary(notation) do
    case notation |> String.trim() |> String.downcase() |> String.split(~r/\s*-\s*/, parts: 2) do
      [from, to] ->
        {to, promo} = split_promotion(to)

        with {:ok, from} <- Square.parse(from),
             {:ok, to} <- Square.parse(to),
             {:ok, promotion} <- promotion(promo) do
          {:ok, %__MODULE__{from: from, to: to, promotion: promotion}}
        end

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  @doc """
  Encodes a move as `"e2-e4"` or `"e7-e8q"`.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{from: from, to: to, promotion: nil}) do
    Square.encode(from) <> "-" <> Square.encode(to)
  end

  def encode(%__MODULE__{from: from, to: to, promotion: promotion}) do
    Square.encode(from) <> "-" <> Square.encode(to) <> Map.fetch!(@promotion_letters, promotion)
  end

  defp split_promotion(to) do
    case String.split_at(to, -1) do
      {square, letter} when letter in ["q", "r", "b", "n"] ->
        if Square.parse(square) == :error, do: {to, ""}, else: {square, letter}

      _ ->
        {to, ""}
    end
  end

  defp promotion(""), do: {:ok, nil}

  defp promotion(letter) do
    case Map.fetch(@promotions, letter) do
      {:ok, kind} -> {:ok, kind}
      :error -> :error
    end
  end
end
