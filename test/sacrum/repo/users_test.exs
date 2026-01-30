defmodule Sacrum.Repo.UsersTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.User

  @valid_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  describe "insert/1" do
    test "creates a user with valid attributes" do
      assert {:ok, %User{} = user} = Users.insert(@valid_attrs)
      assert user.email == "test@example.com"
      assert user.username == "testuser"
      assert user.password_hash != nil
      assert user.id != nil
    end

    test "returns error with invalid attributes" do
      assert {:error, changeset} = Users.insert(%{})
      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error with duplicate email" do
      {:ok, _} = Users.insert(@valid_attrs)
      {:error, changeset} = Users.insert(@valid_attrs)
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "returns error with duplicate username" do
      {:ok, _} = Users.insert(@valid_attrs)
      {:error, changeset} = Users.insert(%{@valid_attrs | email: "other@example.com"})
      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "get/1" do
    test "returns user when found" do
      {:ok, user} = Users.insert(@valid_attrs)
      assert {:ok, found} = Users.get(user.id)
      assert found.id == user.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Users.get(Ecto.UUID.generate())
    end
  end

  describe "update/2" do
    test "updates user with valid attributes" do
      {:ok, user} = Users.insert(@valid_attrs)
      assert {:ok, updated} = Users.update(user, %{name: "Test User"})
      assert updated.name == "Test User"
    end

    test "updates email" do
      {:ok, user} = Users.insert(@valid_attrs)
      assert {:ok, updated} = Users.update(user, %{email: "new@example.com"})
      assert updated.email == "new@example.com"
    end

    test "returns error with invalid email" do
      {:ok, user} = Users.insert(@valid_attrs)
      assert {:error, changeset} = Users.update(user, %{email: "invalid"})
      assert %{email: ["must be a valid email"]} = errors_on(changeset)
    end
  end

  describe "update_password/2" do
    test "updates password" do
      {:ok, user} = Users.insert(@valid_attrs)
      old_hash = user.password_hash

      assert {:ok, updated} = Users.update_password(user, %{password: "newpassword123"})
      assert updated.password_hash != old_hash
    end

    test "returns error with short password" do
      {:ok, user} = Users.insert(@valid_attrs)
      assert {:error, changeset} = Users.update_password(user, %{password: "short"})
      assert %{password: ["should be at least 8 character(s)"]} = errors_on(changeset)
    end
  end

  describe "delete/1" do
    test "deletes user" do
      {:ok, user} = Users.insert(@valid_attrs)
      assert {:ok, _} = Users.delete(user)
      assert {:error, :not_found} = Users.get(user.id)
    end
  end
end
