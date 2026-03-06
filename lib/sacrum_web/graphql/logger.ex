defmodule SacrumWeb.Graphql.Logger do
  require Logger

  @spec log(Plug.Conn.t(), Absinthe.Blueprint.t() | term()) :: Plug.Conn.t()
  def log(conn, %Absinthe.Blueprint{} = blueprint) do
    operation = List.first(blueprint.operations)

    if operation do
      op_type = operation.type || :query
      op_name = operation.name || "anonymous"
      Logger.info("[GraphQL] #{op_type} #{op_name}")
    end

    conn
  end

  def log(conn, _), do: conn
end
