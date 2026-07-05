defmodule DelegatedSpend.Evm.Abi do
  @moduledoc """
  Port of a production-proven pure-Elixir EVM module; do not diverge.

  Thin wrapper over `ex_abi`. Function/return/constructor encoding for the chain
  layer, plus the `Transfer` event topic. Types are the `ex_abi` tuples
  (`{:uint,256}`, `{:array,{:uint,8}}`, `:address`, `:bytes`, `:string`).

  The selector is derived **from the signature ex_abi builds out of name+types**
  — never hand-typed — so a typo can't silently produce a wrong selector.
  """

  alias ABI.FunctionSelector

  @doc "Encode a function call: 4-byte selector ++ ABI-encoded args (raw bytes)."
  def encode_call(name, types, args) do
    # Selector via our pure Keccak (so ex_abi needs no keccak NIF); args via ex_abi's
    # type encoder with `function: nil` (no selector, no keccak). The canonical type
    # string comes from ex_abi's own `encode_type/1`, so the signature can't drift.
    selector = DelegatedSpend.Keccak.hash_256(signature(name, types)) |> binary_part(0, 4)
    selector <> ABI.TypeEncoder.encode(args, %FunctionSelector{function: nil, types: types})
  end

  defp signature(name, types),
    do: name <> "(" <> Enum.map_join(types, ",", &FunctionSelector.encode_type/1) <> ")"

  @doc "Decode a view-call return (no selector) into a list of values."
  def decode_result(types, data) when is_binary(data) do
    ABI.TypeDecoder.decode(data, %FunctionSelector{function: nil, types: types})
  end

  @doc "Encode constructor args (no selector) — appended to creation bytecode."
  def encode_constructor(types, args) do
    ABI.TypeEncoder.encode(args, %FunctionSelector{function: nil, types: types})
  end

  @doc "keccak256 of a canonical event signature, e.g. \"Transfer(address,address,uint256)\"."
  def event_topic0(signature) when is_binary(signature),
    do: DelegatedSpend.Keccak.hash_256(signature)
end
