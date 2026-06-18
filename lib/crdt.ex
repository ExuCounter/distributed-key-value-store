defmodule DS.CRDT do
  def resolve_conflict(:counter, {value1, clock1}, {value2, clock2}) do
    counter = Map.merge(value1, value2, fn _key, c1, c2 -> max(c1, c2) end)
    clock = DS.VectorClock.merge(clock1, clock2)
    {counter, clock}
  end

  def resolve_conflict(:set, {value1, clock1}, {value2, clock2}) do
    clock = DS.VectorClock.merge(clock1, clock2)
    {MapSet.union(value1, value2), clock}
  end

  def resolve_conflict(:lww, {value1, clock1}, {value2, clock2}) do
    case DS.VectorClock.compare(clock1, clock2) do
      :after ->
        {value1, clock1}

      :before ->
        {value2, clock2}

      _ ->
        sum1 = Enum.sum(Map.values(clock1))
        sum2 = Enum.sum(Map.values(clock2))
        clock = DS.VectorClock.merge(clock1, clock2)

        cond do
          sum1 > sum2 ->
            {value1, clock}

          sum2 > sum1 ->
            {value2, clock}

          true ->
            winner =
              [Map.keys(clock1) ++ Map.keys(clock2)]
              |> List.flatten()
              |> Enum.uniq()
              |> Enum.sort()
              |> List.first()

            if winner in Map.keys(clock1) do
              {value1, clock}
            else
              {value2, clock}
            end
        end
    end
  end

  def counter_value(counter) do
    Enum.sum(Map.values(counter))
  end
end
