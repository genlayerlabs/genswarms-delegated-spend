defmodule DelegatedSpend.PermitLaneTest do
  use ExUnit.Case, async: true
  alias DelegatedSpend.Evm.Abi
  alias DelegatedSpend.Keeper.PermitLane

  @config %{
    with_permit_name: "payWithPermit",
    arg_types: [{:bytes, 32}, {:uint, 256}, {:bytes, 32}]
  }
  @permit %{
    owner: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    deadline: 1_800_000_000,
    v: 27,
    r: <<1::256>>,
    s: <<2::256>>
  }

  test "selector matches the canonical payWithPermit signature" do
    call = PermitLane.build_call(@config, [<<7::256>>, 25_000_000, <<9::256>>], @permit)

    expected_sel =
      Abi.encode_call(
        "payWithPermit",
        [
          {:bytes, 32},
          {:uint, 256},
          {:bytes, 32},
          :address,
          {:uint, 256},
          {:uint, 8},
          {:bytes, 32},
          {:bytes, 32}
        ],
        [<<7::256>>, 25_000_000, <<9::256>>, <<0::160>>, 0, 0, <<0::256>>, <<0::256>>]
      )
      |> binary_part(0, 4)

    assert binary_part(call, 0, 4) == expected_sel
  end

  test "args decode back in order: action args then permit tail" do
    call = PermitLane.build_call(@config, [<<7::256>>, 25_000_000, <<9::256>>], @permit)
    <<_sel::binary-size(4), body::binary>> = call

    [topic, amount, order, owner, deadline, v, r, s] =
      Abi.decode_result(
        [
          {:bytes, 32},
          {:uint, 256},
          {:bytes, 32},
          :address,
          {:uint, 256},
          {:uint, 8},
          {:bytes, 32},
          {:bytes, 32}
        ],
        body
      )

    assert {topic, amount, order} == {<<7::256>>, 25_000_000, <<9::256>>}
    assert Base.encode16(owner, case: :lower) == "f39fd6e51aad88f6f4ce6ab8827279cfffb92266"
    assert {deadline, v} == {1_800_000_000, 27}
    assert {r, s} == {<<1::256>>, <<2::256>>}
  end

  test "arg count mismatch raises (order and config must agree)" do
    assert_raise FunctionClauseError, fn ->
      PermitLane.build_call(@config, [<<7::256>>], @permit)
    end
  end
end
