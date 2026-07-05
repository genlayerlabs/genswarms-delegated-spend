defmodule DelegatedSpend.Evm.Address do
  @moduledoc """
  Port of a production-proven pure-Elixir EVM module; do not diverge.

  Ethereum address helpers — pure (keccak + secp256k1 in-BEAM, no network).

  Addresses flow through the chain layer as `0x`-prefixed **checksummed strings**
  (EIP-55). `to_bytes/1` converts one to the 20 raw bytes `ex_abi` wants for an
  `address` argument; `from_private_key/1` derives the bot's address; `eq?/2`
  compares case-insensitively (a log topic recovers lowercase).
  """

  @doc "Derive the checksummed `0x…` address for a raw 32-byte secp256k1 private key."
  def from_private_key(priv) when is_binary(priv) do
    <<4, pub::binary>> = DelegatedSpend.Evm.Secp256k1.public_key(priv)
    pub |> DelegatedSpend.Keccak.hash_256() |> binary_part(12, 20) |> checksum()
  end

  @doc "Derive the address created by `sender` at `nonce` for a standard CREATE deploy."
  def create_address(sender, nonce) when is_integer(nonce) do
    [to_bytes(sender), nonce]
    |> ExRLP.encode()
    |> DelegatedSpend.Keccak.hash_256()
    |> binary_part(12, 20)
    |> checksum()
  end

  @doc "20 raw bytes for an `0x…` address string (or pass-through a 20-byte binary)."
  def to_bytes(<<_::binary-size(20)>> = bin), do: bin
  def to_bytes(addr) when is_binary(addr), do: Base.decode16!(strip0x(addr), case: :mixed)

  @doc "EIP-55 checksummed `0x…` string from a 20-byte binary or any-case hex string."
  def checksum(<<_::binary-size(20)>> = bin), do: checksum(Base.encode16(bin, case: :lower))

  def checksum(addr) when is_binary(addr) do
    lower = addr |> strip0x() |> String.downcase()
    hash = lower |> DelegatedSpend.Keccak.hash_256() |> Base.encode16(case: :lower)

    out =
      Enum.zip(String.to_charlist(lower), String.to_charlist(hash))
      |> Enum.map(fn {c, h} ->
        if c in ?a..?f and (h in ?8..?9 or h in ?a..?f), do: c - 32, else: c
      end)

    "0x" <> List.to_string(out)
  end

  @doc "Case-insensitive address equality."
  def eq?(a, b), do: down(a) == down(b)

  defp down(a), do: a |> strip0x() |> String.downcase()
  defp strip0x("0x" <> h), do: h
  defp strip0x("0X" <> h), do: h
  defp strip0x(h), do: h
end
