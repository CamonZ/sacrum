defmodule SacrumWeb.Graphql.Types.ArtifactTypes do
  @moduledoc """
  GraphQL types and mutations for project artifacts and artifact links.
  """

  use Absinthe.Schema.Notation

  alias Sacrum.Accounts

  object :artifact do
    field :id, :id
    field :artifact_type, :string
    field :artifact_state, :string
    field :title, :string
    field :content, :string
    field :data, :json
    field :storage_ref, :string
    field :visibility, :string
    field :redaction_state, :string
    field :project_id, :id
    field :user_id, :id
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end

  object :artifact_mutations do
    field :create_artifact, :artifact do
      arg(:project_id, non_null(:uuid4))
      arg(:artifact_type, non_null(:string))
      arg(:title, non_null(:string))
      arg(:content, :string)
      arg(:data, :json)
      arg(:storage_ref, :string)
      arg(:visibility, non_null(:string))
      arg(:artifact_state, :string)

      resolve(fn args, %{context: %{current_user: user}} ->
        %{project_id: project_id} = args

        attrs =
          args
          |> Map.drop([:project_id])
          |> Map.put_new(:artifact_state, "draft")
          |> Map.put_new(:redaction_state, "not_needed")

        Accounts.Artifacts.create(user.id, project_id, attrs)
      end)
    end

    @desc "Link an artifact to a subject (task, task_section, etc). Returns the linked artifact."
    field :create_artifact_link, :artifact do
      arg(:artifact_id, non_null(:uuid4))
      arg(:subject_type, non_null(:string))
      arg(:subject_id, non_null(:uuid4))
      arg(:relationship_kind, non_null(:string))
      arg(:project_id, :uuid4)
      arg(:metadata, :json)

      resolve(fn args, %{context: %{current_user: user}} ->
        with {:ok, project_id} <- resolve_project_id(args, user.id),
             {:ok, _link} <-
               Accounts.Artifacts.add_link(
                 user.id,
                 args.artifact_id,
                 args.subject_type,
                 args.subject_id,
                 project_id,
                 relationship_kind: args.relationship_kind,
                 metadata: Map.get(args, :metadata)
               ) do
          Accounts.Artifacts.get_for_project(user.id, args.artifact_id, project_id,
            internal: true
          )
        end
      end)
    end
  end

  defp resolve_project_id(%{project_id: project_id}, _user_id) when is_binary(project_id),
    do: {:ok, project_id}

  defp resolve_project_id(%{artifact_id: artifact_id}, user_id) do
    import Ecto.Query
    alias Sacrum.Repo
    alias Sacrum.Repo.Schemas.Artifact

    case Repo.one(
           from(a in Artifact,
             where: a.id == ^artifact_id and a.user_id == ^user_id,
             select: a.project_id
           )
         ) do
      nil -> {:error, :not_found}
      project_id -> {:ok, project_id}
    end
  end
end
