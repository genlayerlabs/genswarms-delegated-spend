defmodule DelegatedSpend.IntakeTest do
  use ExUnit.Case
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Intake
  alias DelegatedSpend.Intake.Rate
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.{MemoryStore, Signer}

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @bot_token "1234567:TEST-fake-bot-token-for-vectors"
  @router "0x0000000000000000000000000000000000000BbB"
  @token "0x0000000000000000000000000000000000000AaA"
  @user_id 777_000_111

  defp init_data(user_id \\ @user_id, token \\ @bot_token) do
    fields = %{
      "auth_date" => Integer.to_string(System.os_time(:second)),
      "query_id" => "AAF03",
      "user" => ~s({"id":#{user_id},"first_name":"A"})
    }

    dcs =
      fields
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)

    secret = :crypto.mac(:hmac, :sha256, "WebAppData", token)
    hash = :crypto.mac(:hmac, :sha256, secret, dcs) |> Base.encode16(case: :lower)
    URI.encode_query(Map.put(fields, "hash", hash))
  end

  defp permit_env(value) do
    %{
      "v" => "0.1.0",
      "chain_id" => 84_532,
      "token" => @token,
      "spender" => @router,
      "owner" => "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
      "value" => value,
      "deadline" => 4_000_000_000,
      "sig" => %{
        "v" => 27,
        "r" => "0x" <> String.duplicate("11", 32),
        "s" => "0x" <> String.duplicate("22", 32)
      }
    }
  end

  defp start_stack(rate_max \\ 100, order_ttl_s \\ 600) do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @anvil0,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()

    {:ok, keeper} =
      Keeper.start_link(
        signer: signer,
        store: {MemoryStore, store},
        router: @router,
        action: %{
          with_permit_name: "payWithPermit",
          arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]
        },
        source_allowlist: ["market_phase"],
        order_ttl_s: order_ttl_s,
        sweep_ms: 3_600_000
      )

    ctx = %{
      bot_token: @bot_token,
      max_age_s: 900,
      user_ref_fn: fn user_id -> "ref-" <> Integer.to_string(user_id) end,
      keeper: keeper,
      pinned: %{chain_id: 84_532, token: @token, router: @router, version: "0.1.0"},
      rate: {Rate.start(60), rate_max}
    }

    %{fake: fake, store: store, keeper: keeper, ctx: ctx}
  end

  defp register(keeper, user_id) do
    {:ok, %{order_ref: ref}} =
      Keeper.register_order(keeper, "market_phase", %{
        user_ref: "ref-" <> Integer.to_string(user_id),
        amount: 25_000_000,
        action_args: [<<7::256>>, 25_000_000, <<9::256>>]
      })

    ref
  end

  test "unauthenticated requests are rejected before ANY work" do
    %{ctx: ctx, store: store, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)

    for bad <- [nil, "", "garbage", init_data(@user_id, "999:WRONG")] do
      assert {401, %{"error" => "unauthorized"}} =
               Intake.handle_order(%{"init_data" => bad, "order_ref" => ref}, ctx)

      assert {401, _} =
               Intake.handle_grant(
                 %{"init_data" => bad, "order_ref" => ref, "permit" => permit_env(25_000_000)},
                 ctx
               )
    end

    # nothing consumed, nothing inflight — zero work happened
    assert MemoryStore.list_inflight(store) == []
    assert {:ok, _} = Keeper.fetch_order(keeper, ref, "ref-#{@user_id}")
  end

  test "order fetch: verified user sees own order; another VERIFIED user gets 404" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)

    assert {200, body} = Intake.handle_order(%{"init_data" => init_data(), "order_ref" => ref}, ctx)
    assert body["amount"] == 25_000_000
    assert body["order_ref"] == ref

    other = init_data(666_000_000)
    assert {404, _} = Intake.handle_order(%{"init_data" => other, "order_ref" => ref}, ctx)
  end

  test "client-supplied user_ref is IGNORED — identity comes from initData only" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)
    other = init_data(666_000_000)

    params = %{
      "init_data" => other,
      "order_ref" => ref,
      # attacker claims the victim's ref in the payload
      "user_ref" => "ref-#{@user_id}"
    }

    assert {404, _} = Intake.handle_order(params, ctx)
  end

  test "grant: pinned mismatches reject typed; version mismatch is 409" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)
    base = %{"init_data" => init_data(), "order_ref" => ref}

    assert {409, _} =
             Intake.handle_grant(
               Map.put(base, "permit", %{permit_env(25_000_000) | "v" => "0.0.9"}),
               ctx
             )

    assert {422, %{"field" => "spender"}} =
             Intake.handle_grant(
               Map.put(base, "permit", %{
                 permit_env(25_000_000)
                 | "spender" => "0x0000000000000000000000000000000000000ccc"
               }),
               ctx
             )
  end

  test "grant happy path: strict validation → keeper → submitted" do
    %{ctx: ctx, keeper: keeper} = start_stack()
    ref = register(keeper, @user_id)

    assert {200, %{"status" => "submitted", "tx" => "0x" <> _}} =
             Intake.handle_grant(
               %{"init_data" => init_data(), "order_ref" => ref, "permit" => permit_env(25_000_000)},
               ctx
             )
  end

  test "grant for someone else's order: 404, nothing broadcast" do
    %{ctx: ctx, keeper: keeper, fake: fake} = start_stack()
    ref = register(keeper, @user_id)

    assert {404, _} =
             Intake.handle_grant(
               %{
                 "init_data" => init_data(666_000_000),
                 "order_ref" => ref,
                 "permit" => permit_env(25_000_000)
               },
               ctx
             )

    assert FakeRpc.sent(fake) == []
  end

  test "rate limiting is per verified user and only counts authenticated calls" do
    %{ctx: ctx, keeper: keeper} = start_stack(2)
    ref = register(keeper, @user_id)
    params = %{"init_data" => init_data(), "order_ref" => ref}

    assert {200, _} = Intake.handle_order(params, ctx)
    assert {200, _} = Intake.handle_order(params, ctx)
    assert {429, _} = Intake.handle_order(params, ctx)

    # a DIFFERENT verified user has their own bucket
    other = %{"init_data" => init_data(666_000_000), "order_ref" => ref}
    assert {404, _} = Intake.handle_order(other, ctx)
  end

  test "unauthenticated requests do NOT consume the rate bucket" do
    # max 1/window: three 401s must leave the single slot untouched for the
    # first AUTHENTICATED call — the limiter only counts verified callers.
    %{ctx: ctx, keeper: keeper} = start_stack(1)
    ref = register(keeper, @user_id)

    for _ <- 1..3 do
      assert {401, _} =
               Intake.handle_order(%{"init_data" => "garbage", "order_ref" => ref}, ctx)
    end

    assert {200, _} =
             Intake.handle_order(%{"init_data" => init_data(), "order_ref" => ref}, ctx)
  end

  test "handle_grant is rate limited too (429 after the bucket is consumed)" do
    %{ctx: ctx, keeper: keeper} = start_stack(1)
    ref = register(keeper, @user_id)
    params = %{"init_data" => init_data(), "order_ref" => ref, "permit" => permit_env(25_000_000)}

    assert {200, _} = Intake.handle_grant(params, ctx)
    assert {429, %{"error" => "rate limited"}} = Intake.handle_grant(params, ctx)
  end

  test "expired order surfaces as the typed 422 failure contract on handle_grant" do
    # order_ttl_s: 0 → the order expires immediately; the keeper's {:failed,
    # :expired} must map to the documented {422, status: failed, reason: expired}.
    %{ctx: ctx, keeper: keeper} = start_stack(100, 0)
    ref = register(keeper, @user_id)

    Process.sleep(1100)

    assert {422, %{"status" => "failed", "reason" => "expired"}} =
             Intake.handle_grant(
               %{"init_data" => init_data(), "order_ref" => ref, "permit" => permit_env(25_000_000)},
               ctx
             )
  end
end
