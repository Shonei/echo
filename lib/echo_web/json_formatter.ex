defmodule EchoWeb.JSONFormatter do
  def format(level, message, timestamp, metadata) do
    %{
      timestamp: format_timestamp(timestamp),
      level: level,
      message: IO.iodata_to_binary(message),
      metadata: Map.new(metadata)
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_timestamp({{year, month, day}, {hour, minute, second, microsecond}}) do
    "#{year}-#{pad(month)}-#{pad(day)}T#{pad(hour)}:#{pad(minute)}:#{pad(second)}.#{pad_microsecond(microsecond)}Z"
  end

  defp pad(int) when int < 10, do: "0#{int}"
  defp pad(int), do: "#{int}"

  defp pad_microsecond(microsecond) do
    microsecond
    |> div(1000)
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
  end
end
