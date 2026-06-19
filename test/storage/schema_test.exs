defmodule DS.Storage.SchemaTest do
  use ExUnit.Case, async: false

  alias DS.Storage.Schema

  @entity :user
  @schema %{name: :lww, age: :lww}

  setup_all do
    case Schema.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  setup do
    :ets.delete_all_objects(:schemas)
    :ok
  end

  describe "register/2" do
    test "stores a schema retrievable via get/1" do
      assert Schema.register(@entity, @schema) == :ok
      assert Schema.get(@entity) == {:ok, @schema}
    end

    test "overwrites a previous registration for the same entity" do
      :ok = Schema.register(@entity, %{name: :lww})
      :ok = Schema.register(@entity, %{name: :lww, age: :lww})

      assert Schema.get(@entity) == {:ok, %{name: :lww, age: :lww}}
    end

    test "supports multiple distinct entities" do
      :ok = Schema.register(:user, %{name: :lww})
      :ok = Schema.register(:post, %{title: :lww, score: :counter})

      assert Schema.get(:user) == {:ok, %{name: :lww}}
      assert Schema.get(:post) == {:ok, %{title: :lww, score: :counter}}
    end

    test "an empty schema is still a valid registration" do
      :ok = Schema.register(@entity, %{})
      assert Schema.get(@entity) == {:ok, %{}}
    end
  end

  describe "get/1" do
    test "returns :not_found for an unregistered entity" do
      assert Schema.get(:ghost) == {:error, :not_found}
    end

    test "returns the exact schema previously registered" do
      :ok = Schema.register(@entity, @schema)
      assert Schema.get(@entity) == {:ok, @schema}
    end
  end

  describe "get_field/2" do
    test "returns the field's merge strategy when the field exists" do
      :ok = Schema.register(@entity, @schema)
      assert Schema.get_field(@entity, :age) == {:ok, :lww}
    end

    test "returns :field_not_found when the field is absent from the schema" do
      :ok = Schema.register(@entity, @schema)
      assert Schema.get_field(@entity, :unknown) == {:error, :field_not_found}
    end

    test "returns :not_found when the entity itself was never registered" do
      assert Schema.get_field(:ghost, :age) == {:error, :not_found}
    end

    test "returns :field_not_found on an empty schema" do
      :ok = Schema.register(@entity, %{})
      assert Schema.get_field(@entity, :age) == {:error, :field_not_found}
    end
  end

  describe "valid_field?/2" do
    test "true when the field exists in the schema" do
      :ok = Schema.register(@entity, @schema)
      assert Schema.valid_field?(@entity, :age) == true
    end

    test "false when the field is missing from the schema" do
      :ok = Schema.register(@entity, @schema)
      assert Schema.valid_field?(@entity, :unknown) == false
    end

    test "false when the entity is unregistered" do
      assert Schema.valid_field?(:ghost, :age) == false
    end
  end

  describe "all_schemas/0" do
    test "returns [] when nothing has been registered" do
      assert Schema.all_schemas() == []
    end

    test "returns every registered entity/schema pair" do
      :ok = Schema.register(:user, %{name: :lww})
      :ok = Schema.register(:post, %{title: :lww})

      assert Enum.sort(Schema.all_schemas()) ==
               [{:post, %{title: :lww}}, {:user, %{name: :lww}}]
    end
  end
end
