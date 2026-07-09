defmodule DelegatedSpend.Keeper.ObjectTest do
  use ExUnit.Case
  alias DelegatedSpend.FakeRpc
  alias DelegatedSpend.Keeper
  alias DelegatedSpend.Keeper.{MemoryStore, Object, Signer}

  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")
  @router "0x00000000000000000000000000000000000000e1"
  @action %{with_permit_name: "payWithPermit", arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]}

  @ref String.duplicate("ab", 32)

  defp keeper_opts(fake, signer) do
    %{
      signer: signer,
      store: {MemoryStore, MemoryStore.start()},
      router: @router,
      action: @action,
      source_allowlist: ["market_phase"],
      order_ttl_s: 600,
      rpc_mod: FakeRpc,
      rpc: fake,
      sweep_ms: 3_600_000
    }
  end

  defp start_object(config_overrides \\ %{}) do
    fake = FakeRpc.start(%{chain_id: 84_532, nonce: 0, simulate: :ok})

    {:ok, signer} =
      Signer.start_link(rpc_url: fake, chain_id: 84_532, priv: @anvil0, rpc_mod: FakeRpc, sweep_ms: 3_600_000)

    opts = keeper_opts(fake, signer)
    {:ok, state} = Object.init(Map.merge(%{keeper_opts: opts}, config_overrides))
    %{state: state, opts: opts}
  end

  defp msg(state, from, payload) do
    {:reply, json, state} = Object.handle_message(from, payload, state)
    {Jason.decode!(json), state}
  end

  defp register_payload(overrides \\ %{}) do
    order =
      Map.merge(
        %{
          "order_ref" => @ref,
          "user_ref" => "u-a",
          "amount" => 25_000_000,
          "action_args" => ["0x" <> String.duplicate("07", 32), 25_000_000, "0x" <> String.duplicate("09", 32)]
        },
        overrides
      )

    Jason.encode!(%{"action" => "register_order", "order" => order})
  end

  test "init: keeper_opts starts an owned core and inherits its allowlist" do
    %{state: state} = start_object()
    assert is_pid(state.keeper) and Process.alive?(state.keeper)
    assert state.owned
    assert MapSet.member?(state.allow, "market_phase")
  end

  test "init: no keeper and no keeper_opts is refused" do
    assert {:error, :missing_keeper} = Object.init(%{})
  end

  test "init: attaching an external core without an explicit allowlist fails closed" do
    %{state: owned} = start_object()
    {:ok, state} = Object.init(%{keeper: owned.keeper})
    refute state.owned

    {reply, _} = msg(state, :market_phase, register_payload())
    assert %{"ok" => false, "error" => "unknown_source"} = reply
  end

  test "register via the door: framework-stamped from is the authority; caller-minted ref lands" do
    %{state: state} = start_object()

    {reply, _} = msg(state, :market_phase, register_payload())
    assert %{"ok" => true, "order_ref" => @ref} = reply
    assert is_binary(reply["order_id"])

    # the order is real: fetchable through the core with the caller-minted ref
    assert {:ok, %{amount: 25_000_000}} = Keeper.fetch_order(state.keeper, @ref, "u-a")
  end

  test "register via the door: 0x-hex args become raw binaries in the stored order" do
    %{state: state, opts: opts} = start_object()
    {%{"ok" => true}, _} = msg(state, :market_phase, register_payload())

    {MemoryStore, store} = opts.store
    order = MemoryStore.get_order_by_ref(store, @ref, "u-a")
    assert [<<7>> <> _ = a, 25_000_000, b] = order.action_args
    assert byte_size(a) == 32 and byte_size(b) == 32 and is_binary(b)
  end

  test "register via the door: transport order fields pass through" do
    %{state: state, opts: opts} = start_object()

    payload =
      register_payload(%{
        "amount" => 0,
        "action_args" => [],
        "kind" => "user_tx",
        "tx" => %{"to" => "0x" <> String.duplicate("11", 20), "data" => "0xdeadbeef", "value" => 0},
        "display" => %{"summary_lines" => ["Sell YES"]},
        "ttl_s" => 60
      })

    {%{"ok" => true}, _} = msg(state, :market_phase, payload)

    {MemoryStore, store} = opts.store
    order = MemoryStore.get_order_by_ref(store, @ref, "u-a")
    assert order.kind == "user_tx"
    assert order.tx.data == "0xdeadbeef"
    assert order.display["summary_lines"] == ["Sell YES"]
    assert is_nil(order.display[:summary_lines])
    assert_in_delta order.expires_at, System.os_time(:second) + 60, 5
  end

  test "register via the door: unlisted from is refused; payload-claimed source is inert" do
    %{state: state} = start_object()

    {reply, _} = msg(state, :evil_object, register_payload())
    assert %{"ok" => false, "error" => "unknown_source"} = reply
    assert {:error, :not_found} = Keeper.fetch_order(state.keeper, @ref, "u-a")

    # smuggling a source claim inside the payload changes nothing
    smuggled =
      Jason.encode!(%{
        "action" => "register_order",
        "source" => "market_phase",
        "order" => Jason.decode!(register_payload())["order"]
      })

    {reply2, _} = msg(state, :evil_object, smuggled)
    assert %{"ok" => false, "error" => "unknown_source"} = reply2
  end

  test "register via the door: order_ref is REQUIRED (no sync return channel to mint through)" do
    %{state: state} = start_object()

    payload =
      Jason.encode!(%{
        "action" => "register_order",
        "order" => Jason.decode!(register_payload())["order"] |> Map.delete("order_ref")
      })

    {reply, _} = msg(state, :market_phase, payload)
    assert %{"ok" => false, "error" => "bad_request"} = reply
  end

  test "register via the door: bad ref shapes and duplicates are typed refusals" do
    %{state: state} = start_object()

    for bad <- [String.upcase(@ref), "0x" <> @ref, String.slice(@ref, 0, 62), "zz" <> String.slice(@ref, 2, 62)] do
      {reply, _} = msg(state, :market_phase, register_payload(%{"order_ref" => bad}))
      assert %{"ok" => false, "error" => "bad_order_ref"} = reply, "accepted bad ref #{bad}"
    end

    {%{"ok" => true}, _} = msg(state, :market_phase, register_payload())
    {dup, _} = msg(state, :market_phase, register_payload())
    assert %{"ok" => false, "error" => "duplicate_order_ref"} = dup

    # the original order is intact (not shadowed by the duplicate attempt)
    assert {:ok, %{amount: 25_000_000}} = Keeper.fetch_order(state.keeper, @ref, "u-a")
  end

  test "register via the door: malformed args are refused, nothing stored" do
    %{state: state} = start_object()

    for {field, value} <- [
          {"action_args", ["not-hex", 1]},
          {"action_args", "not-a-list"},
          {"amount", "25"},
          {"amount", -5},
          {"expected_owner", 42}
        ] do
      {reply, _} = msg(state, :market_phase, register_payload(%{field => value}))
      assert %{"ok" => false, "error" => "bad_request"} = reply, "accepted bad #{field}"
    end

    assert {:error, :not_found} = Keeper.fetch_order(state.keeper, @ref, "u-a")
  end

  test "non-JSON and unknown actions get a typed error reply, never a crash; the door keeps working" do
    %{state: state} = start_object()

    {r1, state} = msg(state, :market_phase, "not json at all {{{")
    assert %{"ok" => false, "error" => "bad_request"} = r1

    {r2, state} = msg(state, :market_phase, Jason.encode!(%{"action" => "steal_funds"}))
    assert %{"ok" => false, "error" => "bad_request"} = r2

    {r3, _} = msg(state, :market_phase, register_payload())
    assert %{"ok" => true} = r3
  end

  test "order_status and reset_backoff round-trip through the door" do
    %{state: state} = start_object()

    {%{"ok" => true, "order_id" => order_id}, state} = msg(state, :market_phase, register_payload())

    {status, state} = msg(state, :market_phase, Jason.encode!(%{"action" => "order_status", "order_id" => order_id}))
    assert %{"ok" => true, "status" => "unknown"} = status

    {reset, _} = msg(state, :market_phase, Jason.encode!(%{"action" => "reset_backoff", "user_ref" => "u-a"}))
    assert %{"ok" => true} = reset
  end

  test "handle_info is a no-op; terminate stops an owned core only" do
    %{state: state} = start_object()
    assert {:noreply, ^state} = Object.handle_info(:tick, state)

    core = state.keeper
    assert :ok = Object.terminate(:shutdown, state)
    refute Process.alive?(core)

    # attached (not owned): terminate leaves the external core running
    %{state: other} = start_object()
    {:ok, attached} = Object.init(%{keeper: other.keeper, source_allowlist: ["market_phase"]})
    assert :ok = Object.terminate(:shutdown, attached)
    assert Process.alive?(other.keeper)
  end

  test "interface/0 describes the three door actions" do
    assert %{register_order: _, order_status: _, reset_backoff: _} = Object.interface()
  end
end
