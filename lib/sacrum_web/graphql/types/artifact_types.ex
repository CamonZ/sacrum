defmodule SacrumWeb.Graphql.Types.ArtifactTypes do
  @moduledoc """
  GraphQL type definitions for artifact resources.
  """

  use Absinthe.Schema.Notation

  object :artifact do
    field :id, :id
    field :project_id, :id
    field :artifact_type, :string
    field :artifact_state, :string
    field :redaction_state, :string
    field :title, :string
    field :content, :string
    field :data, :json
    field :storage_ref, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end
end
