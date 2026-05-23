defmodule Sacrum.Accounts.AuthoringRunKinds do
  @moduledoc """
  Single source of truth for the authoring run-kind descriptors.

  Each descriptor encodes the tuple of identifiers that together drive an
  authoring session through `Sacrum.Accounts.AuthoringChatLoop`,
  `Sacrum.Accounts.AuthoringTemplateLookup`, and
  `Sacrum.Accounts.InitialAuthoringDraftRenderer`.

  Other modules (system prompt builder, tool argument enums, test fixtures,
  template lookup) must read from this module instead of redefining the same
  tuple inline.
  """

  @feature_exploration %{
    run_kind: "feature_exploration",
    artifact_type: "task_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_minimal_feature_exploration",
    state_machine_id: "feature_exploration",
    initial_state: "collect_feature_scope"
  }

  @work_breakdown %{
    run_kind: "work_breakdown",
    artifact_type: "task_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_work_breakdown_authoring",
    state_machine_id: "work_breakdown_authoring",
    initial_state: "collect_parent_scope"
  }

  @code_factory %{
    run_kind: "code_factory",
    artifact_type: "workflow_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_code_factory_creation",
    state_machine_id: "code_factory_creation",
    initial_state: "collect_workflow_goal"
  }

  @investigation_session %{
    run_kind: "investigation_session",
    artifact_type: "investigation_draft",
    template_kind: "starter_draft",
    state_machine_entrypoint: "start_investigation_session_authoring",
    state_machine_id: "investigation_session_authoring",
    initial_state: "collect_investigation_scope"
  }

  @all [@feature_exploration, @work_breakdown, @code_factory, @investigation_session]

  @type descriptor :: %{
          run_kind: String.t(),
          artifact_type: String.t(),
          template_kind: String.t(),
          state_machine_entrypoint: String.t(),
          state_machine_id: String.t(),
          initial_state: String.t()
        }

  @spec all() :: [descriptor()]
  def all, do: @all

  @spec feature_exploration() :: descriptor()
  def feature_exploration, do: @feature_exploration

  @spec work_breakdown() :: descriptor()
  def work_breakdown, do: @work_breakdown

  @spec code_factory() :: descriptor()
  def code_factory, do: @code_factory

  @spec investigation_session() :: descriptor()
  def investigation_session, do: @investigation_session

  @spec run_kinds() :: [String.t()]
  def run_kinds, do: Enum.map(@all, & &1.run_kind)

  @spec artifact_types() :: [String.t()]
  def artifact_types, do: Enum.uniq(Enum.map(@all, & &1.artifact_type))

  @spec template_kinds() :: [String.t()]
  def template_kinds, do: Enum.uniq(Enum.map(@all, & &1.template_kind))

  @spec state_machine_entrypoints() :: [String.t()]
  def state_machine_entrypoints, do: Enum.map(@all, & &1.state_machine_entrypoint)

  @spec state_machine_ids() :: [String.t()]
  def state_machine_ids, do: Enum.map(@all, & &1.state_machine_id)

  @spec initial_states() :: [String.t()]
  def initial_states, do: Enum.uniq(Enum.map(@all, & &1.initial_state))

  @spec fetch(term()) :: {:ok, descriptor()} | {:error, :not_found}
  def fetch(run_kind) when is_binary(run_kind) do
    case Enum.find(@all, &(&1.run_kind == run_kind)) do
      nil -> {:error, :not_found}
      descriptor -> {:ok, descriptor}
    end
  end

  def fetch(_), do: {:error, :not_found}

  @spec known_run_kind?(String.t()) :: boolean()
  def known_run_kind?(run_kind) when is_binary(run_kind),
    do: Enum.any?(@all, &(&1.run_kind == run_kind))

  def known_run_kind?(_), do: false
end
