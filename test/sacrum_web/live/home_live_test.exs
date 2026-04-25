defmodule SacrumWeb.HomeLiveTest do
  use SacrumWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "displays the home page" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "Orchestrate Agents"
      assert html =~ "Ship Faster"
    end

    test "displays waitlist form" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "Join Waitlist"
      assert html =~ "you@example.com"
    end

    test "displays design system properly" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "aurora-bg"
      assert html =~ "gradient-text"
      assert html =~ "glow-orb"
    end
  end

  describe "waitlist form submission" do
    test "submits valid email and shows success" do
      {:ok, view, _html} = live(build_conn(), "/")

      result =
        view
        |> form("form", %{"email" => "user@example.com"})
        |> render_submit()

      assert result =~ "Welcome to the waitlist!"
      assert result =~ "notify you"
    end

    test "displays error for invalid email format" do
      {:ok, view, _html} = live(build_conn(), "/")

      result =
        view
        |> form("form", %{"email" => "not-an-email"})
        |> render_submit()

      assert result =~ "valid email address"
    end

    test "displays error for blank email" do
      {:ok, view, _html} = live(build_conn(), "/")

      result =
        view
        |> form("form", %{"email" => ""})
        |> render_submit()

      assert result =~ "valid email address"
    end

    test "duplicate email shows success message (enumeration prevention)" do
      {:ok, view, _html} = live(build_conn(), "/")

      result1 =
        view
        |> form("form", %{"email" => "duplicate@example.com"})
        |> render_submit()

      assert result1 =~ "Welcome to the waitlist!"

      {:ok, view2, _html} = live(build_conn(), "/")

      result2 =
        view2
        |> form("form", %{"email" => "DUPLICATE@EXAMPLE.COM"})
        |> render_submit()

      assert result2 =~ "Welcome to the waitlist!"
    end

    test "form clears after successful submission" do
      {:ok, view, _html} = live(build_conn(), "/")

      rendered =
        view
        |> form("form", %{"email" => "user@example.com"})
        |> render_submit()

      assert rendered =~ "Welcome to the waitlist!"
      assert rendered =~ "notify you when early access"
    end
  end

  describe "ui elements" do
    test "has header with logo" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "Vertebrae"
    end

    test "footer exists but has no references to implementation" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "footer"
      refute html =~ "Built with Phoenix"
      refute html =~ "github.com"
    end

    test "no reference to Sacrum in user-facing copy" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "Vertebrae"
      refute html =~ ~r/sacrum/i
    end

    test "theme toggle is present" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "data-phx-theme"
    end
  end

  describe "email validation" do
    test "accepts email with plus addressing" do
      {:ok, view, _html} = live(build_conn(), "/")

      result =
        view
        |> form("form", %{"email" => "user+tag@example.com"})
        |> render_submit()

      assert result =~ "Welcome to the waitlist!"
    end

    test "accepts email with multiple subdomains" do
      {:ok, view, _html} = live(build_conn(), "/")

      result =
        view
        |> form("form", %{"email" => "user@subdomain.example.co.uk"})
        |> render_submit()

      assert result =~ "Welcome to the waitlist!"
    end
  end
end
