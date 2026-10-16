defmodule Echo.UnoChess.DeckTest do
  use ExUnit.Case, async: true

  alias Echo.UnoChess.Deck

  test "the standard pile is 64 cards with the locked counts" do
    deck = Deck.standard()

    assert length(deck) == 64

    assert Enum.frequencies(deck) == %{
             {:move, 1} => 20,
             {:move, 2} => 27,
             {:move, 3} => 6,
             {:restore, 2} => 4,
             {:restore, 4} => 2,
             :reverse => 5
           }
  end

  test "codes round-trip through the one-character alphabet" do
    deck = Deck.standard()

    assert Deck.encode(deck) |> Enum.frequencies() == %{
             "1" => 20,
             "2" => 27,
             "3" => 6,
             "T" => 4,
             "F" => 2,
             "R" => 5
           }

    assert Deck.decode(Deck.encode(deck)) == {:ok, deck}
    assert Deck.decode(["t", "f", "r"]) == {:ok, [{:restore, 2}, {:restore, 4}, :reverse]}
    assert Deck.decode(["9"]) == {:error, :invalid_card}
  end

  test "shuffle uses the supplied function and leaves the standard pile ordered" do
    assert Deck.shuffle([:reverse, {:move, 1}], &Enum.reverse/1) == [{:move, 1}, :reverse]
    assert Deck.standard() |> Deck.shuffle(&Function.identity/1) == Deck.standard()
  end
end
