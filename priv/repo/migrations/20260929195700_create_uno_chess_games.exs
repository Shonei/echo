defmodule Echo.Repo.Migrations.CreateUnoChessGames do
  use Ecto.Migration

  # The row is the deal: starting position, shuffled deck, and seats.
  # Moves live in uno_chess_events and are replayed to rebuild the turn.
  def change do
    create table(:uno_chess_games) do
      add :room_code, :text, null: false
      add :board, :text, null: false
      add :deck, {:array, :text}, null: false

      # Secrets the browsers keep so the same seat can reconnect.
      add :white_token, :text, null: false
      add :black_token, :text

      # Cache for lists. The event log is the source of truth.
      add :status, :text, null: false, default: "active"
      add :winner, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:uno_chess_games, [:room_code])
    create unique_index(:uno_chess_games, [:white_token])
    create unique_index(:uno_chess_games, [:black_token])

    create table(:uno_chess_events) do
      add :game_id, references(:uno_chess_games, on_delete: :delete_all), null: false
      add :sequence, :integer, null: false
      add :type, :text, null: false
      add :payload, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:uno_chess_events, [:game_id, :sequence])
  end
end
