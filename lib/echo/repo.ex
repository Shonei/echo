defmodule Echo.Repo do
  use Ecto.Repo,
    otp_app: :echo,
    adapter: Ecto.Adapters.SQLite3
end
