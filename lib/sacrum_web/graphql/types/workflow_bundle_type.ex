defmodule SacrumWeb.Graphql.Types.WorkflowBundleType do
  @moduledoc """
  GraphQL types for atomic portable workflow bundle imports.
  """

  use Absinthe.Schema.Notation

  alias Sacrum.Accounts

  object :workflow_bundle_import_result do
    field :workflows, list_of(:workflow)
    field :workflow_steps, list_of(:workflow_step)
    field :workflow_mappings, :json
    field :step_mappings, :json
    field :id_mappings, :json
    field :workflow_count, non_null(:integer)
    field :step_count, non_null(:integer)
    field :step_edge_count, non_null(:integer)
    field :workflow_edge_count, non_null(:integer)
  end

  object :workflow_bundle_mutations do
    field :import_workflow_bundle, :workflow_bundle_import_result do
      arg(:project_id, non_null(:uuid4))
      arg(:bundle, non_null(:json))

      resolve(fn %{project_id: project_id, bundle: bundle}, %{context: %{current_user: user}} ->
        Accounts.WorkflowBundles.import(user.id, project_id, bundle)
      end)
    end
  end
end
