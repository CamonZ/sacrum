defmodule SacrumWeb.PageControllerTest do
  use SacrumWeb.ConnCase

  test "GET / returns health check", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
