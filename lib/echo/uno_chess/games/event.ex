defmodule Echo.UnoChess.Games.Event do
  @moduledoc """
  One fact from `Echo.UnoChess.Game.apply/2`.

  `sequence` orders the log for a game. `payload` holds the fields that `type` needs.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Echo.UnoChess.Games.Game

  @types ~w(card_drawn piece_moved piece_dropped move_undone turn_ended checkmate stalemate)

  schema "uno_chess_events" do
    belongs_to :game, Game
    field :sequence, :integer
    field :type, :string
    field :payload, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:game_id, :sequence, :type, :payload])
    |> validate_required([:game_id, :sequence, :type, :payload])
    |> validate_inclusion(:type, @types)
    |> unique_constraint([:game_id, :sequence])
  end
end
