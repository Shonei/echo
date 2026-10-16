defmodule EchoWeb.UnoChessJSON do
  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Deck
  alias Echo.UnoChess.Game, as: Engine
  alias Echo.UnoChess.Games.Event
  alias Echo.UnoChess.Games.Game
  alias Echo.UnoChess.Move
  alias Echo.UnoChess.Rules
  alias Echo.UnoChess.Square

  def created(%{game: game, state: state, events: events, seat: seat, token: token}) do
    %{
      data: %{
        seat: color_name(seat),
        token: token,
        game: data(game, state, events, seat)
      }
    }
  end

  def joined(%{game: game, state: state, events: events, seat: seat, token: token}) do
    %{
      data: %{
        seat: color_name(seat),
        token: token,
        game: data(game, state, events, seat)
      }
    }
  end

  def show(%{game: game, state: state, events: events, seat: seat}) do
    %{data: data(game, state, events, seat)}
  end

  def played(%{game: game, state: state, events: events, new_events: new_events, seat: seat}) do
    %{
      data: %{
        game: data(game, state, events, seat),
        events: Enum.map(new_events, &render_domain_event/1)
      }
    }
  end

  def data(%Game{} = game, %Engine{} = state, events, seat) do
    %{
      room_code: game.room_code,
      status: Atom.to_string(state.status),
      winner: color_name(state.winner),
      turn: color_name(state.turn),
      you: color_name(seat),
      seats: %{
        white: is_binary(game.white_token),
        black: is_binary(game.black_token)
      },
      board: encode_board(state.board),
      staged: encode_board(state.staged),
      graveyard: %{
        white: Enum.map(state.graveyard.white, &Atom.to_string/1),
        black: Enum.map(state.graveyard.black, &Atom.to_string/1)
      },
      card: encode_card(state.card),
      remaining: state.remaining,
      can_undo: state.history != [],
      can_end_turn:
        state.turn != nil and match?({:ok, _, _}, Engine.apply(state, {:end_turn, state.turn})),
      in_check: %{
        white: Rules.in_check?(state.staged, :white),
        black: Rules.in_check?(state.staged, :black)
      },
      deck_count: length(state.deck),
      discard_count: length(state.discard),
      legal_moves: legal_moves_for_turn(state),
      legal_drops: legal_drops_for_turn(state),
      events: Enum.map(events, &render_stored_event/1)
    }
  end

  def render_domain_event({:card_drawn, color, card}) do
    %{
      type: "card_drawn",
      color: color_name(color),
      card: encode_card(card)
    }
  end

  def render_domain_event({:piece_moved, color, move, captured, remaining}) do
    %{
      type: "piece_moved",
      color: color_name(color),
      move: move,
      captured: encode_piece(captured),
      remaining: remaining
    }
  end

  def render_domain_event({:piece_dropped, color, kind, square, remaining}) do
    %{
      type: "piece_dropped",
      color: color_name(color),
      kind: Atom.to_string(kind),
      square: square,
      remaining: remaining
    }
  end

  def render_domain_event({:move_undone, color, remaining}) do
    %{
      type: "move_undone",
      color: color_name(color),
      remaining: remaining
    }
  end

  def render_domain_event({:turn_ended, color}) do
    %{
      type: "turn_ended",
      color: color_name(color)
    }
  end

  def render_domain_event({:checkmate, winner}) do
    %{
      type: "checkmate",
      winner: color_name(winner)
    }
  end

  def render_domain_event({:stalemate}) do
    %{type: "stalemate"}
  end

  def render_domain_event({:forfeited, color, winner}) do
    %{
      type: "forfeited",
      color: color_name(color),
      winner: color_name(winner)
    }
  end

  defp render_stored_event(%Event{} = event) do
    %{
      sequence: event.sequence,
      type: event.type,
      payload: event.payload
    }
  end

  defp encode_board(%Board{squares: squares}) do
    Map.new(squares, fn {square, piece} ->
      {Square.encode(square), encode_piece(piece)}
    end)
  end

  defp encode_piece(nil), do: nil

  defp encode_piece({color, kind}) do
    %{color: color_name(color), kind: Atom.to_string(kind)}
  end

  defp encode_card(nil), do: nil

  defp encode_card({:move, count} = card) do
    %{type: "move", count: count, code: hd(Deck.encode([card]))}
  end

  defp encode_card({:restore, count} = card) do
    %{type: "restore", count: count, code: hd(Deck.encode([card]))}
  end

  defp encode_card(:reverse) do
    %{type: "reverse", count: 0, code: "R"}
  end

  defp legal_moves_for_turn(
         %Engine{status: :active, card: {:move, _}, remaining: remaining} = state
       )
       when remaining > 0 do
    state.staged
    |> Rules.pseudo_legal_moves(state.turn)
    |> Enum.map(&Move.encode/1)
  end

  defp legal_moves_for_turn(_state), do: []

  defp legal_drops_for_turn(
         %Engine{status: :active, card: {:restore, _}, remaining: remaining} = state
       )
       when remaining > 0 do
    last_file = Board.files() - 1
    last_rank = Board.ranks() - 1
    color = state.turn

    state.graveyard[color]
    |> Enum.uniq()
    |> Map.new(fn kind ->
      squares =
        for file <- 0..last_file,
            rank <- 0..last_rank,
            match?({:ok, _}, Rules.apply_drop(state.staged, color, kind, {file, rank})) do
          Square.encode({file, rank})
        end

      {Atom.to_string(kind), squares}
    end)
  end

  defp legal_drops_for_turn(_state), do: %{}

  defp color_name(nil), do: nil
  defp color_name(color) when color in [:white, :black], do: Atom.to_string(color)
end
