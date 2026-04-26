defmodule SacrumWeb.NotInvitedLiveTest do
  use SacrumWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "not invited page" do
    test "renders the not invited error screen", %{conn: conn} do
      {:ok, view, html} = live(conn, "/not-invited")

      assert html =~ "Not invited yet"
      assert html =~ "have access"
      assert has_element?(view, "a#back-to-home[href='/']")
    end

    test "does not leak whether email is on invite list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/not-invited")

      refute html =~ "email not found"
      refute html =~ "invalid email"
      assert html =~ "have access"
    end

    test "has proper mobile responsive layout", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/not-invited")

      assert html =~ "max-w-md"
      assert html =~ "px-4"
      assert html =~ "sm:px-6"
    end

    test "displays Vertebrae header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/not-invited")

      assert html =~ "Vertebrae"
    end
  end
end
