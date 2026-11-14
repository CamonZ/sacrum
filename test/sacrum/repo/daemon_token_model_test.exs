defmodule Sacrum.Repo.DaemonTokenModelTest do
  @moduledoc """
  Model-based property test for daemon registration, access and refresh tokens.

  Random command sequences run against the real `Sacrum.Repo.Daemons` and a
  pure model. After every command the real result must equal the model's, the
  persisted credential rows must equal the model's token state, and the
  security invariants must hold. `token_ref` indexes every token issued so far,
  so stale, expired and wrong-kind tokens are replayed constantly.
  """

  use Sacrum.DataCase, async: false
  use ExUnitProperties

  alias Sacrum.Repo.{Daemons, Users}
  alias Sacrum.Repo.Schemas.DaemonCredential

  @access_ttl 3_600
  @refresh_ttl 2_592_000
  @bootstrap_ttl 86_400
  @argon2_modules [Argon2, Argon2.Base]

  # -- command generation ------------------------------------------------------

  defp command do
    frequency([
      {2, constant(:create_daemon)},
      {1, tuple({constant(:rotate), nat()})},
      {1, tuple({constant(:delete), nat()})},
      {4, tuple({constant(:exchange), nat()})},
      {6, tuple({constant(:request), nat(), nat()})},
      {6, tuple({constant(:refresh), nat()})},
      {2,
       tuple(
         {constant(:advance_clock), member_of([1, 59, 3_599, 3_600, 3_601, 86_400, 2_592_000])}
       )}
    ])
  end

  # Refs count back from the newest token/daemon, so small values replay recent
  # credentials (the interesting rotation cases) while large ones reach stale ones.
  defp nat, do: frequency([{3, integer(0..3)}, {1, integer(0..50)}])

  property "real daemon tokens always match the model and keep their invariants" do
    check all(
            commands <- list_of(command(), min_length: 6, max_length: 40),
            max_runs: 300,
            initial_size: 100
          ) do
      {:ok, owner} =
        Users.insert(%{
          email: "model-#{System.unique_integer([:positive])}@example.com",
          username: "model#{System.unique_integer([:positive])}",
          password: "password123"
        })

      model = %{owner: owner, clock: DateTime.utc_now(), daemons: [], tokens: []}

      Enum.reduce(commands, model, fn command, model ->
        model = step(command, model)
        assert_invariants(model)
        model
      end)
    end
  end

  # -- commands: each runs the real call, checks it against the model ----------

  defp step(:create_daemon, model) do
    {:ok, daemon, token, _credential} =
      Daemons.create_bootstrap(model.owner.id, %{}, now: model.clock)

    ref = length(model.daemons)

    model
    |> Map.update!(:daemons, &(&1 ++ [%{struct: daemon, live?: true}]))
    |> add_token(:bootstrap, token, ref, @bootstrap_ttl, nil, nil)
  end

  defp step({:rotate, idx}, model) do
    with_daemon(model, idx, fn ref, daemon ->
      result = Daemons.rotate_bootstrap(daemon.struct, now: model.clock)

      if daemon.live? do
        assert {:ok, %{token: token}} = result
        model = revoke_where(model, &(&1.daemon == ref))
        add_token(model, :bootstrap, token, ref, @bootstrap_ttl, nil, nil)
      else
        assert {:error, :invalid_credentials} = result
        model
      end
    end)
  end

  defp step({:delete, idx}, model) do
    with_daemon(model, idx, fn ref, daemon ->
      result = Daemons.unregister(daemon.struct)

      if daemon.live? do
        assert {:ok, _} = result
        put_in_daemon(model, ref, live?: false)
      else
        assert {:error, :not_found} = result
        model
      end
    end)
  end

  defp step({:exchange, idx}, model) do
    with_token(model, idx, fn tok ->
      result =
        Daemons.exchange_bootstrap(daemon_id(model, tok.daemon), tok.value, now: model.clock)

      if tok.kind == :bootstrap and valid?(model, tok) do
        assert {:ok, _daemon, pair} = result
        model = update_token(model, tok.id, &%{&1 | consumed: true})
        issue_pair(model, tok.daemon, pair, nil)
      else
        assert {:error, :invalid_credentials} = result
        model
      end
    end)
  end

  defp step({:request, tidx, didx}, model) do
    with_token(model, tidx, fn tok ->
      with_daemon(model, didx, fn dref, daemon ->
        {result, queries, argon2_calls} =
          observed(fn ->
            Daemons.authenticate_access(daemon.struct.id, tok.value, now: model.clock)
          end)

        if tok.kind == :access and tok.daemon == dref and valid?(model, tok) do
          assert {:ok, %{daemon: %{id: id}}} = result
          assert id == daemon.struct.id
          retire = stale_predecessor(model, tok)
          assert_one_select(queries, retire)
          assert argon2_calls == []
          if retire, do: update_token(model, retire.id, &%{&1 | revoked: true}), else: model
        else
          assert {:error, :invalid_credentials} = result
          assert argon2_calls == []
          model
        end
      end)
    end)
  end

  defp step({:refresh, idx}, model) do
    with_token(model, idx, fn tok ->
      result = Daemons.refresh(daemon_id(model, tok.daemon), tok.value, now: model.clock)

      if tok.kind == :refresh and valid?(model, tok) do
        assert {:ok, _daemon, pair} = result

        model
        |> revoke_where(fn t ->
          t.daemon == tok.daemon and
            (t.kind == :access or (t.kind == :refresh and t.pred == tok.id) or t.id == tok.pred)
        end)
        |> issue_pair(tok.daemon, pair, tok.id)
      else
        assert {:error, :invalid_credentials} = result
        model
      end
    end)
  end

  defp step({:advance_clock, seconds}, model),
    do: %{model | clock: DateTime.add(model.clock, seconds)}

  # -- model ------------------------------------------------------------------

  defp valid?(model, tok) do
    daemon = Enum.at(model.daemons, tok.daemon)

    daemon.live? and not tok.revoked and not tok.consumed and
      DateTime.compare(tok.expires, model.clock) == :gt
  end

  # The pair's refresh token retires its still-active predecessor on first use.
  defp stale_predecessor(model, %{kind: :access, pair: pair_id}) do
    refresh = Enum.find(model.tokens, &(&1.id == pair_id))
    refresh.pred && Enum.find(model.tokens, &(&1.id == refresh.pred and not &1.revoked))
  end

  defp issue_pair(model, ref, pair, predecessor_id) do
    refresh_id = length(model.tokens)

    model
    |> add_token(:refresh, pair.refresh_token, ref, @refresh_ttl, predecessor_id, nil)
    |> add_token(:access, pair.access_token, ref, @access_ttl, nil, refresh_id)
  end

  defp add_token(model, kind, value, daemon, ttl, pred, pair) do
    token = %{
      id: length(model.tokens),
      kind: kind,
      value: value,
      daemon: daemon,
      expires: DateTime.add(model.clock, ttl),
      revoked: false,
      consumed: false,
      pred: pred,
      pair: pair
    }

    %{model | tokens: model.tokens ++ [token]}
  end

  defp revoke_where(model, fun) do
    %{model | tokens: Enum.map(model.tokens, &if(fun.(&1), do: %{&1 | revoked: true}, else: &1))}
  end

  defp update_token(model, id, fun) do
    %{model | tokens: Enum.map(model.tokens, &if(&1.id == id, do: fun.(&1), else: &1))}
  end

  defp put_in_daemon(model, ref, live?: live?) do
    %{
      model
      | daemons: List.update_at(model.daemons, ref, &%{&1 | live?: live?})
    }
  end

  defp with_daemon(%{daemons: []} = model, _idx, _fun), do: model

  defp with_daemon(model, idx, fun) do
    ref = length(model.daemons) - 1 - rem(idx, length(model.daemons))
    fun.(ref, Enum.at(model.daemons, ref))
  end

  defp with_token(%{tokens: []} = model, _idx, _fun), do: model

  defp with_token(model, idx, fun),
    do: fun.(Enum.at(model.tokens, length(model.tokens) - 1 - rem(idx, length(model.tokens))))

  defp daemon_id(model, ref), do: Enum.at(model.daemons, ref).struct.id

  # -- invariants checked against persisted rows after every command ------------

  defp assert_invariants(model) do
    for {daemon, ref} <- Enum.with_index(model.daemons) do
      rows = Repo.all(from c in DaemonCredential, where: c.daemon_id == ^daemon.struct.id)

      if daemon.live? do
        assert_rows_match_model(model, ref, rows)
        assert_refresh_invariants(model, rows)
      else
        # A deleted daemon has no credential of any kind.
        assert rows == []
      end
    end
  end

  defp assert_rows_match_model(model, ref, rows) do
    for tok <- Enum.filter(model.tokens, &(&1.daemon == ref)) do
      row = Enum.find(rows, &(&1.token_hash == DaemonCredential.hash_token(tok.value)))
      assert row, "model token #{tok.id} (#{tok.kind}) missing from the database"
      assert row.credential_kind == to_string(tok.kind)
      assert row.status == if(tok.revoked, do: "revoked", else: "active")
      assert not is_nil(row.consumed_at) == tok.consumed
      assert row.expires_at == tok.expires
    end

    assert length(rows) == Enum.count(model.tokens, &(&1.daemon == ref))
  end

  # A daemon has at most one valid refresh token; the sole exception is the
  # not-yet-retired predecessor kept for lost-response recovery.
  defp assert_refresh_invariants(model, rows) do
    valid =
      Enum.filter(rows, fn row ->
        row.credential_kind == "refresh" and
          DaemonCredential.valid_for_authentication?(row, model.clock)
      end)

    case valid do
      [] -> :ok
      [_] -> :ok
      [a, b] -> assert a.predecessor_id == b.id or b.predecessor_id == a.id
      more -> flunk("#{length(more)} simultaneously valid refresh tokens")
    end

    # A registration token never coexists with a live session credential after
    # being consumed, and at most one is exchangeable.
    live_bootstrap =
      Enum.count(
        rows,
        &(&1.credential_kind == "bootstrap" and DaemonCredential.consumable?(&1, model.clock))
      )

    assert live_bootstrap <= 1
  end

  # -- performance: a successful request is one indexed SELECT -------------------

  defp assert_one_select(queries, retire) do
    {selects, others} = Enum.split_with(queries, &String.starts_with?(&1, "SELECT"))
    assert length(selects) == 1, "expected exactly one SELECT, got: #{inspect(queries)}"
    refute Enum.any?(queries, &(&1 =~ ~r/FOR UPDATE/i)), "row lock: #{inspect(queries)}"

    refute Enum.any?(queries, &(&1 =~ ~r/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)),
           "transaction: #{inspect(queries)}"

    # The only permitted write is the one-time retirement of a predecessor refresh token.
    if retire do
      assert [update] = others
      assert update =~ ~r/\AUPDATE "daemon_credentials"/
    else
      assert others == []
    end
  end

  defp observed(fun) do
    test_pid = self()
    handler = "daemon-token-model-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:sacrum, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == test_pid, do: send(test_pid, {:repo_query, query})
      end,
      nil
    )

    trace_argon2(true)

    try do
      result = fun.()
      {result, drain(:repo_query), drain(:trace)}
    after
      trace_argon2(false)
      :telemetry.detach(handler)
    end
  end

  defp trace_argon2(on?) do
    :erlang.trace(self(), on?, [:call])

    for module <- @argon2_modules do
      Code.ensure_loaded(module)
      :erlang.trace_pattern({module, :_, :_}, on?, [:local])
    end
  end

  defp drain(:repo_query) do
    receive do
      {:repo_query, query} -> [query | drain(:repo_query)]
    after
      0 -> []
    end
  end

  defp drain(:trace) do
    receive do
      {:trace, _pid, :call, mfa} -> [mfa | drain(:trace)]
    after
      0 -> []
    end
  end
end
