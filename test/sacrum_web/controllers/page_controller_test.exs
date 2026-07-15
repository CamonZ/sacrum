defmodule SacrumWeb.PageControllerTest do
  use SacrumWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Vertebrae"
    assert html =~ "Make agentic work"
    assert html =~ "https://github.com/CamonZ/vertebrae"
    assert html =~ "https://github.com/CamonZ/sacrum"
  end
end
