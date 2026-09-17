defmodule Autonomic.Canonical do
  @moduledoc "Canonical JSON identity for authority, payloads and append-only evidence."
  def json(value), do: value |> normalize() |> Jason.encode!()
  def digest(value), do: hash(json(value))
  def hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  def now, do: System.system_time(:millisecond)
  def normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()
  def normalize(map) when is_map(map) do
    pairs = Enum.map(map, fn {key, value} -> {to_string(key), normalize(value)} end)
    if length(Enum.uniq_by(pairs, &elem(&1, 0))) != length(pairs), do: raise(ArgumentError, "key collision")
    pairs |> Enum.sort_by(&elem(&1, 0)) |> Jason.OrderedObject.new()
  end
  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(value) when value in [nil, true, false], do: value
  def normalize(atom) when is_atom(atom), do: Atom.to_string(atom)
  def normalize(value) when is_binary(value) or is_number(value), do: value
  def normalize(_), do: raise(ArgumentError, "Non-JSON authority value")
  def plain(value), do: value |> json() |> Jason.decode!()
end
