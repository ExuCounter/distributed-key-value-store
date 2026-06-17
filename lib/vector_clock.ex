defmodule DS.VectorClock do
  def increment(clock, node) do
    Map.update(clock, node, 1, &(&1 + 1))
  end

  def merge(clock1, clock2) do
    Map.merge(clock1, clock2, fn _key, counter1, counter2 ->
      max(counter1, counter2)
    end)
  end

  def compare(clock1, clock2) do
    all_keys = Map.merge(clock1, clock2) |> Map.keys()

    %{clock1_ahead: clock1_ahead, clock2_ahead: clock2_ahead} =
      Enum.reduce(all_keys, %{clock1_ahead: 0, clock2_ahead: 0}, fn key, acc ->
        c1 = clock1[key] || 0
        c2 = clock2[key] || 0

        cond do
          c1 > c2 -> Map.update!(acc, :clock1_ahead, &(&1 + 1))
          c1 < c2 -> Map.update!(acc, :clock2_ahead, &(&1 + 1))
          true -> acc
        end
      end)

    cond do
      clock1_ahead > 0 and clock2_ahead == 0 -> :after
      clock1_ahead == 0 and clock2_ahead > 0 -> :before
      clock1_ahead > 0 and clock2_ahead > 0 -> :concurrent
      true -> :equal
    end
  end
end
