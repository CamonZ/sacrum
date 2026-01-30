defmodule SacrumWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use SacrumWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint SacrumWeb.Endpoint

      use SacrumWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import SacrumWeb.ConnCase
    end
  end

  setup tags do
    Sacrum.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Creates a test user with the given attributes.

  If no attributes are provided, uses a default set:
  - email: "test@example.com"
  - username: "testuser"
  - password: "password123"
  """
  def create_user(attrs \\ %{}) do
    default_attrs = %{
      email: "test@example.com",
      username: "testuser",
      password: "password123"
    }

    attrs = Map.merge(default_attrs, attrs)
    {:ok, user} = Sacrum.Repo.Users.insert(attrs)
    user
  end

  @doc """
  Authenticates a connection with a user's API token.

  Creates an API token for the user and adds it to the
  connection as a Bearer token in the Authorization header.
  """
  def authenticate(conn, user) do
    {:ok, token, _api_token} = Sacrum.Auth.create_api_token(user)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")
  end

end
