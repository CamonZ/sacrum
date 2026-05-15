defmodule SacrumWeb.Graphql.Schema do
  @moduledoc """
  Root GraphQL schema combining all types, queries, and mutations.
  """

  use Absinthe.Schema

  # Import all type modules
  import_types(SacrumWeb.Graphql.Types.CustomScalars)
  import_types(SacrumWeb.Graphql.Types.ProjectType)
  import_types(SacrumWeb.Graphql.Types.WorkflowType)
  import_types(SacrumWeb.Graphql.Types.WorkflowStepType)
  import_types(SacrumWeb.Graphql.Types.TaskType)
  import_types(SacrumWeb.Graphql.Types.SectionTypes)
  import_types(SacrumWeb.Graphql.Types.TransitionTypes)
  import_types(SacrumWeb.Graphql.Types.ExecutionTypes)
  import_types(SacrumWeb.Graphql.Types.ChatTypes)
  import_types(SacrumWeb.Graphql.Types.ArtifactTypes)

  query do
    import_fields(:project_queries)
    import_fields(:workflow_queries)
    import_fields(:workflow_step_queries)
    import_fields(:task_queries)
    import_fields(:execution_queries)
    import_fields(:chat_queries)
  end

  mutation do
    import_fields(:project_mutations)
    import_fields(:workflow_mutations)
    import_fields(:workflow_step_mutations)
    import_fields(:task_mutations)
    import_fields(:section_mutations)
    import_fields(:transition_mutations)
    import_fields(:execution_mutations)
    import_fields(:chat_mutations)
    import_fields(:artifact_mutations)
  end

  @spec context(map()) :: map()
  def context(ctx) do
    loader =
      Dataloader.new()
      |> Dataloader.add_source(Sacrum.Accounts.Projects, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(Sacrum.Accounts.Workflows, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(Sacrum.Accounts.WorkflowSteps, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(Sacrum.Accounts.Tasks, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(Sacrum.Accounts.Sections, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(Sacrum.Accounts.CodeRefs, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(
        Sacrum.Accounts.WorkflowTransitions,
        Dataloader.Ecto.new(Sacrum.Repo)
      )
      |> Dataloader.add_source(Sacrum.Accounts.StepTransitions, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(Sacrum.Accounts.StepExecutions, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(Sacrum.Accounts.SessionLogs, Dataloader.Ecto.new(Sacrum.Repo))
      |> Dataloader.add_source(Sacrum.Accounts.TaskRuns, Dataloader.Ecto.new(Sacrum.Repo))

    Map.put(ctx, :loader, loader)
  end

  @spec plugins() :: [atom()]
  def plugins do
    [Absinthe.Middleware.Dataloader] ++ Absinthe.Plugin.defaults()
  end

  # Mutations are the only resolvers that return changeset errors. Appending
  # ChangesetErrors here converts a leaked {:error, %Ecto.Changeset{}} into a
  # structured GraphQL error instead of crashing Absinthe.
  @spec middleware(
          [Absinthe.Middleware.spec()],
          Absinthe.Type.Field.t(),
          Absinthe.Type.Object.t()
        ) ::
          [Absinthe.Middleware.spec()]
  def middleware(middleware, _field, %{identifier: :mutation}) do
    Enum.concat(middleware, [SacrumWeb.Graphql.Middleware.ChangesetErrors])
  end

  def middleware(middleware, _field, _object), do: middleware
end
