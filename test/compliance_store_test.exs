defmodule DelegatedSpend.Compliance.StoreTest do
  use ExUnit.Case, async: true

  alias DelegatedSpend.Compliance.Store
  alias DelegatedSpend.Intake

  @empty_meta %{ip: nil, country: nil, user_agent: nil, session_id: nil}

  test "two-arity intake handlers delegate with empty request metadata" do
    ctx = %{bot_token: "test-token", max_age_s: 900}

    for handler <- [:handle_order, :handle_grant, :handle_wallet, :handle_submitted] do
      assert apply(Intake, handler, [%{}, ctx]) == apply(Intake, handler, [%{}, %{}, ctx])
    end
  end

  test "normalizes the four allowed fields and drops unknown keys" do
    assert Store.normalize_meta(%{
             ip: "203.0.113.4",
             country: "uS",
             user_agent: "wallet/1.0",
             session_id: "session-1",
             ignored: "client data"
           }) == %{
             ip: "203.0.113.4",
             country: "US",
             user_agent: "wallet/1.0",
             session_id: "session-1"
           }
  end

  test "accepts only two ASCII letters as a country" do
    for country <- [nil, :us, "", "U", "USA", "U1", "U_", "Ü", "ß"] do
      assert %{country: nil} = Store.normalize_meta(%{country: country})
    end

    assert %{country: "GB"} = Store.normalize_meta(%{country: "Gb"})
  end

  test "bounds user agents by bytes without splitting valid UTF-8" do
    utf8 = String.duplicate("a", 255) <> "é"
    normalized = Store.normalize_meta(%{user_agent: utf8}).user_agent

    assert normalized == String.duplicate("a", 255)
    assert byte_size(normalized) <= 256
    assert String.valid?(normalized)

    binary = :binary.copy(<<255>>, 300)
    assert Store.normalize_meta(%{user_agent: binary}).user_agent == binary_part(binary, 0, 256)
  end

  test "returns the empty shape for nil and non-map input" do
    assert Store.normalize_meta(nil) == @empty_meta
    assert Store.normalize_meta("not a map") == @empty_meta
    assert Store.normalize_meta(%{user_agent: 42, unknown: true}) == @empty_meta
  end
end
