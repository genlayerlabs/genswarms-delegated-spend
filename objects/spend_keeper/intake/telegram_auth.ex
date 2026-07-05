defmodule DelegatedSpend.Intake.TelegramAuth do
  @moduledoc """
  Telegram WebApp `initData` verification (spec §6.1): HMAC per Telegram's
  published algorithm plus `auth_date` freshness to stop replay.

    secret_key        = HMAC_SHA256(key: "WebAppData", msg: bot_token)
    data_check_string = sorted "k=v" lines of every field except `hash`
    valid             ⇔ hex(HMAC_SHA256(secret_key, dcs)) == hash
                        AND now - auth_date <= max_age_s

  Returns only what the intake needs — the numeric user id (for the app's
  `user_ref` derivation) — and NEVER logs the payload (spec §10.1: `initData`
  is redacted from logs; raw platform ids are never persisted here).
  """

  @doc """
  `verify(init_data, bot_token, max_age_s, now_s \\\\ os_time)` →
  `{:ok, %{user_id: integer}} | {:error, :malformed | :bad_hash | :stale}`
  """
  def verify(init_data, bot_token, max_age_s, now_s \\ System.os_time(:second))

  def verify(init_data, bot_token, max_age_s, now_s)
      when is_binary(init_data) and is_binary(bot_token) do
    with {:ok, fields} <- decode(init_data),
         {:ok, hash} <- Map.fetch(fields, "hash") |> ok_or(:malformed),
         :ok <- check_hash(Map.delete(fields, "hash"), hash, bot_token),
         :ok <- check_fresh(fields["auth_date"], max_age_s, now_s),
         {:ok, user_id} <- extract_user(fields["user"]) do
      {:ok, %{user_id: user_id}}
    end
  end

  def verify(_, _, _, _), do: {:error, :malformed}

  defp decode(init_data) do
    {:ok, URI.decode_query(init_data)}
  rescue
    _ -> {:error, :malformed}
  end

  defp check_hash(fields, hash, bot_token) do
    dcs =
      fields
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)

    secret = :crypto.mac(:hmac, :sha256, "WebAppData", bot_token)
    expected = :crypto.mac(:hmac, :sha256, secret, dcs) |> Base.encode16(case: :lower)

    # constant-time compare — the hash is attacker-supplied
    if byte_size(hash) == byte_size(expected) and :crypto.hash_equals(hash, expected),
      do: :ok,
      else: {:error, :bad_hash}
  end

  defp check_fresh(auth_date, max_age_s, now_s) when is_binary(auth_date) do
    case Integer.parse(auth_date) do
      {ts, ""} when now_s - ts <= max_age_s -> :ok
      {_ts, ""} -> {:error, :stale}
      _ -> {:error, :malformed}
    end
  end

  defp check_fresh(_, _, _), do: {:error, :malformed}

  defp extract_user(nil), do: {:error, :malformed}

  defp extract_user(json) do
    case Jason.decode(json) do
      {:ok, %{"id" => id}} when is_integer(id) -> {:ok, id}
      _ -> {:error, :malformed}
    end
  end

  defp ok_or({:ok, v}, _e), do: {:ok, v}
  defp ok_or(:error, e), do: {:error, e}
end
