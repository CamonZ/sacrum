defmodule SacrumWeb.Graphql.Types.ArtifactTypes do
  @moduledoc """
  GraphQL type definitions for artifact resources.
  """

  use Absinthe.Schema.Notation

  alias Sacrum.Accounts

  object :artifact do
    field :id, :id
    field :filename, :string
    field :body, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end

  object :artifact_mutations do
    field :create_artifact, :artifact do
      arg(:project_id, non_null(:uuid4))
      arg(:filename, non_null(:string))
      arg(:body, non_null(:string))

      resolve(fn %{project_id: project_id} = args, %{context: %{current_user: user}} ->
        artifact_attrs = Map.take(args, [:filename, :body])

        link_attrs = %{
          subject_type: "project",
          subject_id: project_id,
          relationship_kind: "attached_to"
        }

        case Accounts.Artifacts.create_and_link(
               user.id,
               project_id,
               artifact_attrs,
               link_attrs
             ) do
          {:ok, %{artifact: artifact}} -> {:ok, artifact}
          {:error, reason} -> {:error, reason}
        end
      end)
    end
  end
end
