defmodule SacrumWeb.HomeLiveTest do
  use SacrumWeb.ConnCase

  import Phoenix.LiveViewTest

  @vertebrae_repo "https://github.com/CamonZ/vertebrae"
  @sacrum_repo "https://github.com/CamonZ/sacrum"

  describe "landing page components" do
    test "renders the Vertebrae brand, hero, and marketing primitives" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert has_element?(view, "#brand-link", "Vertebrae")
      assert has_element?(view, "#hero-eyebrow", "The execution spine")
      assert has_element?(view, "h1#hero-heading", "Make agentic work move.")
      assert has_element?(view, "#hero-workflow-visual")
      assert has_element?(view, "#workflow-spine-chain")
      assert has_element?(view, "#capability-workflows")
      assert has_element?(view, "#repository-cards")
    end

    test "renders labeled calls to action and theme controls" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert has_element?(view, "#hero-vertebrae-cta", "Explore Frontend Source")
      assert has_element?(view, "#hero-sacrum-cta", "Explore Backend Source")
      assert has_element?(view, "#theme-toggle")
      assert has_element?(view, "#theme-system[data-phx-theme=system]")
      assert has_element?(view, "#theme-light[data-phx-theme=light]")
      assert has_element?(view, "#theme-dark[data-phx-theme=dark]")
    end
  end

  describe "GET / integration" do
    test "renders semantic landmarks and the primary heading hierarchy" do
      {:ok, view, html} = live(build_conn(), "/")

      assert has_element?(view, "header#site-header")
      assert has_element?(view, "nav#primary-navigation")
      assert has_element?(view, "main#landing-main")
      assert has_element?(view, "footer#site-footer")
      assert has_element?(view, "h1#hero-heading")
      assert has_element?(view, "h2#spine-heading")
      assert has_element?(view, "h2#capabilities-heading")
      assert has_element?(view, "h2#repositories-heading")

      assert html =~ ~r/<h1\b/
    end

    test "links to the canonical Sacrum and Vertebrae repositories" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert has_element?(view, ~s|#hero-vertebrae-cta[href="#{@vertebrae_repo}"]|)
      assert has_element?(view, ~s|#hero-sacrum-cta[href="#{@sacrum_repo}"]|)
      assert has_element?(view, ~s|#repository-vertebrae[href="#{@vertebrae_repo}"]|)
      assert has_element?(view, ~s|#repository-sacrum[href="#{@sacrum_repo}"]|)
    end

    test "uses Vertebrae-first copy and describes Sacrum as the backend" do
      {:ok, view, html} = live(build_conn(), "/")

      assert has_element?(view, "#marketing-page", "Vertebrae")
      assert has_element?(view, "#spine", "backend coordination layer")
      refute html =~ "Orchestrate Agents"
      refute html =~ "Vertebrae coordinates local task execution"
    end
  end

  describe "accessibility and design guardrails" do
    test "provides keyboard focus styling and reduced-motion handling" do
      css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

      assert css =~ ":focus-visible"
      assert css =~ "outline: 2px solid var(--color-accent)"
      assert css =~ "prefers-reduced-motion: reduce"
      assert css =~ "transition-duration: 0.01ms !important"
      assert css =~ "--font-serif: \"Newsreader\""
      assert css =~ "--font-mono: \"JetBrains Mono\""
    end

    test "defines readable light and dark theme ramps in one token layer" do
      css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

      assert css =~ ~s([data-theme="light"])
      assert css =~ ~s([data-theme="dark"])
      assert css =~ "--color-bg: #100e0c"
      assert css =~ "--color-bg: #faf6ec"
      assert css =~ "--color-text-primary: #e8e5dd"
      assert css =~ "--color-text-primary: #1a1a20"

      js = File.read!(Path.expand("../../../assets/js/app.js", __DIR__))
      assert js =~ ~s(const THEME_KEY = "phx:theme")
      assert js =~ ~s(const CONSENT_KEY = "sacrum_consent")
      assert js =~ "sacrum_consent=([^;]+)"
      assert js =~ "aria-pressed"
      assert js =~ "localStorage"
    end

    test "keeps navigation, sections, and cards usable at mobile widths" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert has_element?(view, "#site-header div.flex-wrap")
      assert has_element?(view, "#primary-navigation.w-full")
      assert has_element?(view, "#hero-workflow-visual")
      assert has_element?(view, "#capability-grid.md\\:grid-cols-3")
      assert has_element?(view, "#repository-cards.lg\\:grid-cols-2")
      assert has_element?(view, "#spine div.overflow-x-auto")

      assert has_element?(
               view,
               "#workflow-spine-chain [role=listitem][aria-current=step][aria-label='Workflow, current step']"
             )
    end

    test "does not introduce generic SaaS decoration" do
      {:ok, _view, html} = live(build_conn(), "/")

      refute html =~ "aurora"
      refute html =~ "gradient-text"
      refute html =~ "glow-orb"
      refute html =~ "tilt-card"
    end
  end

  describe "cookie banner" do
    test "is rendered as an initially hidden accessible region" do
      {:ok, view, _html} = live(build_conn(), "/")

      assert has_element?(view, "#cookie-banner[hidden]")
      assert has_element?(view, "#cookie-banner[role=region][aria-label='Cookie consent']")
      assert has_element?(view, "#cookie-ok", "OK")
    end
  end
end
