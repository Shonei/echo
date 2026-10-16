defmodule EchoWeb.UnoChessController do
  use EchoWeb, :controller

  alias Echo.UnoChess.Games
  alias Echo.UnoChess.Games.Game

  action_fallback EchoWeb.FallbackController

  def create(conn, _params) do
    with {:ok, %Game{} = game} <- Games.create_game(),
         {:ok, state} <- Games.restore_game(game) do
      conn
      |> put_status(:created)
      |> render(:created,
        game: game,
        state: state,
        events: [],
        seat: :white,
        token: game.white_token
      )
    end
  end

  def show(conn, %{"room_code" => room_code} = params) do
    with {:ok, %Game{} = game} <- fetch_game(room_code),
         events = Games.list_events(game.id),
         {:ok, state} <- Games.restore_game(game, events) do
      seat = Games.seat(game, extract_token(conn, params))
      render(conn, :show, game: game, state: state, events: events, seat: seat)
    end
  end

  def join(conn, %{"room_code" => room_code}) do
    with {:ok, %Game{} = game} <- fetch_game(room_code) do
      case Games.claim_black(game) do
        {:ok, token} ->
          game = %{game | black_token: token}
          events = Games.list_events(game.id)
          {:ok, state} = Games.restore_game(game, events)

          render(conn, :joined,
            game: game,
            state: state,
            events: events,
            seat: :black,
            token: token
          )

        {:error, :seat_taken} ->
          conn
          |> put_status(:conflict)
          |> json(%{errors: %{detail: "seat_taken"}})
      end
    end
  end

  def play(conn, %{"room_code" => room_code} = params) do
    with {:ok, %Game{} = game} <- fetch_game(room_code),
         {:ok, seat} <- require_seat(game, extract_token(conn, params)),
         {:ok, command} <- parse_command(seat, params),
         {:ok, %Game{} = updated, new_events} <- Games.play(game, command),
         events = Games.list_events(updated.id),
         {:ok, state} <- Games.restore_game(updated, events) do
      render(conn, :played,
        game: updated,
        state: state,
        events: events,
        new_events: new_events,
        seat: seat
      )
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :invalid_token} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{errors: %{detail: "invalid_token"}})

      {:error, reason} when is_atom(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{detail: Atom.to_string(reason)}})
    end
  end

  @doc """
  Translates a JSON command payload into an `Echo.UnoChess.Game.command()` tuple
  for `color`.
  """
  def parse_command(color, %{"action" => "draw"}) do
    {:ok, {:draw, color}}
  end

  def parse_command(color, %{"action" => "move", "move" => move}) when is_binary(move) do
    {:ok, {:move, color, move}}
  end

  def parse_command(color, %{"action" => "move", "from" => from, "to" => to} = params)
      when is_binary(from) and is_binary(to) do
    promo = normalize_promotion(params["promotion"])
    {:ok, {:move, color, "#{from}-#{to}#{promo}"}}
  end

  def parse_command(color, %{"action" => "drop", "kind" => kind, "square" => square})
      when is_binary(kind) and is_binary(square) do
    case parse_drop_kind(kind) do
      {:ok, kind_atom} -> {:ok, {:drop, color, kind_atom, square}}
      :error -> {:error, :invalid_piece}
    end
  end

  def parse_command(color, %{"action" => "undo"}) do
    {:ok, {:undo, color}}
  end

  def parse_command(color, %{"action" => "end_turn"}) do
    {:ok, {:end_turn, color}}
  end

  def parse_command(color, %{"action" => "forfeit"}) do
    {:ok, {:forfeit, color}}
  end

  def parse_command(_color, _params) do
    {:error, :unknown_command}
  end

  defp fetch_game(room_code) do
    case Games.get_game_by_room_code(room_code) do
      %Game{} = game -> {:ok, game}
      nil -> {:error, :not_found}
    end
  end

  defp require_seat(%Game{} = game, token) do
    case Games.seat(game, token) do
      seat when seat in [:white, :black] -> {:ok, seat}
      nil -> {:error, :invalid_token}
    end
  end

  defp extract_token(conn, params) do
    bearer_token(conn) ||
      header_token(conn, "x-player-token") ||
      params["token"]
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> String.trim(token)
      ["bearer " <> token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp header_token(conn, header) do
    case get_req_header(conn, header) do
      [token | _] -> String.trim(token)
      _ -> nil
    end
  end

  defp parse_drop_kind(kind) do
    case String.downcase(String.trim(kind)) do
      "queen" -> {:ok, :queen}
      "rook" -> {:ok, :rook}
      "bishop" -> {:ok, :bishop}
      "knight" -> {:ok, :knight}
      "pawn" -> {:ok, :pawn}
      _ -> :error
    end
  end

  defp normalize_promotion(nil), do: ""

  defp normalize_promotion(promo) when is_binary(promo) do
    case String.downcase(String.trim(promo)) do
      letter when letter in ["q", "r", "b", "n"] -> letter
      "queen" -> "q"
      "rook" -> "r"
      "bishop" -> "b"
      "knight" -> "n"
      other -> other
    end
  end

  defp normalize_promotion(_), do: ""
end
