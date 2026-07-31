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
    field :logical_name, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end

  object :artifact_queries do
    field :artifact, :artifact do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        Accounts.Artifacts.get(user.id, id)
      end)
    end

    field :artifact_by_logical_name, :artifact do
      arg(:project_id, non_null(:uuid4))
      arg(:subject_type, non_null(:string))
      arg(:subject_id, non_null(:uuid4))
      arg(:logical_name, non_null(:string))

      resolve(fn args, %{context: %{current_user: user}} ->
        Accounts.Artifacts.get_for_subject_by_logical_name(
          user.id,
          args.project_id,
          args.subject_type,
          args.subject_id,
          args.logical_name
        )
      end)
    end
  end

  object :artifact_mutations do
    field :create_artifact, :artifact do
      arg(:project_id, non_null(:uuid4))
      arg(:filename, non_null(:string))
      arg(:body, non_null(:string))
      arg(:subject_type, :string)
      arg(:subject_id, :uuid4)
      arg(:logical_name, :string)

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
      arg(:logical_name, :string)

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
    case {Map.get(args, :subject_type), Map.get(args, :subject_id),
          Map.has_key?(args, :logical_name)} do
      {nil, nil, false} ->
        {:ok, nil}

      {nil, nil, true} ->
        {:ok, Map.take(args, [:logical_name])}

      {subject_type, subject_id, _} when is_binary(subject_type) and is_binary(subject_id) ->
        {:ok, Map.take(args, [:subject_type, :subject_id, :logical_name])}

      _ ->
        {:error, "subjectType and subjectId must be provided together"}
    end
  end

  defp create_link_attrs(args, project_id) do
    case attachment_attrs(args) do
      {:ok, nil} ->
        {:ok, %{subject_type: "project", subject_id: project_id}}

      {:ok, %{subject_type: _, subject_id: _} = attachment_attrs} ->
        {:ok, attachment_attrs}

      {:ok, attachment_attrs} ->
        {:ok,
         Map.merge(
           %{subject_type: "project", subject_id: project_id},
           attachment_attrs
         )}

      error ->
        error
    end
  end
end
