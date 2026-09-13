defmodule Sacrum.Realtime.AccountChannelCdcContractTest do
  use ExUnit.Case, async: true

  alias Sacrum.Realtime.AccountChannelCdcContract

  test "defines complete sanitized daemon row projections" do
    assert AccountChannelCdcContract.topic("user-id") == "account:user-id"

    assert AccountChannelCdcContract.event_names() == [
             "daemon_created",
             "daemon_updated",
             "daemon_deleted"
           ]

    for contract <- AccountChannelCdcContract.contracts() do
      assert contract.schema_version == 1
      assert contract.classification == :entity_projection
      assert contract.payload_keys == AccountChannelCdcContract.payload_keys()
      assert String.downcase(contract.completeness) =~ "sanitized"
      assert Enum.all?(contract.source_changes, &(&1.table == "daemons"))
    end

    refute :token_hash in AccountChannelCdcContract.payload_keys()
    refute :credential in AccountChannelCdcContract.payload_keys()
    refute :token in AccountChannelCdcContract.payload_keys()
  end

  test "uses the update event for row changes and delete event for hard deletes" do
    assert {:ok, contract} = AccountChannelCdcContract.contract_for("daemon_updated")
    assert contract.completeness =~ "replacement"
    assert AccountChannelCdcContract.event?("daemon_updated")
    refute AccountChannelCdcContract.event?("daemon_revoked")
    refute AccountChannelCdcContract.event?("daemon_removed")
  end
end
