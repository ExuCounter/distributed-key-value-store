defmodule DS.ReaderTest do
  use ExUnit.Case, async: true

  alias DS.Reader

  describe "deterministic_pick/2" do
    test "higher clock-sum wins on the left" do
      assert Reader.deterministic_pick({"left", %{a: 5}}, {"right", %{a: 2}}) ==
               {"left", %{a: 5}}
    end

    test "higher clock-sum wins on the right" do
      assert Reader.deterministic_pick({"left", %{a: 1}}, {"right", %{a: 4}}) ==
               {"right", %{a: 4}}
    end

    test "sum compares totals across all nodes in the clock" do
      assert Reader.deterministic_pick({"left", %{a: 1, b: 1}}, {"right", %{a: 3}}) ==
               {"right", %{a: 3}}
    end

    test "equal sums: smallest sorted node key decides the side" do
      # both clocks sum to 2; smallest key across both is :a, which lives in
      # clock_a, so the left record wins.
      assert Reader.deterministic_pick({"left", %{a: 2}}, {"right", %{b: 2}}) ==
               {"left", %{a: 2}}
    end

    test "equal sums: tiebreaker picks the right when :a lives only on the right" do
      assert Reader.deterministic_pick({"left", %{b: 2}}, {"right", %{a: 2}}) ==
               {"right", %{a: 2}}
    end

    test "identical clocks: stable winner derived from the smallest shared key" do
      # smallest key is :a, present in both — first-found is clock_a (left).
      assert Reader.deterministic_pick({"left", %{a: 1}}, {"right", %{a: 1}}) ==
               {"left", %{a: 1}}
    end

    test "repeated calls return the same result" do
      left = {"left", %{a: 1, b: 1}}
      right = {"right", %{a: 1, b: 1}}

      first = Reader.deterministic_pick(left, right)

      for _ <- 1..5 do
        assert Reader.deterministic_pick(left, right) == first
      end
    end

    test "both empty clocks resolve deterministically" do
      first = Reader.deterministic_pick({"left", %{}}, {"right", %{}})
      assert Reader.deterministic_pick({"left", %{}}, {"right", %{}}) == first
    end
  end
end
