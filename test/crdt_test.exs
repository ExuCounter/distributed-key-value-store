defmodule DS.CRDTTest do
  use ExUnit.Case, async: true

  alias DS.CRDT

  describe "resolve_conflict/3 :counter" do
    test "merges per-node counts taking the max" do
      {value, clock} =
        CRDT.resolve_conflict(:counter, {%{a: 2, b: 1}, %{a: 1}}, {%{a: 1, b: 3}, %{b: 1}})

      assert value == %{a: 2, b: 3}
      assert clock == %{a: 1, b: 1}
    end

    test "two empty counters yield empty value and merged clock" do
      assert CRDT.resolve_conflict(:counter, {%{}, %{}}, {%{}, %{}}) == {%{}, %{}}
    end

    test "is commutative" do
      a = {%{a: 5, b: 2}, %{a: 2, b: 1}}
      b = {%{a: 1, b: 7}, %{a: 1, b: 3}}
      assert CRDT.resolve_conflict(:counter, a, b) == CRDT.resolve_conflict(:counter, b, a)
    end

    test "keeps unique nodes from each side" do
      {value, _} = CRDT.resolve_conflict(:counter, {%{a: 1}, %{}}, {%{b: 2}, %{}})
      assert value == %{a: 1, b: 2}
    end
  end

  describe "resolve_conflict/3 :set" do
    test "unions the two sets" do
      {value, clock} =
        CRDT.resolve_conflict(
          :set,
          {MapSet.new([1, 2]), %{a: 1}},
          {MapSet.new([2, 3]), %{b: 1}}
        )

      assert value == MapSet.new([1, 2, 3])
      assert clock == %{a: 1, b: 1}
    end

    test "two empty sets remain empty" do
      {value, _} =
        CRDT.resolve_conflict(:set, {MapSet.new(), %{}}, {MapSet.new(), %{}})

      assert MapSet.size(value) == 0
    end

    test "is commutative" do
      a = {MapSet.new([:x, :y]), %{a: 1}}
      b = {MapSet.new([:y, :z]), %{b: 1}}
      assert CRDT.resolve_conflict(:set, a, b) == CRDT.resolve_conflict(:set, b, a)
    end
  end

  describe "resolve_conflict/3 :lww" do
    test "later clock wins (:after)" do
      {value, clock} =
        CRDT.resolve_conflict(:lww, {"new", %{a: 2}}, {"old", %{a: 1}})

      assert value == "new"
      assert clock == %{a: 2}
    end

    test "earlier clock loses (:before)" do
      {value, clock} =
        CRDT.resolve_conflict(:lww, {"old", %{a: 1}}, {"new", %{a: 2}})

      assert value == "new"
      assert clock == %{a: 2}
    end

    test "concurrent: higher clock-sum wins, returns merged clock" do
      {value, clock} =
        CRDT.resolve_conflict(:lww, {"left", %{a: 5, b: 0}}, {"right", %{a: 0, b: 2}})

      assert value == "left"
      assert clock == %{a: 5, b: 2}
    end

    test "concurrent with equal sums: deterministic by smallest sorted node key" do
      # both clocks have sum 2; keys are :a and :b — :a sorts first, so the
      # side containing :a wins.
      {value, _} =
        CRDT.resolve_conflict(:lww, {"left", %{a: 2}}, {"right", %{b: 2}})

      assert value == "left"

      {value2, _} =
        CRDT.resolve_conflict(:lww, {"left", %{b: 2}}, {"right", %{a: 2}})

      assert value2 == "right"
    end

    test "tiebreaker is stable across repeated calls" do
      left = {"left", %{a: 1, b: 1}}
      right = {"right", %{a: 1, b: 1}}

      result = CRDT.resolve_conflict(:lww, left, right)
      assert CRDT.resolve_conflict(:lww, left, right) == result
      assert CRDT.resolve_conflict(:lww, left, right) == result
    end

    test "equal clocks: deterministic winner via smallest sorted node key" do
      # compare/2 returns :equal, sums tie, tiebreaker key is :a which lives
      # in clock1, so the left value wins.
      {value, clock} =
        CRDT.resolve_conflict(:lww, {"left", %{a: 1}}, {"right", %{a: 1}})

      assert value == "left"
      assert clock == %{a: 1}
    end

    test "both empty clocks resolve deterministically" do
      result = CRDT.resolve_conflict(:lww, {"l", %{}}, {"r", %{}})
      assert result == CRDT.resolve_conflict(:lww, {"l", %{}}, {"r", %{}})
    end
  end

  describe "counter_value/1" do
    test "sums per-node counts" do
      assert CRDT.counter_value(%{a: 2, b: 3, c: 5}) == 10
    end

    test "empty counter is zero" do
      assert CRDT.counter_value(%{}) == 0
    end

    test "single-node counter equals its value" do
      assert CRDT.counter_value(%{a: 7}) == 7
    end
  end
end
