defmodule EchoWeb.UnoChessChannel do
  use EchoWeb, :channel

  alias Echo.UnoChess.Games
  alias Echo.UnoChess.Games.Game
  alias EchoWeb.UnoChessController
  alias EchoWeb.UnoChessJSON

  @impl true
  def join("uno_chess:" <> room_code, payload, socket) do
    case Games.get_game_by_room_code(room_code) do
      %Game{} = game ->
        Games.subscribe(room_code)
        seat = Games.seat(game, Map.get(payload || %{}, "token"))
        events = Games.list_events(game.id)
        {:ok, state} = Games.restore_game(game, events)

        socket =
          socket
          |> assign(:room_code, room_code)
          |> assign(:game_id, game.id)
          |> assign(:seat, seat)

        {:ok, %{game: UnoChessJSON.data(game, state, events, seat)}, socket}

      nil ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_in("join_black", _payload, socket) do
    game = Games.get_game!(socket.assigns.game_id)

    case Games.claim_black(game) do
      {:ok, token} ->
        updated = %{game | black_token: token}
        events = Games.list_events(updated.id)
        {:ok, state} = Games.restore_game(updated, events)
        socket = assign(socket, :seat, :black)

        reply = %{
          seat: "black",
          token: token,
          game: UnoChessJSON.data(updated, state, events, :black)
        }

        {:reply, {:ok, reply}, socket}

      {:error, :seat_taken} ->
        {:reply, {:error, %{reason: "seat_taken"}}, socket}
    end
  end

  @impl true
  def handle_in("play", payload, socket) do
    case socket.assigns.seat do
      seat when seat in [:white, :black] ->
        with {:ok, command} <- UnoChessController.parse_command(seat, payload),
             {:ok, %Game{} = updated, new_events} <-
               Games.play(%Game{id: socket.assigns.game_id}, command),
             events = Games.list_events(updated.id),
             {:ok, state} <- Games.restore_game(updated, events) do
          reply = %{
            game: UnoChessJSON.data(updated, state, events, seat),
            events: Enum.map(new_events, &UnoChessJSON.render_domain_event/1)
          }

          {:reply, {:ok, reply}, socket}
        else
          {:error, reason} when is_atom(reason) ->
            {:reply, {:error, %{reason: Atom.to_string(reason)}}, socket}
        end

      nil ->
        {:reply, {:error, %{reason: "invalid_token"}}, socket}
    end
  end

  @impl true
  def handle_info({:uno_chess_updated, %Game{} = game, new_events}, socket) do
    events = Games.list_events(game.id)
    {:ok, state} = Games.restore_game(game, events)

    push(socket, "game_updated", %{
      game: UnoChessJSON.data(game, state, events, socket.assigns.seat),
      events: Enum.map(new_events, &UnoChessJSON.render_domain_event/1)
    })

    {:noreply, socket}
  end
end
