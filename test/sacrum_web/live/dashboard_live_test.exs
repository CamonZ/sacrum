defmodule SacrumWeb.DashboardLiveTest do
  use SacrumWeb.ConnCase

  import Phoenix.LiveViewTest

  defp authed_conn(user) do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{"user_id" => user.id})
  end

  describe "mount" do
    test "renders the empty dashboard shell" do
      user = create_user(%{username: "dashboarduser"})

      {:ok, _view, html} = live(authed_conn(user), "/dashboard")

      assert html =~ ~s(id="dashboard")
      assert html =~ ~s(aria-label="Dashboard")
    end
  end

  describe "route" do
    test "requires authentication" do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), "/dashboard")
    end

    test "authenticated browser request returns a successful LiveView response using the app layout" do
      user = create_user(%{username: "dashboardlayoutuser"})

      {:ok, _view, html} = live(authed_conn(user), "/dashboard")

      assert html =~ ~s(href="/dashboard")
      refute html =~ ~s(href="/command-center")
      refute html =~ ~s(href="/tasks")
      refute html =~ ~s(href="/workflows")
      refute html =~ ~s(href="/traces")
      assert html =~ ~s(action="/auth/session")
      assert html =~ user.email
    end
  end
end
