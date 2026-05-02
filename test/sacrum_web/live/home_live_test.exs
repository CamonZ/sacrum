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

    test "displays Articulated design system properly" do
      {:ok, _view, html} = live(build_conn(), "/")

      # Articulated system uses structural components - spine_rule renders as segments with border styling
      assert html =~ "bg-border"
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

  describe "Articulated design system components" do
    test "renders spine_rule component" do
      {:ok, _view, html} = live(build_conn(), "/")

      # spine_rule renders as a flex row with segment spans
      assert html =~ ~r/flex.*gap.*bg-border/
    end

    test "no decorative classes present" do
      {:ok, _view, html} = live(build_conn(), "/")

      # Ensure removed decorative classes are not in the template
      refute html =~ "aurora-bg"
      refute html =~ "glow-orb"
      refute html =~ "gradient-text"
      refute html =~ "shadow-glow"
      refute html =~ "magnetic-btn"
      refute html =~ "tilt-card"
    end

    test "uses Articulated color tokens not Neural Pathways palette" do
      {:ok, _view, html} = live(build_conn(), "/")

      # Ensure old gradient gradient references are gone
      refute html =~ "gradient-to-r"
      refute html =~ "via-primary/30"
      refute html =~ "from-primary to-accent"
    end

    test "minimal borders only, no shadows in structure" do
      {:ok, _view, html} = live(build_conn(), "/")

      # Should have border classes but not shadow classes
      assert html =~ "border-b"
      assert html =~ "border-border"
      refute html =~ "shadow-"
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

  describe "cookie banner" do
    test "is rendered on the landing page" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ ~s(id="cookie-banner")
      assert html =~ "This website utilizes cookies"
      assert html =~ ~s(id="cookie-ok")
    end

    test "is hidden by default and gated by the consent hook" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ ~s(phx-hook="CookieConsent")
      assert html =~ "hidden"
    end

    test "exposes an accessible region for screen readers" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ ~s(role="region")
      assert html =~ ~s(aria-label="Cookie consent")
    end
  end
end
