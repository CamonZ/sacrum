defmodule SacrumWeb.AuthIntegrationTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{User, Invite}

  describe "auth flow integration" do
    test "uninvited users cannot sign in" do
      user_attrs = %{
        google_sub: "google789",
        email: "uninvited@example.com",
        name: "Uninvited User",
        avatar_url: "https://example.com/avatar.jpg"
      }

      assert {:error, :not_invited} = Sacrum.Accounts.Auth.find_or_invite_user(user_attrs)
    end

    test "invited user is created on first sign-in" do
      {:ok, _invite} =
        Repo.Invites.insert(Invite.create_changeset(%Invite{}, %{email: "newuser@example.com"}))

      user_attrs = %{
        google_sub: "google123",
        email: "newuser@example.com",
        name: "New User",
        avatar_url: "https://example.com/avatar.jpg"
      }

      assert {:ok, user} = Sacrum.Accounts.Auth.find_or_invite_user(user_attrs)
      assert user.email == "newuser@example.com"
      assert user.google_sub == "google123"
    end

    test "sign-out clears session and redirects to home", %{conn: conn} do
      {:ok, user} =
        %User{}
        |> User.oauth_changeset(%{
          email: "test@example.com",
          google_sub: "google123",
          name: "Test User"
        })
        |> Repo.Users.insert()

      result_conn =
        conn
        |> Plug.Test.init_test_session(%{"user_id" => user.id})
        |> post("/auth/session")

      assert redirected_to(result_conn) == "/"
      assert result_conn.private[:plug_session] != nil
    end

    test "state mismatch during OAuth redirects to auth-error", %{conn: conn} do
      result_conn =
        conn
        |> Plug.Test.init_test_session(%{:oauth_state => "correct_state"})
        |> get("/auth/google/callback", %{"state" => "wrong_state", "code" => "code"})

      assert redirected_to(result_conn) == "/auth-error"
    end
  end
end
