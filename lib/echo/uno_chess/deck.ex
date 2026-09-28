defmodule Echo.UnoChess.Deck do
  @moduledoc """
  The 64-card Uno Chess pile.

  `standard/0` is ordered and unshuffled so a game test can depend on it.
  The process that starts a real game shuffles once, with `shuffle/1`, and
  stores that order. A stored deck is a list of one-character codes:

    * `1`, `2`, `3` — Move cards
    * `T` — Restore 2
    * `F` — Restore 4
    * `R` — Reverse
  """

  @type card :: {:move, 1 | 2 | 3} | {:restore, 2 | 4} | :reverse

  @counts [
    {{:move, 1}, 15},
    {{:move, 2}, 24},
    {{:move, 3}, 5},
    {{:restore, 2}, 10},
    {{:restore, 4}, 5},
    {:reverse, 5}
  ]

  @doc """
  One copy of each card, in count order. 64 cards, none of them shuffled.
  """
  @spec standard() :: [card()]
  def standard do
    Enum.flat_map(@counts, fn {card, count} -> List.duplicate(card, count) end)
  end

  @doc """
  Shuffles `deck` with `rng`. `rng` defaults to `Enum.shuffle/1`.
  """
  @spec shuffle([card()], ([card()] -> [card()])) :: [card()]
  def shuffle(deck \\ standard(), rng \\ &Enum.shuffle/1) do
    rng.(deck)
  end

  @codes [
    {{:move, 1}, "1"},
    {{:move, 2}, "2"},
    {{:move, 3}, "3"},
    {{:restore, 2}, "T"},
    {{:restore, 4}, "F"},
    {:reverse, "R"}
  ]

  @encode Map.new(@codes)
  @decode Map.new(@codes, fn {card, code} -> {code, card} end)

  @doc """
  Encodes cards as the one-character codes stored for a game.
  """
  @spec encode([card()]) :: [String.t()]
  def encode(cards) when is_list(cards), do: Enum.map(cards, &Map.fetch!(@encode, &1))

  @doc """
  Decodes a stored deck. Tuples that are already cards pass through.
  """
  @spec decode([card() | String.t()]) :: {:ok, [card()]} | {:error, :invalid_card}
  def decode(cards) when is_list(cards) do
    Enum.reduce_while(cards, {:ok, []}, fn card, {:ok, acc} ->
      case decode_one(card) do
        {:ok, card} -> {:cont, {:ok, [card | acc]}}
        :error -> {:halt, {:error, :invalid_card}}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      {:error, :invalid_card} = error -> error
    end
  end

  defp decode_one({:move, n} = card) when n in [1, 2, 3], do: {:ok, card}
  defp decode_one({:restore, n} = card) when n in [2, 4], do: {:ok, card}
  defp decode_one(:reverse), do: {:ok, :reverse}

  defp decode_one(code) when is_binary(code) do
    Map.fetch(@decode, String.upcase(code))
  end

  defp decode_one(_card), do: :error
end
