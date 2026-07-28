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
      arg(:subject_type, :string)
      arg(:subject_id, :uuid4)

      resolve(fn %{project_id: project_id} = args, %{context: %{current_user: user}} ->
        artifact_attrs = Map.take(args, [:filename, :body])

        with {:ok, link_attrs} <- create_link_attrs(args, project_id),
             {:ok, %{artifact: artifact}} <-
               Accounts.Artifacts.create_and_link(
                 user.id,
                 project_id,
                 artifact_attrs,
                 link_attrs
               ) do
          {:ok, artifact}
        end
      end)
    end

    field :update_artifact, :artifact do
      arg(:id, non_null(:uuid4))
      arg(:filename, :string)
      arg(:body, :string)
      arg(:subject_type, :string)
      arg(:subject_id, :uuid4)

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        artifact_attrs = Map.take(args, [:filename, :body])

        with {:ok, attachment_attrs} <- attachment_attrs(args) do
          Accounts.Artifacts.update(user.id, id, artifact_attrs, attachment_attrs)
        end
      end)
    end

    field :delete_artifact, :artifact do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        Accounts.Artifacts.delete(user.id, id)
      end)
    end
  end

  defp attachment_attrs(args) do
    case {Map.get(args, :subject_type), Map.get(args, :subject_id)} do
      {nil, nil} ->
        {:ok, nil}

      {subject_type, subject_id} when is_binary(subject_type) and is_binary(subject_id) ->
        {:ok, %{subject_type: subject_type, subject_id: subject_id}}

      _ ->
        {:error, "subjectType and subjectId must be provided together"}
    end
  end

  defp create_link_attrs(args, project_id) do
    case attachment_attrs(args) do
      {:ok, nil} ->
        {:ok,
         %{subject_type: "project", subject_id: project_id, relationship_kind: "attached_to"}}

      {:ok, attachment_attrs} ->
        {:ok, Map.put(attachment_attrs, :relationship_kind, "attached_to")}

      error ->
        error
    end
  end
end
