defmodule SacrumWeb.SignInLiveTest do
  use SacrumWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp authed_conn(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{"user_id" => user.id})
  end

  describe "sign-in page" do
    test "renders the sign-in page with Google button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sign-in")

      assert html =~ "Sign in to Vertebrae"
      assert html =~ "Continue with Google"
      assert html =~ "id=\"sign-in-button\""
    end

    test "has proper mobile responsive layout", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sign-in")

      assert html =~ "max-w-md"
      assert html =~ "px-4"
      assert html =~ "sm:px-6"
      assert html =~ "lg:px-8"
    end

    test "sign-in button links to Google OAuth endpoint", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sign-in")

      assert has_element?(view, "a#sign-in-button[href='/auth/google']")
    end

    test "back link points to home page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sign-in")

      assert has_element?(view, "a[href='/']")
    end

    test "displays Vertebrae header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/sign-in")

      assert html =~ "Vertebrae"
    end

    test "authenticated users are sent to the preserved home route" do
      user = create_user(%{email: "signedin@example.com", username: "signedin"})

      assert {:error, {:live_redirect, %{to: "/"}}} = live(authed_conn(user), "/sign-in")
    end
  end
end
