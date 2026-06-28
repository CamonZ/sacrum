defmodule SacrumWeb.HomeLiveTest do
  use SacrumWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "mount" do
    test "displays the home page" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "Orchestrate Agents"
      assert html =~ "Ship Faster"
      assert html =~ "workflow state"
    end

    test "does not render a browser signup form" do
      {:ok, _view, html} = live(build_conn(), "/")

      refute html =~ "<form"
      refute html =~ ~s(type="email")
      refute html =~ "<a "
    end

    test "displays Articulated design system properly" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "bg-border"
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

      assert html =~ ~r/flex.*gap.*bg-border/
    end

    test "no decorative classes present" do
      {:ok, _view, html} = live(build_conn(), "/")

      refute html =~ "aurora-bg"
      refute html =~ "glow-orb"
      refute html =~ "gradient-text"
      refute html =~ "shadow-glow"
      refute html =~ "magnetic-btn"
      refute html =~ "tilt-card"
    end

    test "uses Articulated color tokens not Neural Pathways palette" do
      {:ok, _view, html} = live(build_conn(), "/")

      refute html =~ "gradient-to-r"
      refute html =~ "via-primary/30"
      refute html =~ "from-primary to-accent"
    end

    test "minimal borders only, no shadows in structure" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ "border-b"
      assert html =~ "border-border"
      refute html =~ "shadow-"
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
