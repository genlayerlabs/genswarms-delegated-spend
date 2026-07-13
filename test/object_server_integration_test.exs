defmodule DelegatedSpend.Keeper.ObjectServerIntegrationTest do
  use ExUnit.Case, async: false

  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Keeper.{MemoryStore, Signer}
  alias Genswarms.Objects.ObjectServer

  @private_key Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @order_ref String.duplicate("ab", 32)

  setup do
    {:ok, _} = Application.ensure_all_started(:genswarms)
    swarm = "delegated-spend-door-#{System.unique_integer([:positive])}"
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(
        rpc_url: fake,
        chain_id: 84_532,
        priv: @private_key,
        rpc_mod: FakeRpc,
        sweep_ms: 3_600_000
      )

    store = MemoryStore.start()

    keeper_opts = %{
      signer: signer,
      store: {MemoryStore, store},
      router: "0x00000000000000000000000000000000000000e1",
      action: %{
        with_permit_name: "payWithPermit",
        arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]
      },
      source_allowlist: ["market_phase"],
      order_ttl_s: 600,
      rpc_mod: FakeRpc,
      rpc: fake,
      sweep_ms: 3_600_000
    }

    {:ok, server} =
      ObjectServer.start_link(
        name: :spend_keeper,
        swarm_name: swarm,
        handler: DelegatedSpend.Keeper.Object,
        config: %{keeper_opts: keeper_opts}
      )

    Process.unlink(server)

    on_exit(fn -> stop_server(server) end)

    assert_idle(swarm)
    %{swarm: swarm, store: store}
  end

  test "the real ObjectServer dispatches a trusted order into the keeper core", %{
    swarm: swarm,
    store: store
  } do
    assert %{register_order: _, order_status: _, reset_backoff: _} =
             ObjectServer.get_interface(swarm, :spend_keeper)

    ObjectServer.deliver_message(swarm, :spend_keeper, :market_phase, register_order())

    assert_eventually(fn ->
      case MemoryStore.get_order_by_ref(store, @order_ref, "user-a") do
        %{action_args: [first, 25_000_000, last]} ->
          byte_size(first) == 32 and byte_size(last) == 32

        _ ->
          false
      end
    end)
  end

  test "the ObjectServer preserves stamped source authority and survives malformed input", %{
    swarm: swarm,
    store: store
  } do
    ObjectServer.deliver_message(swarm, :spend_keeper, :untrusted_object, register_order())
    assert ObjectServer.get_state(swarm, :spend_keeper) == :idle
    assert MemoryStore.get_order_by_ref(store, @order_ref, "user-a") == nil

    ObjectServer.deliver_message(swarm, :spend_keeper, :market_phase, "not json {{{")
    assert ObjectServer.get_state(swarm, :spend_keeper) == :idle

    ObjectServer.deliver_message(swarm, :spend_keeper, :market_phase, register_order())

    assert_eventually(fn -> is_map(MemoryStore.get_order_by_ref(store, @order_ref, "user-a")) end)
  end

  defp register_order do
    Jason.encode!(%{
      "action" => "register_order",
      "order" => %{
        "order_ref" => @order_ref,
        "user_ref" => "user-a",
        "amount" => 25_000_000,
        "action_args" => [
          "0x" <> String.duplicate("07", 32),
          25_000_000,
          "0x" <> String.duplicate("09", 32)
        ]
      }
    })
  end

  defp assert_idle(swarm) do
    assert_eventually(fn -> ObjectServer.get_state(swarm, :spend_keeper) == :idle end)
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      if attempts == 0 do
        flunk("condition did not become true")
      else
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp stop_server(server) do
    if Process.alive?(server), do: GenServer.stop(server)
  catch
    :exit, _ -> :ok
  end
end
