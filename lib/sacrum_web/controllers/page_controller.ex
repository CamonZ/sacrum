defmodule SacrumWeb.PageController do
  use SacrumWeb, :controller

  def home(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
