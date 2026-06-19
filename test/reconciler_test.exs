defmodule DS.ReconcilerTest do
  use ExUnit.Case, async: false

  alias DS.Reconciler
  alias DS.Storage.Index
  alias DS.Storage.Schema

  @entity :user

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

    :ok = Schema.register(@entity, %{age: :lww, name: :lww, score: :lww})
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

  # Record format consumed by reconcile_record/3:
  # %{field_name => {type, true_value, clock}}
  defp record(fields) do
    Map.new(fields, fn {field, value} -> {field, {:lww, value, %{a: 1}}} end)
  end

  describe "reconcile_record/3" do
    test "no-op when the index already holds the true value" do
      :ok = Index.create_index(@entity, :age)
      :ok = Index.update_index(@entity, :age, "u1", 30)

      assert Reconciler.reconcile_record(@entity, "u1", record(age: 30)) == :ok

      assert Index.indexed_value(@entity, :age, "u1") == {:ok, 30}
      assert Index.where(@entity, :age, 30, 30) == ["u1"]
    end

    test "overwrites a stale index value with the true value" do
      :ok = Index.create_index(@entity, :age)
      :ok = Index.update_index(@entity, :age, "u1", 30)

      assert Reconciler.reconcile_record(@entity, "u1", record(age: 99)) == :ok

      assert Index.indexed_value(@entity, :age, "u1") == {:ok, 99}
      assert Index.where(@entity, :age, 30, 30) == []
      assert Index.where(@entity, :age, 99, 99) == ["u1"]
    end

    test "inserts a new index entry when the key was never indexed" do
      :ok = Index.create_index(@entity, :age)

      assert Reconciler.reconcile_record(@entity, "u1", record(age: 42)) == :ok

      assert Index.indexed_value(@entity, :age, "u1") == {:ok, 42}
      assert Index.where(@entity, :age, 42, 42) == ["u1"]
    end

    test "no-op for fields that have no index" do
      assert Reconciler.reconcile_record(@entity, "u1", record(name: "alice")) == :ok

      assert Index.indexed_value(@entity, :name, "u1") == {:error, :no_index}
    end

    test "processes every field independently when the record carries several" do
      :ok = Index.create_index(@entity, :age)
      :ok = Index.create_index(@entity, :score)

      :ok = Index.update_index(@entity, :age, "u1", 30)
      # :score has no value yet for u1

      assert Reconciler.reconcile_record(
               @entity,
               "u1",
               record(age: 31, score: 100, name: "ignored")
             ) == :ok

      assert Index.indexed_value(@entity, :age, "u1") == {:ok, 31}
      assert Index.indexed_value(@entity, :score, "u1") == {:ok, 100}
      assert Index.indexed_value(@entity, :name, "u1") == {:error, :no_index}

      assert Index.where(@entity, :age, 30, 30) == []
      assert Index.where(@entity, :age, 31, 31) == ["u1"]
      assert Index.where(@entity, :score, 100, 100) == ["u1"]
    end

    test "empty record is a no-op" do
      :ok = Index.create_index(@entity, :age)
      :ok = Index.update_index(@entity, :age, "u1", 30)

      assert Reconciler.reconcile_record(@entity, "u1", %{}) == :ok

      assert Index.indexed_value(@entity, :age, "u1") == {:ok, 30}
    end

    test "does not affect other keys sharing the same value" do
      :ok = Index.create_index(@entity, :age)
      :ok = Index.update_index(@entity, :age, "u1", 30)
      :ok = Index.update_index(@entity, :age, "u2", 30)

      assert Reconciler.reconcile_record(@entity, "u1", record(age: 99)) == :ok

      assert Index.indexed_value(@entity, :age, "u1") == {:ok, 99}
      assert Index.indexed_value(@entity, :age, "u2") == {:ok, 30}
      assert Enum.sort(Index.where(@entity, :age, 30, 30)) == ["u2"]
      assert Index.where(@entity, :age, 99, 99) == ["u1"]
    end
  end
end
