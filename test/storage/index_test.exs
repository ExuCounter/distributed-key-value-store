defmodule DS.Storage.IndexTest do
  use ExUnit.Case, async: false

  alias DS.Storage.Index
  alias DS.Storage.Schema

  @entity :user
  @field :age

  setup_all do
    start_if_needed(Schema)
    start_if_needed(Index)
    :ok
  end

  setup do
    for {{entity, field}, _} <- :ets.tab2list(:indexes) do
      drop_table(Index.forward_index_name(entity, field))
      drop_table(Index.reverse_index_name(entity, field))
    end

    :ets.delete_all_objects(:indexes)
    :ets.delete_all_objects(:schemas)

    :ok = Schema.register(@entity, %{@field => :lww, :name => :lww})
    :ok
  end

  defp start_if_needed(module) do
    case module.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp drop_table(name) do
    case :ets.info(name) do
      :undefined -> :ok
      _ -> :ets.delete(name)
    end
  end

  describe "create_index/2" do
    test "registers the pair and the resulting index supports a full write/read cycle" do
      assert Index.create_index(@entity, @field) == :ok
      assert Index.index_pairs() == [{@entity, @field}]

      :ok = Index.update_index(@entity, @field, "u1", 30)

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 30}
      assert Index.where(@entity, @field, 30, 30) == ["u1"]
    end

    test "rejects a duplicate index on the same (entity, field)" do
      :ok = Index.create_index(@entity, @field)
      assert Index.create_index(@entity, @field) == {:error, :index_already_exists}
    end

    test "rejects a field that the schema does not know about" do
      assert Index.create_index(@entity, :unknown_field) == {:error, :field_schema_not_found}
    end

    test "rejects when the entity itself has no schema" do
      assert Index.create_index(:no_such_entity, :age) == {:error, :field_schema_not_found}
    end
  end

  describe "forward_index_name/2 and reverse_index_name/2" do
    test "produce stable, distinct atoms" do
      assert Index.forward_index_name(:user, :age) == :index_user_age
      assert Index.reverse_index_name(:user, :age) == :rindex_user_age
    end
  end

  describe "update_index/4" do
    setup do
      :ok = Index.create_index(@entity, @field)
      :ok
    end

    test "round-trips through indexed_value/3 and where/4" do
      :ok = Index.update_index(@entity, @field, "u1", 30)

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 30}
      assert Index.where(@entity, @field, 30, 30) == ["u1"]
    end

    test "replaces the prior value for an existing key" do
      :ok = Index.update_index(@entity, @field, "u1", 30)
      :ok = Index.update_index(@entity, @field, "u1", 31)

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 31}
      assert Index.where(@entity, @field, 30, 30) == []
      assert Index.where(@entity, @field, 31, 31) == ["u1"]
    end

    test "supports multiple keys sharing the same value" do
      :ok = Index.update_index(@entity, @field, "u1", 30)
      :ok = Index.update_index(@entity, @field, "u2", 30)

      assert Enum.sort(Index.where(@entity, @field, 30, 30)) == ["u1", "u2"]
      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 30}
      assert Index.indexed_value(@entity, @field, "u2") == {:ok, 30}
    end

    test "is a no-op when (entity, field) is not indexed" do
      assert Index.update_index(@entity, :name, "u1", "x") == :ok
      assert Index.indexed_value(@entity, :name, "u1") == {:error, :no_index}
    end
  end

  describe "where/4 (indexed branch)" do
    setup do
      :ok = Index.create_index(@entity, @field)
      :ok = Index.update_index(@entity, @field, "u1", 10)
      :ok = Index.update_index(@entity, @field, "u2", 20)
      :ok = Index.update_index(@entity, @field, "u3", 30)
      :ok = Index.update_index(@entity, @field, "u4", 40)
      :ok
    end

    test "returns ids in [min, max]" do
      assert Enum.sort(Index.where(@entity, @field, 20, 30)) == ["u2", "u3"]
    end

    test "inclusive on both bounds" do
      assert Enum.sort(Index.where(@entity, @field, 10, 40)) == ["u1", "u2", "u3", "u4"]
    end

    test ":negative_infinity ignores the lower bound" do
      assert Enum.sort(Index.where(@entity, @field, :negative_infinity, 20)) == ["u1", "u2"]
    end

    test ":infinity ignores the upper bound" do
      assert Enum.sort(Index.where(@entity, @field, 30, :infinity)) == ["u3", "u4"]
    end

    test "both unbounded returns every entry" do
      assert Enum.sort(Index.where(@entity, @field, :negative_infinity, :infinity)) ==
               ["u1", "u2", "u3", "u4"]
    end

    test "empty range returns []" do
      assert Index.where(@entity, @field, 100, 200) == []
    end

    test "min > max returns []" do
      assert Index.where(@entity, @field, 40, 10) == []
    end

    test "point lookup (min == max)" do
      assert Index.where(@entity, @field, 20, 20) == ["u2"]
    end
  end

  describe "delete_index_entry/4" do
    setup do
      :ok = Index.create_index(@entity, @field)
      :ok
    end

    test "removes the matching entry from both directions" do
      :ok = Index.update_index(@entity, @field, "u1", 30)
      :ok = Index.update_index(@entity, @field, "u2", 30)

      assert Index.delete_index_entry(@entity, @field, "u1", 30) == :ok

      assert Index.indexed_value(@entity, @field, "u1") == {:error, :not_found}
      assert Index.where(@entity, @field, 30, 30) == ["u2"]
    end

    test "leaves data alone when value does not match the stored one" do
      :ok = Index.update_index(@entity, @field, "u1", 30)

      assert Index.delete_index_entry(@entity, @field, "u1", 99) == :ok

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 30}
      assert Index.where(@entity, @field, 30, 30) == ["u1"]
    end

    test "no-op when (entity, field) is not indexed" do
      assert Index.delete_index_entry(@entity, :name, "u1", "x") == :ok
    end

    test "no-op when the key was never indexed" do
      :ok = Index.update_index(@entity, @field, "u1", 30)
      assert Index.delete_index_entry(@entity, @field, "ghost", 1) == :ok

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 30}
      assert Index.where(@entity, @field, 30, 30) == ["u1"]
    end
  end

  describe "indexed_value/3" do
    test "returns the current value for a known key" do
      :ok = Index.create_index(@entity, @field)
      :ok = Index.update_index(@entity, @field, "u1", 42)

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 42}
    end

    test "returns :not_found when key is absent from a real index" do
      :ok = Index.create_index(@entity, @field)
      assert Index.indexed_value(@entity, @field, "ghost") == {:error, :not_found}
    end

    test "returns :no_index when (entity, field) is not indexed" do
      assert Index.indexed_value(@entity, :name, "u1") == {:error, :no_index}
    end
  end

  describe "fix_entry/5" do
    setup do
      :ok = Index.create_index(@entity, @field)
      :ok
    end

    test "writes the true value when stale_value is nil" do
      assert Index.fix_entry(@entity, @field, "u1", nil, 42) == :ok

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 42}
      assert Index.where(@entity, @field, 42, 42) == ["u1"]
    end

    test "removes the stale value before inserting the true one" do
      :ok = Index.update_index(@entity, @field, "u1", 30)

      assert Index.fix_entry(@entity, @field, "u1", 30, 99) == :ok

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 99}
      assert Index.where(@entity, @field, 30, 30) == []
      assert Index.where(@entity, @field, 99, 99) == ["u1"]
    end

    test "no-op when (entity, field) is not indexed" do
      assert Index.fix_entry(@entity, :name, "u1", "a", "b") == :ok
      assert Index.indexed_value(@entity, :name, "u1") == {:error, :no_index}
    end

    test "stale_value that does not exist still results in the true value being set" do
      assert Index.fix_entry(@entity, @field, "u1", 7, 42) == :ok

      assert Index.indexed_value(@entity, @field, "u1") == {:ok, 42}
      assert Index.where(@entity, @field, 42, 42) == ["u1"]
      assert Index.where(@entity, @field, 7, 7) == []
    end
  end

  describe "index_pairs/0" do
    test "returns [] when no indexes are registered" do
      assert Index.index_pairs() == []
    end

    test "lists every registered (entity, field) pair" do
      :ok = Schema.register(:post, %{score: :lww})
      :ok = Index.create_index(@entity, @field)
      :ok = Index.create_index(:post, :score)

      assert Enum.sort(Index.index_pairs()) == [{:post, :score}, {:user, :age}]
    end
  end
end
