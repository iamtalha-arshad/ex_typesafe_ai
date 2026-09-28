defmodule TypeSafe.Server do
  @moduledoc false
  # A supervised owner for a named, application-level client.
  #
  # A `TypeSafe.Client` is an immutable value with nothing to refresh, so this process does not sit on
  # the request path. On `init` it builds the client once and publishes it to `:persistent_term`,
  # where `TypeSafe.client/1` reads it without any message passing — reads stay lock-free and
  # concurrent. The process exists only to own the entry's lifecycle: it clears it on shutdown and
  # lets the supervisor rebuild it (re-reading env/opts) on restart.

  use GenServer

  alias TypeSafe.Client

  @doc "Child spec keyed by `:name`, so multiple named clients coexist under one supervisor."
  def child_spec(opts) do
    %{
      id: {__MODULE__, fetch_name!(opts)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Start and register a client under `opts[:name]`. See `TypeSafe.new/1` for the other options."
  def start_link(opts) do
    name = fetch_name!(opts)
    GenServer.start_link(__MODULE__, {name, opts}, name: name)
  end

  @doc "Fetch the client registered under `name`, or `:error` if none is registered."
  @spec fetch(atom()) :: {:ok, Client.t()} | :error
  def fetch(name) do
    case :persistent_term.get(key(name), :undefined) do
      %Client{} = client -> {:ok, client}
      :undefined -> :error
    end
  end

  @impl true
  def init({name, opts}) do
    Process.flag(:trap_exit, true)

    # Client.new/1 validates config and raises TypeSafe.ConfigError on bad input, failing the child
    # start loudly at boot rather than on the first request.
    :persistent_term.put(key(name), Client.new(Keyword.delete(opts, :name)))
    {:ok, %{name: name}}
  end

  @impl true
  def terminate(_reason, %{name: name}) do
    :persistent_term.erase(key(name))
    :ok
  end

  defp key(name), do: {__MODULE__, name}

  defp fetch_name!(opts) do
    case Keyword.get(opts, :name) do
      name when is_atom(name) and not is_nil(name) ->
        name

      other ->
        raise ArgumentError,
              "TypeSafe requires a :name (a non-nil atom) to start a supervised client, got: " <>
                inspect(other)
    end
  end
end
