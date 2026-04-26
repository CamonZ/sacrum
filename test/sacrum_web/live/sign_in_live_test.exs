defmodule SacrumWeb.SignInLiveTest do
  use SacrumWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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
  end
end
