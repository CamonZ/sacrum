defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.Route do
  @moduledoc """
  Config for `route` steps. `route_config` may be nil while the route is being
  authored; graph validation rejects an unconfigured route before it can run.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Routing.RouteConfig

  @type t :: %__MODULE__{}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :route_config, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    config
    |> cast(params, __schema__(:fields))
    |> Config.validate_version()
    |> validate_route_config()
  end

  defp validate_route_config(changeset) do
    with route_config when not is_nil(route_config) <- get_field(changeset, :route_config),
         {:error, %{path: path, message: message}} <- RouteConfig.decode(route_config) do
      add_error(changeset, :route_config, "#{path}: #{message}")
    else
      _valid -> changeset
    end
  end
end
