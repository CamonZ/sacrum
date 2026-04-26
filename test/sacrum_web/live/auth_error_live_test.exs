defmodule SacrumWeb.AuthErrorLiveTest do
  use SacrumWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "auth error page" do
    test "renders the auth error screen with recovery actions", %{conn: conn} do
      {:ok, view, html} = live(conn, "/auth-error")

      assert html =~ "Authentication failed"
      assert html =~ "Something went wrong"
      assert has_element?(view, "a#retry-sign-in[href='/sign-in']")
      assert has_element?(view, "a#back-home[href='/']")
    end

    test "has proper mobile responsive layout", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/auth-error")

      assert html =~ "max-w-md"
      assert html =~ "px-4"
      assert html =~ "sm:px-6"
    end

    test "displays Vertebrae header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/auth-error")

      assert html =~ "Vertebrae"
    end
  end
end
