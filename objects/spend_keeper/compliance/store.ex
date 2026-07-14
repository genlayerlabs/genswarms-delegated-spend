defmodule DelegatedSpend.Compliance.Store do
  @moduledoc "Storage behaviour helpers for legal-compliance records."

  @empty_meta %{ip: nil, country: nil, user_agent: nil, session_id: nil}

  @doc "Normalizes server-owned request metadata into its persisted shape."
  def normalize_meta(meta) when is_map(meta) do
    %{
      ip: meta[:ip],
      country: normalize_country(meta[:country]),
      user_agent: normalize_user_agent(meta[:user_agent]),
      session_id: meta[:session_id]
    }
  end

  def normalize_meta(_), do: @empty_meta

  defp normalize_country(<<a, b>> = country)
       when (a in ?A..?Z or a in ?a..?z) and (b in ?A..?Z or b in ?a..?z),
       do: String.upcase(country)

  defp normalize_country(_), do: nil

  defp normalize_user_agent(value) when is_binary(value) and byte_size(value) > 256 do
    prefix = binary_part(value, 0, 256)

    case :unicode.characters_to_binary(prefix) do
      {:incomplete, valid, _} -> valid
      _ -> prefix
    end
  end

  defp normalize_user_agent(value) when is_binary(value), do: value
  defp normalize_user_agent(_), do: nil
end
