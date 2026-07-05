defmodule DelegatedSpend.Keeper.BootCheck do
  @moduledoc """
  Boot verification (spec §5.1, do-not-weaken §10): before the keeper enables,
  the RPC must report the pinned chain id and every critical contract's
  runtime code must hash to its pinned keccak. Combined with the Signer's own
  chain-id pin this fails closed on wrong-network or wrong-contract wiring.
  (A fully hostile RPC can still fake observations — the recommended app
  policy is a second-RPC crosscheck for gate-authoritative reads; spec §5.1.)
  """

  alias DelegatedSpend.Keccak

  def verify(rpc_mod, rpc, %{chain_id: pinned, codehashes: pins}) do
    with :ok <- check_chain(rpc_mod, rpc, pinned) do
      Enum.reduce_while(pins, :ok, fn {addr, expected}, :ok ->
        case codehash(rpc_mod, rpc, addr) do
          ^expected -> {:cont, :ok}
          got -> {:halt, {:error, {:codehash_mismatch, addr, expected: expected, got: got}}}
        end
      end)
    end
  end

  defp check_chain(rpc_mod, rpc, pinned) do
    case rpc_mod.chain_id(rpc) do
      ^pinned -> :ok
      got -> {:error, {:chain_id_mismatch, expected: pinned, got: got}}
    end
  end

  defp codehash(rpc_mod, rpc, addr) do
    "0x" <> hex = rpc_mod.code(rpc, addr)
    "0x" <> Base.encode16(Keccak.hash_256(Base.decode16!(hex, case: :mixed)), case: :lower)
  end
end
