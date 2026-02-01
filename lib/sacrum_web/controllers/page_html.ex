defmodule SacrumWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use SacrumWeb, :html

  embed_templates "page_html/*"
end
