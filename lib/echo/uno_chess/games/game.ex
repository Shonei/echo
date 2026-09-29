defmodule Echo.UnoChess.Games.Game do
  @moduledoc """
  One stored Uno Chess deal.

  `board` and `deck` are the inputs to `Echo.UnoChess.Game.restore/3`.
  `status` and `winner` mirror the log so a list does not have to replay it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Echo.UnoChess.Deck
  alias Echo.UnoChess.Games.Event

  schema "uno_chess_games" do
    field :room_code, :string
    field :board, :string
    field :deck, {:array, :string}
    field :white_token, :string
    field :black_token, :string
    field :status, :string, default: "active"
    field :winner, :string

    has_many :events, Event, preload_order: [asc: :sequence]

    timestamps(type: :utc_datetime)
  end

  def create_changeset(game, attrs) do
    game
    |> cast(attrs, [
      :room_code,
      :board,
      :deck,
      :white_token,
      :black_token,
      :status,
      :winner
    ])
    |> validate_required([:room_code, :board, :deck, :white_token, :status])
    |> validate_inclusion(:status, ~w(active checkmate stalemate))
    |> validate_inclusion(:winner, ~w(white black), allow_nil: true)
    |> validate_deck()
    |> unique_constraint(:room_code)
    |> unique_constraint(:white_token)
    |> unique_constraint(:black_token)
  end

  def status_changeset(game, attrs) do
    game
    |> cast(attrs, [:status, :winner])
    |> validate_required([:status])
    |> validate_inclusion(:status, ~w(active checkmate stalemate))
    |> validate_inclusion(:winner, ~w(white black), allow_nil: true)
  end

  defp validate_deck(changeset) do
    validate_change(changeset, :deck, fn :deck, deck ->
      case Deck.decode(deck) do
        {:ok, [_ | _]} -> []
        _ -> [deck: "must be a non-empty list of card codes"]
      end
    end)
  end
end
