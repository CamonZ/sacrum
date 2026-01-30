defmodule SacrumWeb.FallbackController do
  use SacrumWeb, :controller

  @doc """
  Converts various error tuples into appropriate HTTP responses.

  Handles the following error patterns:
  - {:error, changeset} - validation errors (422)
  - {:error, :not_found} - resource not found (404)
  - {:error, atom} - domain-specific errors (422)
  - {:error, atom, message} - domain errors with details (422)
  """

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: SacrumWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: SacrumWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :unprocessable_entity, message}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: SacrumWeb.ErrorJSON)
    |> json(%{errors: %{detail: message}})
  end

  # Domain-specific errors: return 422 with the error atom as detail
  def call(conn, {:error, reason}) when is_atom(reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: SacrumWeb.ErrorJSON)
    |> json(%{errors: %{detail: to_string(reason)}})
  end

  # Catch-all for unexpected error shapes - return 500 without crashing
  def call(conn, error) do
    require Logger
    Logger.error("FallbackController received unexpected error shape: #{inspect(error)}")

    conn
    |> put_status(:internal_server_error)
    |> put_view(json: SacrumWeb.ErrorJSON)
    |> json(%{errors: %{detail: "An unexpected error occurred"}})
  end
end
