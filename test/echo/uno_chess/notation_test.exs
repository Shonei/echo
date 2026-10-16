defmodule Echo.UnoChess.NotationTest do
  use ExUnit.Case, async: true

  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Move
  alias Echo.UnoChess.Square

  test "the live board is 8 by 8" do
    assert Board.files() == 8
    assert Board.ranks() == 8
    assert Square.on_board?({0, 0})
    assert Square.on_board?({7, 7})
    refute Square.on_board?({8, 0})
    refute Square.on_board?({0, 8})
  end

  test "a square is one file letter and at most two rank digits" do
    assert Square.parse("e4") == {:ok, {4, 3}}
    assert Square.parse("e10") == {:ok, {4, 9}}
    assert Square.parse("z99") == {:ok, {25, 98}}
    assert Square.encode({4, 3}) == "e4"
    assert Square.encode({4, 9}) == "e10"

    assert Square.parse("e100") == :error
    assert Square.parse("aa1") == :error
    assert Square.parse("e0") == :error
    assert Square.parse("e01") == :error

    {:ok, tenth} = Square.parse("e10")
    refute Square.on_board?(tenth)
  end

  test "moves are separated by a hyphen, with optional spaces and a promotion letter" do
    assert {:ok, %Move{from: {4, 3}, to: {4, 4}, promotion: nil}} = Move.parse("e4-e5")
    assert {:ok, %Move{from: {4, 3}, to: {4, 4}}} = Move.parse("e4 - e5")
    assert {:ok, %Move{promotion: :queen}} = Move.parse("e7-e8q")
    assert {:ok, %Move{promotion: :rook}} = Move.parse("E7-E8R")
    assert {:ok, %Move{from: {4, 9}, to: {4, 10}, promotion: nil}} = Move.parse("e10-e11")

    {:ok, quiet} = Move.parse("e4-e5")
    {:ok, promoted} = Move.parse("e7-e8q")
    {:ok, tenth} = Move.parse("e10-e11")
    assert Move.encode(quiet) == "e4-e5"
    assert Move.encode(promoted) == "e7-e8q"
    assert Move.encode(tenth) == "e10-e11"

    assert Move.parse("e2e4") == :error
    assert Move.parse("e100-e4") == :error
    assert Move.parse("aa4-b5") == :error
  end
end
