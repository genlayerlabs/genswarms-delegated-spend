defmodule DelegatedSpend.IntakeComplianceTest do
  use ExUnit.Case

  alias DelegatedSpend.Compliance.MemoryStore, as: ComplianceStore
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Intake
  alias DelegatedSpend.Intake.{Rate, Token}
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.{MemoryStore, Signer}

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @router "0x0000000000000000000000000000000000000BbB"
  @token "0x0000000000000000000000000000000000000AaA"
  @user_ref "ref-777000111"
  @other_user_ref "ref-666000000"
  @terms_hash "0x" <> String.duplicate("11", 32)
  @old_terms_hash "0x" <> String.duplicate("22", 32)
  @terms %{hash: @terms_hash, url: "https://example.test/terms-v2"}
  @terms_required {428,
                   %{
                     "error" => "terms_required",
                     "terms" => %{
                       "v_hash" => @terms_hash,
                       "url" => "https://example.test/terms-v2"
                     }
                   }}

  defmodule MissingAcceptanceStore do
  end

  defmodule FailingAcceptanceStore do
    def get_acceptance(:raise, _user_ref, _v_hash), do: raise("store down")
    def get_acceptance(:exit, _user_ref, _v_hash), do: exit(:store_down)
    def get_acceptance(:throw, _user_ref, _v_hash), do: throw(:store_down)
  end

  setup do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    keeper_store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        chain_id: 84_532,
        store: {MemoryStore, keeper_store},
        router: @router,
        action: %{
          with_permit_name: "payWithPermit",
          arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]
        },
        source_allowlist: ["market_phase"],
        order_ttl_s: 600,
        sweep_ms: 3_600_000
      )

    test_pid = self()

    ctx = %{
      bot_token: "1234567:TEST-fake-bot-token-for-vectors",
      max_age_s: 900,
      user_ref_fn: fn user_id -> "ref-" <> Integer.to_string(user_id) end,
      keeper: keeper,
      pinned: %{chain_id: 84_532, token: @token, router: @router, version: "0.2.0"},
      rate: {Rate.start(60), 100},
      token_secret: "tsecret",
      wallet_fn: fn user_ref, address, bind_ref ->
        send(test_pid, {:bound, user_ref, address, bind_ref})
        :ok
      end
    }

    compliance_store = ComplianceStore.start()

    {:ok,
     ctx: with_terms(ctx, compliance_store),
     base_ctx: ctx,
     compliance_store: compliance_store,
     fake: fake,
     keeper: keeper,
     keeper_store: keeper_store}
  end

  test "compliance without terms preserves the exact order response", %{
    base_ctx: ctx,
    keeper: keeper
  } do
    ref = register_order(keeper)
    params = order_params(ctx, ref)

    assert response = {200, body} = Intake.handle_order(params, ctx)
    refute Map.has_key?(body, "terms")

    off_ctx = Map.put(ctx, :compliance, %{geo_allow: ["US"]})
    assert ^response = Intake.handle_order(params, %{country: "US"}, off_ctx)
  end

  test "order view reports current terms required before acceptance and satisfied after", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)
    params = order_params(ctx, ref)

    assert {200,
            %{
              "terms" => %{
                "required" => true,
                "v_hash" => @terms_hash,
                "url" => "https://example.test/terms-v2"
              }
            }} = Intake.handle_order(params, %{country: "US"}, ctx)

    :ok = ComplianceStore.record_acceptance(store, acceptance(@user_ref, @terms_hash))

    assert {200,
            %{
              "terms" => %{
                "required" => false,
                "v_hash" => @terms_hash,
                "url" => "https://example.test/terms-v2"
              }
            }} = Intake.handle_order(params, %{country: "US"}, ctx)

    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  test "old-hash and other-user acceptances do not satisfy the current user and hash", %{
    ctx: ctx,
    compliance_store: store
  } do
    :ok = ComplianceStore.record_acceptance(store, acceptance(@user_ref, @old_terms_hash))
    :ok = ComplianceStore.record_acceptance(store, acceptance(@other_user_ref, @terms_hash))

    ref = String.duplicate("ab", 32)
    params = %{"order_ref" => ref, "token" => token(ref), "permit" => %{}}

    assert @terms_required = Intake.handle_grant(params, %{country: "US"}, ctx)

    :ok = ComplianceStore.record_acceptance(store, acceptance(@user_ref, @terms_hash))

    assert {409, %{"error" => "version mismatch"}} =
             Intake.handle_grant(params, %{country: "US"}, ctx)
  end

  test "grant, wallet, and submitted gates run before validation and keeper work", %{
    ctx: ctx,
    compliance_store: store,
    fake: fake,
    keeper_store: keeper_store
  } do
    ref = String.duplicate("ab", 32)
    auth = token(ref)

    assert @terms_required =
             Intake.handle_grant(
               %{"order_ref" => ref, "token" => auth, "permit" => %{}},
               %{country: "US"},
               ctx
             )

    assert @terms_required =
             Intake.handle_wallet(
               %{"bind_ref" => ref, "token" => auth, "address" => "bad", "v" => "0.2.0"},
               %{country: "US"},
               Map.delete(ctx, :wallet_fn)
             )

    assert @terms_required =
             Intake.handle_submitted(
               %{"order_ref" => ref, "token" => auth, "tx_hash" => "bad", "v" => "0.2.0"},
               %{country: "US"},
               ctx
             )

    assert FakeRpc.sent(fake) == []
    assert MemoryStore.list_inflight(keeper_store) == []
    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  test "a 428 does not consume a bind ref and the same ref binds after acceptance", %{
    ctx: ctx,
    compliance_store: store,
    keeper: keeper
  } do
    ref = register_order(keeper)
    address = "0x8ba1f109551bd432803012645ac136ddd64dba72"

    params = %{
      "bind_ref" => ref,
      "token" => token(ref),
      "address" => address,
      "v" => "0.2.0"
    }

    assert @terms_required = Intake.handle_wallet(params, %{country: "US"}, ctx)
    refute_received {:bound, _, _, _}
    assert ComplianceStore.events_for(store, @user_ref) == []

    :ok =
      ComplianceStore.record_acceptance(
        store,
        acceptance(@user_ref, @terms_hash, "0x0000000000000000000000000000000000000001")
      )

    assert {200, %{"status" => "bound", "address" => bound}} =
             Intake.handle_wallet(params, %{country: "US"}, ctx)

    assert_received {:bound, @user_ref, ^bound, ^ref}
  end

  test "malformed terms and unreadable stores fail closed", %{base_ctx: ctx, keeper: keeper} do
    ref = register_order(keeper)
    params = order_params(ctx, ref)

    invalid_compliance = [
      %{geo_allow: ["US"], terms: nil},
      %{geo_allow: ["US"], terms: %{}},
      %{geo_allow: ["US"], terms: %{hash: @terms_hash}},
      %{geo_allow: ["US"], terms: %{hash: "0x1234", url: @terms.url}},
      %{geo_allow: ["US"], terms: %{hash: @terms_hash, url: ""}},
      %{geo_allow: ["US"], terms: @terms},
      %{geo_allow: ["US"], terms: @terms, store: :invalid},
      %{geo_allow: ["US"], terms: @terms, store: {"not-a-module", :ignored}},
      %{geo_allow: ["US"], terms: @terms, store: {MissingAcceptanceStore, :ignored}},
      %{geo_allow: ["US"], terms: @terms, store: {FailingAcceptanceStore, :raise}},
      %{geo_allow: ["US"], terms: @terms, store: {FailingAcceptanceStore, :exit}},
      %{geo_allow: ["US"], terms: @terms, store: {FailingAcceptanceStore, :throw}}
    ]

    for compliance <- invalid_compliance do
      assert {503, %{"error" => "unavailable"}} =
               Intake.handle_order(
                 params,
                 %{country: "US"},
                 Map.put(ctx, :compliance, compliance)
               )
    end
  end

  test "geofence remains first, two-arity stays fail-closed, and auth precedes the terms read", %{
    base_ctx: base_ctx
  } do
    ref = String.duplicate("ab", 32)
    params = %{"order_ref" => ref, "token" => token(ref), "v" => "0.2.0"}

    ctx =
      base_ctx
      |> Map.put(:rate, {Rate.start(60), 1})
      |> Map.put(:compliance, %{
        geo_allow: ["US"],
        terms: @terms,
        store: {FailingAcceptanceStore, :raise}
      })

    for handler <- [:handle_order, :handle_grant, :handle_wallet, :handle_submitted] do
      assert {451, %{"error" => "geo_blocked"}} =
               apply(Intake, handler, [%{}, %{country: "CA"}, ctx])

      assert {451, %{"error" => "geo_blocked"}} = apply(Intake, handler, [%{}, ctx])
    end

    assert {401, %{"error" => "unauthorized"}} =
             Intake.handle_order(
               %{"order_ref" => ref, "token" => "bad", "v" => "0.2.0"},
               %{country: "US"},
               ctx
             )

    assert {503, %{"error" => "unavailable"}} =
             Intake.handle_order(params, %{country: "US"}, ctx)
  end

  test "rate limiting remains before the terms gate", %{ctx: ctx, compliance_store: store} do
    ref = String.duplicate("ab", 32)
    params = %{"order_ref" => ref, "token" => token(ref), "permit" => %{}}
    ctx = Map.put(ctx, :rate, {Rate.start(60), 1})

    assert @terms_required = Intake.handle_grant(params, %{country: "US"}, ctx)

    assert {429, %{"error" => "rate limited"}} =
             Intake.handle_grant(params, %{country: "US"}, ctx)

    assert ComplianceStore.events_for(store, @user_ref) == []
  end

  defp with_terms(ctx, store) do
    Map.put(ctx, :compliance, %{
      geo_allow: ["US"],
      terms: @terms,
      store: {ComplianceStore, store}
    })
  end

  defp register_order(keeper) do
    {:ok, %{order_ref: ref}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: @user_ref,
        amount: 0,
        action_args: [],
        kind: "bind"
      })

    ref
  end

  defp order_params(ctx, ref),
    do: %{"order_ref" => ref, "token" => token(ref), "v" => ctx.pinned.version}

  defp token(ref),
    do: Token.mint("tsecret", ref, @user_ref, System.os_time(:second) + 600)

  defp acceptance(user_ref, v_hash, account \\ "0x0000000000000000000000000000000000000002") do
    %{
      user_ref: user_ref,
      v_hash: v_hash,
      account: account,
      sig: %{v: 27, r: "0x11", s: "0x22"},
      issued_at: 100,
      accepted_at: 101,
      meta: %{}
    }
  end
end
