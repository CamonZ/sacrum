defmodule Sacrum.Accounts.AuthoringRunKindsTest do
  use ExUnit.Case, async: true

  alias Sacrum.Accounts.AuthoringRunKinds

  describe "all/0" do
    test "exposes the four authoring run-kind descriptors" do
      descriptors = AuthoringRunKinds.all()

      assert length(descriptors) == 4

      run_kinds = Enum.map(descriptors, & &1.run_kind)

      assert MapSet.new(run_kinds) ==
               MapSet.new([
                 "feature_exploration",
                 "work_breakdown",
                 "code_factory",
                 "investigation_session"
               ])
    end

    test "each descriptor carries the full tuple of authoring identifiers" do
      for descriptor <- AuthoringRunKinds.all() do
        assert is_binary(descriptor.run_kind) and descriptor.run_kind != ""
        assert is_binary(descriptor.artifact_type) and descriptor.artifact_type != ""
        assert is_binary(descriptor.template_kind) and descriptor.template_kind != ""

        assert is_binary(descriptor.state_machine_entrypoint) and
                 descriptor.state_machine_entrypoint != ""

        assert is_binary(descriptor.state_machine_id) and descriptor.state_machine_id != ""
        assert is_binary(descriptor.initial_state) and descriptor.initial_state != ""
      end
    end
  end

  describe "fetch/1 and lookup helpers" do
    test "fetch/1 returns the descriptor for a known run_kind" do
      assert {:ok,
              %{
                run_kind: "code_factory",
                artifact_type: "workflow_draft",
                template_kind: "starter_draft",
                state_machine_entrypoint: "start_code_factory_creation",
                state_machine_id: "code_factory_creation",
                initial_state: "collect_workflow_goal"
              }} = AuthoringRunKinds.fetch("code_factory")
    end

    test "fetch/1 returns :not_found for an unknown run_kind" do
      assert {:error, :not_found} = AuthoringRunKinds.fetch("nonsense")
    end

    test "fetch/1 returns :not_found instead of raising when called with non-binary input" do
      assert {:error, :not_found} = AuthoringRunKinds.fetch(nil)
      assert {:error, :not_found} = AuthoringRunKinds.fetch(0)
      assert {:error, :not_found} = AuthoringRunKinds.fetch(:code_factory)
    end

    test "known_run_kind?/1 returns true for valid kinds and false otherwise" do
      assert AuthoringRunKinds.known_run_kind?("feature_exploration")
      refute AuthoringRunKinds.known_run_kind?("nope")
      refute AuthoringRunKinds.known_run_kind?(nil)
    end

    test "state_machine_ids/0 returns the per-run-kind identifiers" do
      assert AuthoringRunKinds.state_machine_ids() == [
               "feature_exploration",
               "work_breakdown_authoring",
               "code_factory_creation",
               "investigation_session_authoring"
             ]
    end
  end

  describe "fixtures decoupling" do
    test "AuthoringFixtures no longer redefines run-kind descriptors as module attrs" do
      source = File.read!("test/support/authoring_fixtures.ex")

      refute source =~ ~s|@work_breakdown %{|
      refute source =~ ~s|@code_factory %{|
      refute source =~ ~s|@feature_exploration %{|
      refute source =~ ~s|@investigation_session %{|

      assert source =~ "AuthoringRunKinds.work_breakdown()"
      assert source =~ "AuthoringRunKinds.code_factory()"
      assert source =~ "AuthoringRunKinds.feature_exploration()"
      assert source =~ "AuthoringRunKinds.investigation_session()"
    end
  end
end
