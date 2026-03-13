defmodule Sacrum.DaemonRegistryTest do
  use Sacrum.DataCase

  alias Sacrum.DaemonRegistry
  alias Ecto.UUID

  describe "register_daemon/1" do
    test "registers a daemon for a project and returns count 1" do
      project_id = UUID.generate()
      count = DaemonRegistry.register_daemon(project_id)
      assert count == 1
    end

    test "increments daemon count for the same project" do
      project_id = UUID.generate()
      count1 = DaemonRegistry.register_daemon(project_id)
      assert count1 == 1

      count2 = DaemonRegistry.register_daemon(project_id)
      assert count2 == 2

      count3 = DaemonRegistry.register_daemon(project_id)
      assert count3 == 3
    end

    test "registers daemons for different projects independently" do
      project_id1 = UUID.generate()
      project_id2 = UUID.generate()

      count1_1 = DaemonRegistry.register_daemon(project_id1)
      assert count1_1 == 1

      count2_1 = DaemonRegistry.register_daemon(project_id2)
      assert count2_1 == 1

      count1_2 = DaemonRegistry.register_daemon(project_id1)
      assert count1_2 == 2

      count2_2 = DaemonRegistry.register_daemon(project_id2)
      assert count2_2 == 2
    end
  end

  describe "unregister_daemon/1" do
    test "unregisters a daemon and returns count 0 when last one leaves" do
      project_id = UUID.generate()
      DaemonRegistry.register_daemon(project_id)

      count = DaemonRegistry.unregister_daemon(project_id)
      assert count == 0
    end

    test "decrements daemon count for multiple daemons" do
      project_id = UUID.generate()
      DaemonRegistry.register_daemon(project_id)
      DaemonRegistry.register_daemon(project_id)
      assert DaemonRegistry.daemon_count(project_id) == 2

      count1 = DaemonRegistry.unregister_daemon(project_id)
      assert count1 == 1

      count2 = DaemonRegistry.unregister_daemon(project_id)
      assert count2 == 0
    end

    test "unregistering from a project with no daemons returns 0" do
      project_id = UUID.generate()
      count = DaemonRegistry.unregister_daemon(project_id)
      assert count == 0
    end
  end

  describe "daemon_connected?/1" do
    test "returns true when daemon is registered" do
      project_id = UUID.generate()
      DaemonRegistry.register_daemon(project_id)

      assert DaemonRegistry.daemon_connected?(project_id) == true
    end

    test "returns false when no daemon is registered" do
      project_id = UUID.generate()
      assert DaemonRegistry.daemon_connected?(project_id) == false
    end

    test "returns false when all daemons unregister" do
      project_id = UUID.generate()
      DaemonRegistry.register_daemon(project_id)
      DaemonRegistry.unregister_daemon(project_id)

      assert DaemonRegistry.daemon_connected?(project_id) == false
    end

    test "returns true when multiple daemons are registered" do
      project_id = UUID.generate()
      DaemonRegistry.register_daemon(project_id)
      DaemonRegistry.register_daemon(project_id)

      assert DaemonRegistry.daemon_connected?(project_id) == true
    end
  end

  describe "daemon_count/1" do
    test "returns 0 for unregistered project" do
      project_id = UUID.generate()
      assert DaemonRegistry.daemon_count(project_id) == 0
    end

    test "returns correct count for registered project" do
      project_id = UUID.generate()
      DaemonRegistry.register_daemon(project_id)
      DaemonRegistry.register_daemon(project_id)
      DaemonRegistry.register_daemon(project_id)

      assert DaemonRegistry.daemon_count(project_id) == 3
    end

    test "returns correct count after unregistering" do
      project_id = UUID.generate()
      DaemonRegistry.register_daemon(project_id)
      DaemonRegistry.register_daemon(project_id)
      DaemonRegistry.unregister_daemon(project_id)

      assert DaemonRegistry.daemon_count(project_id) == 1
    end
  end

  describe "multiple projects" do
    test "daemon join and leave per project are tracked correctly" do
      project1 = UUID.generate()
      project2 = UUID.generate()

      # Register daemons for both projects
      assert DaemonRegistry.register_daemon(project1) == 1
      assert DaemonRegistry.register_daemon(project2) == 1

      # Both should have a daemon
      assert DaemonRegistry.daemon_connected?(project1) == true
      assert DaemonRegistry.daemon_connected?(project2) == true

      # Unregister daemon for project1
      assert DaemonRegistry.unregister_daemon(project1) == 0

      # Only project2 should have a daemon
      assert DaemonRegistry.daemon_connected?(project1) == false
      assert DaemonRegistry.daemon_connected?(project2) == true

      # Unregister daemon for project2
      assert DaemonRegistry.unregister_daemon(project2) == 0

      # Neither should have a daemon
      assert DaemonRegistry.daemon_connected?(project1) == false
      assert DaemonRegistry.daemon_connected?(project2) == false
    end
  end
end
