defmodule DS.VectorClockTest do
  use ExUnit.Case, async: true

  alias DS.VectorClock

  describe "increment/2" do
    test "starts a node at 1 when not present" do
      assert VectorClock.increment(%{}, :a) == %{a: 1}
    end

    test "bumps an existing counter" do
      assert VectorClock.increment(%{a: 3}, :a) == %{a: 4}
    end

    test "does not touch other nodes" do
      assert VectorClock.increment(%{a: 1, b: 5}, :a) == %{a: 2, b: 5}
    end
  end

  describe "merge/2" do
    test "returns empty for two empty clocks" do
      assert VectorClock.merge(%{}, %{}) == %{}
    end

    test "takes the max per node" do
      assert VectorClock.merge(%{a: 1, b: 5}, %{a: 4, b: 2}) == %{a: 4, b: 5}
    end

    test "preserves nodes present on only one side" do
      assert VectorClock.merge(%{a: 1}, %{b: 2}) == %{a: 1, b: 2}
    end

    test "is commutative" do
      c1 = %{a: 1, b: 5, c: 3}
      c2 = %{a: 4, b: 2, d: 7}
      assert VectorClock.merge(c1, c2) == VectorClock.merge(c2, c1)
    end
  end

  describe "compare/2" do
    test "two empty clocks are equal" do
      assert VectorClock.compare(%{}, %{}) == :equal
    end

    test "identical clocks are equal" do
      assert VectorClock.compare(%{a: 1, b: 2}, %{a: 1, b: 2}) == :equal
    end

    test "strictly greater on every shared key is :after" do
      assert VectorClock.compare(%{a: 2, b: 3}, %{a: 1, b: 2}) == :after
    end

    test "strictly less on every shared key is :before" do
      assert VectorClock.compare(%{a: 1, b: 2}, %{a: 2, b: 3}) == :before
    end

    test "extra node on left is :after" do
      assert VectorClock.compare(%{a: 1, b: 1}, %{a: 1}) == :after
    end

    test "extra node on right is :before" do
      assert VectorClock.compare(%{a: 1}, %{a: 1, b: 1}) == :before
    end

    test "diverging clocks are :concurrent" do
      assert VectorClock.compare(%{a: 2, b: 1}, %{a: 1, b: 2}) == :concurrent
    end

    test "extra nodes on both sides are :concurrent" do
      assert VectorClock.compare(%{a: 1}, %{b: 1}) == :concurrent
    end

    test "treats missing key as zero" do
      assert VectorClock.compare(%{a: 1}, %{a: 1, b: 0}) == :equal
    end
  end
end
