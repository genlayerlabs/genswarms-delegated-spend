defmodule DelegatedSpend.Secp256k1Test do
  use ExUnit.Case, async: true
  alias DelegatedSpend.Evm.{Address, Secp256k1}
  alias DelegatedSpend.Keccak

  # anvil dev key #0 — universally known test key, safe to embed.
  @anvil0 Base.decode16!("AC0974BEC39A17E36BA4A6B4D238FF944BACB478CBED5EFCAE784D7BF4F2FF80")

  test "sign/recover roundtrip binds the address" do
    digest = Keccak.hash_256("delegated-spend test message")
    {r, s, recid} = Secp256k1.sign(digest, @anvil0)
    <<4, pub::binary>> = Secp256k1.recover(digest, r, s, recid)

    addr =
      "0x" <> (pub |> Keccak.hash_256() |> binary_part(12, 20) |> Base.encode16(case: :lower))

    assert String.downcase(Address.from_private_key(@anvil0)) == addr
  end

  test "rfc6979 determinism: same input, same signature" do
    digest = Keccak.hash_256("determinism")
    assert Secp256k1.sign(digest, @anvil0) == Secp256k1.sign(digest, @anvil0)
  end

  test "anvil key 0 derives the canonical dev address" do
    assert Address.from_private_key(@anvil0) ==
             "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
  end

  test "eip-55 checksum" do
    assert Address.checksum("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed") ==
             "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
  end
end
