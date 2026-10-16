defmodule Echo.UnoChess.Game do
  @moduledoc """
  Turn state machine for one Uno Chess game.

  `apply/2` takes a `t:command/0` and returns the next game plus the
  `t:event/0` facts that happened. It does not touch the database or the
  network. A later process can broadcast those facts and store the returned
  game.

  Facts are public. Both players see every card and every staged move.

      {:ok, game, [{:card_drawn, :white, {:move, 3}}]} =
        Game.apply(game, {:draw, :white})

      {:ok, game, [{:piece_moved, :white, "e2-e4", nil, 2}]} =
        Game.apply(game, {:move, :white, "e2-e4"})

      {:ok, game, [{:move_undone, :white, 3}]} =
        Game.apply(game, {:undo, :white})

  `{:undo, color}` rolls back one sub-move or drop. The drawn card stays.
  `{:end_turn, color}` commits what is still staged. After that, undo is gone.

  `restore/3` rebuilds a game from the initial board, the initial deck, and
  the events in order. Turn, graveyard, charges, and the remaining deck are
  not stored separately. They come back from that fold.
  """

  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Deck
  alias Echo.UnoChess.Rules

  import Kernel, except: [apply: 2]

  defstruct board: nil,
            staged: nil,
            graveyard: %{white: [], black: []},
            deck: [],
            discard: [],
            turn: :white,
            card: nil,
            remaining: 0,
            history: [],
            status: :active,
            winner: nil,
            rng: &Function.identity/1

  @typedoc """
  A card in the deck or in a player's hand.

    * `{:move, n}` — play exactly `n` sub-moves, `n` in 1, 2, or 3.
    * `{:restore, n}` — drop up to `n` of your own captured pieces, `n` in 2 or 4.
    * `:reverse` — discard immediately and draw again. It never becomes the held card.
  """
  @type card :: Deck.card()

  @typedoc """
  A player action passed to `apply/2`.

  The color is who is asking, and it has to be the side to move.

    * `{:draw, color}` — take the next card. Legal only when no card is held.
    * `{:move, color, "e2-e4"}` — one sub-move while holding a Move card.
    * `{:drop, color, :queen, "d4"}` — place one graveyard piece while holding a Restore card.
    * `{:undo, color}` — take back the latest sub-move or drop. One call undoes one action.
    * `{:end_turn, color}` — commit the staged board and pass the turn.
  """
  @type command ::
          {:draw, Board.color()}
          | {:move, Board.color(), String.t()}
          | {:drop, Board.color(), Board.kind(), String.t()}
          | {:undo, Board.color()}
          | {:end_turn, Board.color()}

  @typedoc """
  A fact returned by a successful `apply/2`. The result is a list of these.

  Checkmate and stalemate are a second element after `{:turn_ended, color}`.

    * `{:card_drawn, color, card}` — the card White or Black just drew.
    * `{:piece_moved, color, "e2-e4", captured, remaining}` — one sub-move landed.
      `captured` is `{color, kind}` or `nil`. `remaining` is charges left after the move.
    * `{:piece_dropped, color, kind, "d4", remaining}` — one restore charge spent.
    * `{:move_undone, color, remaining}` — the latest sub-move or drop was rolled back.
      `remaining` counts the charges after the undo.
    * `{:turn_ended, color}` — that side's staged board is now the committed board.
    * `{:checkmate, winner}` — the commit mated the opponent.
    * `{:stalemate}` — the opponent has no legal move and an empty graveyard.
  """
  @type event ::
          {:card_drawn, Board.color(), card()}
          | {:piece_moved, Board.color(), String.t(), Board.piece() | nil, non_neg_integer()}
          | {:piece_dropped, Board.color(), Board.kind(), String.t(), non_neg_integer()}
          | {:move_undone, Board.color(), non_neg_integer()}
          | {:turn_ended, Board.color()}
          | {:checkmate, Board.color()}
          | {:stalemate}

  @type t :: %__MODULE__{
          board: Board.t(),
          staged: Board.t(),
          graveyard: %{white: [Board.kind()], black: [Board.kind()]},
          deck: [card()],
          discard: [card()],
          turn: Board.color() | nil,
          card: card() | nil,
          remaining: non_neg_integer(),
          history: [map()],
          status: :active | :checkmate | :stalemate,
          winner: Board.color() | nil,
          rng: ([card()] -> [card()])
        }

  @doc """
  Builds a game. The deck is used in the order given. Shuffle once, with
  `Deck.shuffle/1`, before storing that order. Replay uses the stored order
  and does not shuffle again.

  When a draw finds an empty deck, the discard pile becomes the deck in its
  current order, newest card first. `rng` replaces that order in tests.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    board = Keyword.get(opts, :board, Board.initial())

    %__MODULE__{
      board: board,
      staged: board,
      graveyard: Map.merge(%{white: [], black: []}, Keyword.get(opts, :graveyard, %{})),
      deck: Keyword.get(opts, :deck, Deck.standard()),
      discard: Keyword.get(opts, :discard, []),
      turn: Keyword.get(opts, :turn, :white),
      rng: Keyword.get(opts, :rng, &Function.identity/1)
    }
  end

  @doc """
  Rebuilds a game by replaying `events` from the initial `board` and `deck`.

  `board` is the starting position (`Board` or a diagram). Its shape is the
  board size. `deck` is the stored deal, either card tuples or the
  one-character codes from `Deck.encode/1`.

  The fold calls `apply/2` for each event and requires the log to match what
  `apply/2` produces, including a following `{:checkmate, _}` or `:stalemate`.
  """
  @spec restore(Board.t() | String.t(), [card() | String.t()], [event()]) ::
          {:ok, t()}
          | {:error, atom() | {:diverged, event(), event() | nil} | {:unexpected_event, term()}}
  def restore(board, deck, events) when is_binary(board) do
    restore(Board.from_diagram(board), deck, events)
  end

  def restore(%Board{} = board, deck, events) when is_list(deck) and is_list(events) do
    with {:ok, deck} <- Deck.decode(deck) do
      replay(new(board: board, deck: deck), events)
    end
  end

  @doc """
  Applies one `t:command/0`.

  Success returns the new game and the `t:event/0` list. Failure returns
  `{:error, reason}` and leaves the caller's game unchanged.

  Turn errors:

    * `:not_your_turn` — the color in the command is not the side to move.
    * `:game_over` — the game is already checkmate or stalemate.
    * `:unknown_command` — the tuple is not one of the commands above.
    * `:must_draw` — a move, drop, undo, or end was sent before a card was drawn.
    * `:card_already_drawn` — draw was sent while a card is already held.
    * `:empty_deck` — the deck and the discard pile are both empty.
    * `:invalid_card` — the next card is not a move, restore, or reverse.

  Card errors:

    * `:wrong_card` — a move was sent on a Restore card, or a drop on a Move card.
    * `:no_charges_left` — that card's sub-moves or drops are already spent.
    * `:nothing_to_undo` — this turn has no staged sub-move or drop.
    * `:not_in_graveyard` — the drop names a piece this color has not lost.
    * `:turn_incomplete` — end was sent while a legal sub-move or drop remains.
    * `:king_in_check` — end was sent while the mover's king is attacked.
      Staged moves stay in place, so undo can still take them back.

  A move or drop the piece rules reject is returned as that rule's atom
  (`:illegal_geometry`, `:path_blocked`, `:off_home_half`, and the rest from
  `Echo.UnoChess.Rules`). The charge is not spent.
  """
  @spec apply(t(), command()) :: {:ok, t(), [event()]} | {:error, atom()}
  def apply(%__MODULE__{} = game, command) do
    with :ok <- known(command),
         :ok <- active(game),
         :ok <- your_turn(game, command_color(command)) do
      transition(game, command)
    end
  end

  defp known(command) do
    if command_color(command) == :error, do: {:error, :unknown_command}, else: :ok
  end

  defp active(%__MODULE__{status: :active}), do: :ok
  defp active(%__MODULE__{}), do: {:error, :game_over}

  defp your_turn(%__MODULE__{turn: color}, color), do: :ok
  defp your_turn(%__MODULE__{}, _color), do: {:error, :not_your_turn}

  defp command_color({:draw, color}), do: color
  defp command_color({:move, color, _move}), do: color
  defp command_color({:drop, color, _kind, _square}), do: color
  defp command_color({:undo, color}), do: color
  defp command_color({:end_turn, color}), do: color
  defp command_color(_command), do: :error

  defp transition(%__MODULE__{card: card}, {:draw, _color}) when card != nil do
    {:error, :card_already_drawn}
  end

  defp transition(game, {:draw, color}) do
    case take_card(game) do
      {:ok, :reverse, deck, discard} ->
        game = %{game | deck: deck, discard: [:reverse | discard]}
        {:ok, game, [{:card_drawn, color, :reverse}]}

      {:ok, {type, n} = card, deck, discard} when type in [:move, :restore] ->
        game = %{game | deck: deck, discard: discard, card: card, remaining: n}
        {:ok, game, [{:card_drawn, color, card}]}

      {:ok, _card, _deck, _discard} ->
        {:error, :invalid_card}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transition(%__MODULE__{card: nil}, {:move, _color, _move}), do: {:error, :must_draw}

  defp transition(%__MODULE__{card: {:restore, _}}, {:move, _color, _move}),
    do: {:error, :wrong_card}

  defp transition(%__MODULE__{remaining: 0}, {:move, _color, _move}),
    do: {:error, :no_charges_left}

  defp transition(game, {:move, color, notation}) do
    with {:ok, staged, captured} <- Rules.apply_move(game.staged, color, notation) do
      game =
        game
        |> remember()
        |> Map.replace!(:staged, staged)
        |> Map.update!(:graveyard, &bury(&1, captured))
        |> Map.update!(:remaining, &(&1 - 1))

      {:ok, game, [{:piece_moved, color, notation, captured, game.remaining}]}
    end
  end

  defp transition(%__MODULE__{card: nil}, {:drop, _color, _kind, _square}),
    do: {:error, :must_draw}

  defp transition(%__MODULE__{card: {:move, _}}, {:drop, _color, _kind, _square}),
    do: {:error, :wrong_card}

  defp transition(%__MODULE__{remaining: 0}, {:drop, _color, _kind, _square}),
    do: {:error, :no_charges_left}

  defp transition(game, {:drop, color, kind, square}) do
    with {:ok, graveyard} <- pull(game.graveyard, color, kind),
         {:ok, staged} <- Rules.apply_drop(game.staged, color, kind, square) do
      game =
        game
        |> remember()
        |> Map.replace!(:staged, staged)
        |> Map.replace!(:graveyard, graveyard)
        |> Map.update!(:remaining, &(&1 - 1))

      {:ok, game, [{:piece_dropped, color, kind, square, game.remaining}]}
    end
  end

  defp transition(%__MODULE__{card: nil}, {:undo, _color}), do: {:error, :must_draw}
  defp transition(%__MODULE__{history: []}, {:undo, _color}), do: {:error, :nothing_to_undo}

  defp transition(game, {:undo, color}) do
    [snap | history] = game.history

    game = %{
      game
      | staged: snap.staged,
        graveyard: snap.graveyard,
        remaining: snap.remaining,
        history: history
    }

    {:ok, game, [{:move_undone, color, game.remaining}]}
  end

  defp transition(%__MODULE__{card: nil}, {:end_turn, _color}), do: {:error, :must_draw}

  defp transition(game, {:end_turn, color}) do
    cond do
      charges_left?(game, color) -> {:error, :turn_incomplete}
      Rules.in_check?(game.staged, color) -> {:error, :king_in_check}
      true -> commit_turn(game, color)
    end
  end

  defp charges_left?(game, color) do
    game.remaining > 0 and continuation?(game, color)
  end

  defp continuation?(%__MODULE__{card: {:move, _}} = game, color) do
    Rules.pseudo_legal_moves(game.staged, color) != []
  end

  defp continuation?(%__MODULE__{card: {:restore, _}} = game, color) do
    drop_available?(game, color)
  end

  defp drop_available?(game, color) do
    last_file = Board.files() - 1
    last_rank = Board.ranks() - 1

    game.graveyard[color]
    |> Enum.uniq()
    |> Enum.any?(fn kind ->
      Enum.any?(0..last_file, fn file ->
        Enum.any?(0..last_rank, fn rank ->
          match?({:ok, _}, Rules.apply_drop(game.staged, color, kind, {file, rank}))
        end)
      end)
    end)
  end

  defp commit_turn(game, color) do
    opponent = Rules.opposite(color)
    board = game.staged

    base = %{
      game
      | board: board,
        staged: board,
        history: [],
        card: nil,
        remaining: 0,
        discard: [game.card | game.discard]
    }

    cond do
      Rules.checkmate?(board, opponent) ->
        {:ok, %{base | status: :checkmate, winner: color, turn: nil},
         [{:turn_ended, color}, {:checkmate, color}]}

      Rules.stalemate?(board, opponent) and base.graveyard[opponent] == [] ->
        {:ok, %{base | status: :stalemate, winner: nil, turn: nil},
         [{:turn_ended, color}, {:stalemate}]}

      true ->
        {:ok, %{base | turn: opponent}, [{:turn_ended, color}]}
    end
  end

  defp take_card(%__MODULE__{deck: [], discard: []}), do: {:error, :empty_deck}

  defp take_card(%__MODULE__{deck: [], discard: discard, rng: rng}) do
    case rng.(discard) do
      [] -> {:error, :empty_deck}
      [card | deck] -> {:ok, card, deck, []}
    end
  end

  defp take_card(%__MODULE__{deck: [card | deck], discard: discard}) do
    {:ok, card, deck, discard}
  end

  defp remember(game) do
    snap = %{staged: game.staged, graveyard: game.graveyard, remaining: game.remaining}
    %{game | history: [snap | game.history]}
  end

  defp bury(graveyard, nil), do: graveyard

  defp bury(graveyard, {color, kind}) do
    %{graveyard | color => [kind | graveyard[color]]}
  end

  defp pull(graveyard, color, kind) do
    pieces = Map.fetch!(graveyard, color)

    if kind in pieces do
      {:ok, %{graveyard | color => List.delete(pieces, kind)}}
    else
      {:error, :not_in_graveyard}
    end
  end

  defp replay(game, []), do: {:ok, game}

  defp replay(game, [event | _] = events) do
    with {:ok, command} <- command_for(event),
         {:ok, game, produced} <- apply(game, command),
         {:ok, events} <- consume(produced, events) do
      replay(game, events)
    end
  end

  defp command_for({:card_drawn, color, _card}), do: {:ok, {:draw, color}}
  defp command_for({:piece_moved, color, move, _captured, _left}), do: {:ok, {:move, color, move}}

  defp command_for({:piece_dropped, color, kind, square, _left}),
    do: {:ok, {:drop, color, kind, square}}

  defp command_for({:move_undone, color, _left}), do: {:ok, {:undo, color}}
  defp command_for({:turn_ended, color}), do: {:ok, {:end_turn, color}}
  defp command_for(event), do: {:error, {:unexpected_event, event}}

  defp consume([], events), do: {:ok, events}
  defp consume([event | produced], [event | events]), do: consume(produced, events)

  defp consume([expected | _produced], [actual | _events]),
    do: {:error, {:diverged, expected, actual}}

  defp consume([expected | _produced], []), do: {:error, {:diverged, expected, nil}}
end
