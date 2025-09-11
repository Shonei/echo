defmodule Echo.Repo.Migrations.AddSearchIndexToRequests do
  use Ecto.Migration

  def change do
    # Create a composite index for efficient searching by path, method, and query params
    create index(:requests, [:url_path, :method])
    
    # Create individual indexes for common search patterns
    create index(:requests, [:url_path])
    create index(:requests, [:method])
  end
end
