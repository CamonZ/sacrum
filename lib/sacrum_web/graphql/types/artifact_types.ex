defmodule SacrumWeb.Graphql.Types.ArtifactTypes do
  @moduledoc """
  GraphQL type definitions for artifact resources.
  """

  use Absinthe.Schema.Notation

  object :artifact do
    field :id, :id
    field :artifact_type, :string
    field :artifact_state, :string
    field :redaction_state, :string
    field :title, :string
    field :content, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end
end
