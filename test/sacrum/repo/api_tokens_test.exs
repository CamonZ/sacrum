defmodule Sacrum.Repo.ApiTokensTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.ApiTokens
  alias Sacrum.Repo.Schemas.ApiToken

  @user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user do
    {:ok, user} = Users.insert(@user_attrs)
    user
  end

  defp valid_token_attrs(user) do
    %{
      token_hash: "hashed_token_#{System.unique_integer()}",
      user_id: user.id
    }
  end

  describe "insert/1" do
    test "creates a token with valid attributes" do
      user = create_user()
      attrs = valid_token_attrs(user)

      assert {:ok, %ApiToken{} = token} = ApiTokens.insert(attrs)
      assert token.user_id == user.id
      assert token.token_hash == attrs.token_hash
      assert token.id != nil
    end

    test "creates a token with optional attributes" do
      user = create_user()
      attrs = valid_token_attrs(user) |> Map.merge(%{name: "My Token", scopes: ["read", "write"]})

      assert {:ok, %ApiToken{} = token} = ApiTokens.insert(attrs)
      assert token.name == "My Token"
      assert token.scopes == ["read", "write"]
    end

    test "returns error without user_id" do
      assert {:error, changeset} = ApiTokens.insert(%{token_hash: "hash"})
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error without token_hash" do
      user = create_user()
      assert {:error, changeset} = ApiTokens.insert(%{user_id: user.id})
      assert %{token_hash: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "get/1" do
    test "returns token when found" do
      user = create_user()
      {:ok, token} = ApiTokens.insert(valid_token_attrs(user))

      assert {:ok, found} = ApiTokens.get(token.id)
      assert found.id == token.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = ApiTokens.get(Ecto.UUID.generate())
    end
  end

  describe "get!/1" do
    test "returns token when found" do
      user = create_user()
      {:ok, token} = ApiTokens.insert(valid_token_attrs(user))

      assert %ApiToken{} = ApiTokens.get!(token.id)
    end

    test "raises when not found" do
      assert_raise Ecto.NoResultsError, fn ->
        ApiTokens.get!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_by/1" do
    test "returns token when found by token_hash" do
      user = create_user()
      attrs = valid_token_attrs(user)
      {:ok, token} = ApiTokens.insert(attrs)

      assert {:ok, found} = ApiTokens.get_by(token_hash: attrs.token_hash)
      assert found.id == token.id
    end

    test "returns token when found by user_id and id" do
      user = create_user()
      {:ok, token} = ApiTokens.insert(valid_token_attrs(user))

      assert {:ok, found} = ApiTokens.get_by(id: token.id, user_id: user.id)
      assert found.id == token.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = ApiTokens.get_by(token_hash: "nonexistent")
    end
  end

  describe "list/0" do
    test "returns empty list when no tokens" do
      assert [] = ApiTokens.list()
    end

    test "returns all tokens" do
      user = create_user()
      {:ok, token1} = ApiTokens.insert(valid_token_attrs(user))
      {:ok, token2} = ApiTokens.insert(valid_token_attrs(user))

      tokens = ApiTokens.list()
      assert length(tokens) == 2
      assert Enum.any?(tokens, &(&1.id == token1.id))
      assert Enum.any?(tokens, &(&1.id == token2.id))
    end
  end

  describe "for_user/1" do
    test "returns query scoped to user" do
      user1 = create_user()
      {:ok, user2} = Users.insert(%{@user_attrs | email: "other@example.com", username: "other"})

      {:ok, token1} = ApiTokens.insert(valid_token_attrs(user1))
      {:ok, _token2} = ApiTokens.insert(valid_token_attrs(user2))

      tokens = ApiTokens.for_user(user1.id) |> ApiTokens.list()
      assert length(tokens) == 1
      assert hd(tokens).id == token1.id
    end
  end

  describe "update/2" do
    test "updates token with valid attributes" do
      user = create_user()
      {:ok, token} = ApiTokens.insert(valid_token_attrs(user))

      assert {:ok, updated} = ApiTokens.update(token, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
    end
  end

  describe "delete/1" do
    test "deletes token" do
      user = create_user()
      {:ok, token} = ApiTokens.insert(valid_token_attrs(user))

      assert {:ok, _} = ApiTokens.delete(token)
      assert {:error, :not_found} = ApiTokens.get(token.id)
    end

    test "cascade deletes tokens when user is deleted" do
      user = create_user()
      {:ok, token} = ApiTokens.insert(valid_token_attrs(user))

      {:ok, _} = Users.delete(user)
      assert {:error, :not_found} = ApiTokens.get(token.id)
    end
  end

  describe "query/0" do
    test "returns queryable" do
      user = create_user()
      {:ok, _} = ApiTokens.insert(valid_token_attrs(user))

      query = ApiTokens.query()
      assert [%ApiToken{}] = Sacrum.Repo.all(query)
    end
  end
end
