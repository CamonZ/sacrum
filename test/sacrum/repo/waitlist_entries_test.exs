defmodule Sacrum.Repo.WaitlistEntriesTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.WaitlistEntries
  alias Sacrum.Repo.Schemas.WaitlistEntry

  describe "create/1" do
    test "creates a waitlist entry with valid email" do
      attrs = %{email: "test@example.com"}

      assert {:ok, %WaitlistEntry{} = entry} = WaitlistEntries.create(attrs)
      assert entry.email == "test@example.com"
      assert entry.id != nil
      assert entry.inserted_at != nil
      assert not Map.has_key?(entry, :updated_at)
    end

    test "returns error with invalid email format" do
      attrs = %{email: "not-an-email"}

      assert {:error, changeset} = WaitlistEntries.create(attrs)
      assert %{email: ["must be a valid email"]} = errors_on(changeset)
    end

    test "returns error with blank email" do
      attrs = %{email: ""}

      assert {:error, changeset} = WaitlistEntries.create(attrs)
      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error with duplicate email (case-insensitive)" do
      attrs1 = %{email: "test@example.com"}
      attrs2 = %{email: "TEST@EXAMPLE.COM"}

      assert {:ok, _entry} = WaitlistEntries.create(attrs1)
      assert {:error, changeset} = WaitlistEntries.create(attrs2)
      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end

    test "accepts email with special characters" do
      attrs = %{email: "test+tag@example.co.uk"}

      assert {:ok, %WaitlistEntry{}} = WaitlistEntries.create(attrs)
    end
  end

  describe "get/1" do
    test "returns entry when found" do
      {:ok, entry} = WaitlistEntries.create(%{email: "test@example.com"})

      assert {:ok, found} = WaitlistEntries.get(entry.id)
      assert found.id == entry.id
      assert found.email == "test@example.com"
    end

    test "returns error when not found" do
      assert {:error, :not_found} = WaitlistEntries.get(Ecto.UUID.generate())
    end
  end

  describe "all/0" do
    test "returns empty list when no entries" do
      assert [] = WaitlistEntries.all()
    end

    test "returns all entries" do
      {:ok, entry1} = WaitlistEntries.create(%{email: "first@example.com"})
      {:ok, entry2} = WaitlistEntries.create(%{email: "second@example.com"})

      entries = WaitlistEntries.all()
      assert length(entries) >= 2

      ids = Enum.map(entries, & &1.id)
      assert entry1.id in ids
      assert entry2.id in ids
    end
  end

  describe "delete/1" do
    test "deletes entry" do
      {:ok, entry} = WaitlistEntries.create(%{email: "test@example.com"})

      assert {:ok, _} = WaitlistEntries.delete(entry)
      assert {:error, :not_found} = WaitlistEntries.get(entry.id)
    end
  end
end
