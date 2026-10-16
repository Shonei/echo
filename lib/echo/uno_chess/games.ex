defmodule Echo.UnoChess.Games do
  @moduledoc """
  Stores an Uno Chess deal and appends the facts that `apply/2` returns.

  Loading a game replays those facts through `Echo.UnoChess.Game.restore/3`.
  """

  import Ecto.Query, warn: false

  alias Echo.Repo
  alias Echo.UnoChess.Board
  alias Echo.UnoChess.Deck
  alias Echo.UnoChess.Game, as: Engine
  alias Echo.UnoChess.Games.Event
  alias Echo.UnoChess.Games.Game

  @doc """
  Inserts a deal. Generates `room_code` and `white_token` when they are omitted.

  `deck` defaults to one shuffled standard pile. Pass card tuples or codes to
  fix the order.
  """
  def create_game(opts \\ []) do
    generated_code = not Keyword.has_key?(opts, :room_code)

    attrs = %{
      room_code: Keyword.get(opts, :room_code) || room_code(),
      board: diagram(Keyword.get(opts, :board, Board.initial())),
      deck: codes(Keyword.get(opts, :deck, Deck.shuffle())),
      white_token: Keyword.get(opts, :white_token, token()),
      black_token: Keyword.get(opts, :black_token),
      status: "active"
    }

    insert_game(attrs, generated_code, 5)
  end

  @doc """
  Sets `black_token` when the seat is empty.

  Returns `{:error, :seat_taken}` when black already has a token.
  """
  def claim_black(%Game{id: id} = game) do
    token = token()

    Game
    |> where([g], g.id == ^id and is_nil(g.black_token))
    |> Repo.update_all(
      set: [black_token: token, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
    |> case do
      {1, _} ->
        broadcast(%{game | black_token: token}, [])
        {:ok, token}

      {0, _} ->
        {:error, :seat_taken}
    end
  end

  @doc """
  Returns `:white` or `:black` when `token` matches that seat on `game`, or `nil`.
  """
  def seat(%Game{} = game, token) when is_binary(token) do
    cond do
      token_match?(game.white_token, token) -> :white
      token_match?(game.black_token, token) -> :black
      true -> nil
    end
  end

  def seat(%Game{}, _token), do: nil

  @doc """
  Subscribes the calling process to real-time updates for `room_code`.
  """
  def subscribe(room_code) when is_binary(room_code) do
    Phoenix.PubSub.subscribe(Echo.PubSub, topic(room_code))
  end

  def get_game!(id), do: Repo.get!(Game, id)

  def get_game_by_room_code(room_code) do
    Repo.get_by(Game, room_code: room_code)
  end

  @doc """
  Replays the stored log into an `Echo.UnoChess.Game` struct.
  """
  def restore_game(%Game{} = game) do
    restore_game(game, list_events(game.id))
  end

  def restore_game(id) when is_integer(id) do
    id |> get_game!() |> restore_game()
  end

  def restore_game(%Game{} = game, events) when is_list(events) do
    decoded = Enum.map(events, &decode_event/1)
    Engine.restore(game.board, game.deck, decoded)
  end

  def list_events(game_id) do
    Event
    |> where([e], e.game_id == ^game_id)
    |> order_by([e], asc: e.sequence)
    |> Repo.all()
  end

  @doc """
  Replays the log, applies `command`, and appends the new facts.

  A refused command writes nothing. `status` and `winner` are updated from
  the resulting game.
  """
  def play(%Game{id: id}, command) do
    case Repo.transaction(fn -> play_locked(id, command) end) do
      {:ok, {game, events}} ->
        broadcast(game, events)
        {:ok, game, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp play_locked(id, command) do
    game = lock!(id)
    encoded = game.id |> list_events() |> Enum.map(&decode_event/1)

    with {:ok, state} <- Engine.restore(game.board, game.deck, encoded),
         {:ok, state, new_events} <- Engine.apply(state, command),
         {:ok, game} <- append(game, state, new_events) do
      {game, new_events}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock!(id) do
    query = from(g in Game, where: g.id == ^id, lock: "FOR UPDATE")
    Repo.one(query) || Repo.rollback(:not_found)
  end

  defp append(game, state, new_events) do
    start = next_sequence(game.id)

    Enum.with_index(new_events, start)
    |> Enum.reduce_while(:ok, fn {event, sequence}, :ok ->
      {type, payload} = encode_event(event)

      %Event{}
      |> Event.changeset(%{game_id: game.id, sequence: sequence, type: type, payload: payload})
      |> Repo.insert()
      |> case do
        {:ok, _event} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      :ok ->
        game
        |> Game.status_changeset(%{status: status(state), winner: winner(state)})
        |> Repo.update()

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp next_sequence(game_id) do
    Event
    |> where([e], e.game_id == ^game_id)
    |> select([e], coalesce(max(e.sequence), 0))
    |> Repo.one!()
    |> Kernel.+(1)
  end

  defp insert_game(_attrs, _generated, 0), do: {:error, :room_code_collision}

  defp insert_game(attrs, generated, attempts) do
    %Game{}
    |> Game.create_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:error, %{errors: [room_code: _]}} when generated ->
        insert_game(%{attrs | room_code: room_code()}, true, attempts - 1)

      other ->
        other
    end
  end

  defp diagram(%Board{} = board), do: Board.to_diagram(board)
  defp diagram(text) when is_binary(text), do: text

  defp codes(cards) do
    case Deck.decode(cards) do
      {:ok, decoded} -> Deck.encode(decoded)
      {:error, :invalid_card} -> cards
    end
  end

  defp status(%Engine{status: status}), do: Atom.to_string(status)
  defp winner(%Engine{winner: nil}), do: nil
  defp winner(%Engine{winner: winner}), do: Atom.to_string(winner)

  defp room_code do
    alphabet = ~c"abcdefghjkmnpqrstuvwxyz23456789"
    Enum.map_join(1..6, fn _ -> <<Enum.random(alphabet)>> end)
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp token_match?(stored, given)
       when is_binary(stored) and is_binary(given) and byte_size(stored) == byte_size(given) do
    Plug.Crypto.secure_compare(stored, given)
  end

  defp token_match?(_stored, _given), do: false

  defp broadcast(%Game{room_code: room_code} = game, events) do
    Phoenix.PubSub.broadcast(Echo.PubSub, topic(room_code), {:uno_chess_updated, game, events})
  end

  defp topic(room_code), do: "uno_chess:room:" <> room_code

  defp encode_event({:card_drawn, color, card}) do
    {"card_drawn", %{"color" => color_name(color), "card" => hd(Deck.encode([card]))}}
  end

  defp encode_event({:piece_moved, color, move, captured, remaining}) do
    {"piece_moved",
     %{
       "color" => color_name(color),
       "move" => move,
       "captured" => encode_captured(captured),
       "remaining" => remaining
     }}
  end

  defp encode_event({:piece_dropped, color, kind, square, remaining}) do
    {"piece_dropped",
     %{
       "color" => color_name(color),
       "kind" => kind_name(kind),
       "square" => square,
       "remaining" => remaining
     }}
  end

  defp encode_event({:move_undone, color, remaining}) do
    {"move_undone", %{"color" => color_name(color), "remaining" => remaining}}
  end

  defp encode_event({:turn_ended, color}) do
    {"turn_ended", %{"color" => color_name(color)}}
  end

  defp encode_event({:checkmate, winner}) do
    {"checkmate", %{"winner" => color_name(winner)}}
  end

  defp encode_event({:stalemate}) do
    {"stalemate", %{}}
  end

  defp encode_event({:forfeited, color, winner}) do
    {"forfeited", %{"color" => color_name(color), "winner" => color_name(winner)}}
  end

  defp encode_captured(nil), do: nil

  defp encode_captured({color, kind}) do
    %{"color" => color_name(color), "kind" => kind_name(kind)}
  end

  defp decode_event(%Event{type: "card_drawn", payload: payload}) do
    {:ok, [card]} = Deck.decode([payload["card"]])
    {:card_drawn, color!(payload["color"]), card}
  end

  defp decode_event(%Event{type: "piece_moved", payload: payload}) do
    {:piece_moved, color!(payload["color"]), payload["move"],
     decode_captured(payload["captured"]), payload["remaining"]}
  end

  defp decode_event(%Event{type: "piece_dropped", payload: payload}) do
    {:piece_dropped, color!(payload["color"]), kind!(payload["kind"]), payload["square"],
     payload["remaining"]}
  end

  defp decode_event(%Event{type: "move_undone", payload: payload}) do
    {:move_undone, color!(payload["color"]), payload["remaining"]}
  end

  defp decode_event(%Event{type: "turn_ended", payload: payload}) do
    {:turn_ended, color!(payload["color"])}
  end

  defp decode_event(%Event{type: "checkmate", payload: payload}) do
    {:checkmate, color!(payload["winner"])}
  end

  defp decode_event(%Event{type: "stalemate", payload: %{}}) do
    {:stalemate}
  end

  defp decode_event(%Event{type: "forfeited", payload: payload}) do
    {:forfeited, color!(payload["color"]), color!(payload["winner"])}
  end

  defp decode_captured(nil), do: nil

  defp decode_captured(%{"color" => color, "kind" => kind}) do
    {color!(color), kind!(kind)}
  end

  defp color_name(:white), do: "white"
  defp color_name(:black), do: "black"
  defp color!("white"), do: :white
  defp color!("black"), do: :black

  defp kind_name(kind), do: Atom.to_string(kind)

  defp kind!("king"), do: :king
  defp kind!("queen"), do: :queen
  defp kind!("rook"), do: :rook
  defp kind!("bishop"), do: :bishop
  defp kind!("knight"), do: :knight
  defp kind!("pawn"), do: :pawn
end
