defmodule SacrumWeb.PageController do
  use SacrumWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
