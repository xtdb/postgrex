defmodule Postgrex.Connection do
  @moduledoc """
  Main API for Postgrex. This module handles the connection to postgres.
  """

  use GenServer.Behaviour
  use Postgrex.Protocol.Messages
  alias Postgrex.Protocol
  alias Postgrex.Types
  import Postgrex.BinaryUtils

  # possible states: auth, init, parsing, describing, binding, executing, ready

  defrecordp :state, [ :opts, :sock, :tail, :state, :reply_to, :parameters,
                       :backend_key, :rows, :statement, :portal, :qparams,
                       :bootstrap, :types, :transactions ]

  defrecordp :statement, [:row_info, :columns]
  defrecordp :portal, [:param_oids]

  ### PUBLIC API ###

  @doc """
  Start the connection process and connect to postgres.

  ## Options

    * `:hostname` - Server hostname (required);
    * `:port` - Server port (default: 5432);
    * `:username` - Username (required);
    * `:password` - User password;
    * `:encoder` - Custom encoder function;
    * `:decoder` - Custom decoder function;
    * `:decode_formatter` - Function deciding the format for a type;
    * `:parameters` - Keyword list of connection parameters;

  ## Function signatures

      @spec encoder(type :: atom, sender :: atom, oid :: integer, default :: fun, param :: term) ::
            { :binary | :text, binary }
      @spec decoder(type :: atom, sender :: atom, oid :: integer, default :: fun, bin :: binary) ::
            term
      @spec decode_formatter(type :: atom, sender :: atom, oid :: integer) ::
            :binary | :text
  """
  @spec start_link(Keyword.t) :: { :ok, pid } | { :error, Postgrex.Error.t | term }
  def start_link(opts) do
    case :gen_server.start_link(__MODULE__, [], []) do
      { :ok, pid } ->
        opts = fix_opts(opts)
        case :gen_server.call(pid, { :connect, opts }) do
          :ok -> { :ok, pid }
          err -> { :error, err }
        end
      err -> err
    end
  end

  @doc """
  Stop the process and disconnect.
  """
  @spec stop(pid) :: :ok
  def stop(pid) do
    :gen_server.call(pid, :stop)
  end

  @doc """
  Runs an (extended) query and returns the result. Parameters can be set in the
  query as `$1` embedded in the query string. Parameters are given as a list of
  elixir values. See the README for information on how Postgrex encodes and
  decodes elixir values by default. See `Postgrex.Result` for the result data.
  """
  @spec query(pid, String.t, list) :: { :ok, Postgrex.Result.t } | { :error, Postgrex.Error.t }
  def query(pid, statement, params // []) do
    case :gen_server.call(pid, { :query, statement, params }) do
      Postgrex.Result[] = res -> { :ok, res }
      Postgrex.Error[] = err -> { :error, err }
    end
  end

  @doc """
  Returns a cached list dict of connection parameters.
  """
  @spec parameters(pid) :: [{ String.t, String.t }]
  def parameters(pid) do
    :gen_server.call(pid, :parameters)
  end

  @doc """
  Starts a transaction. Transactions can be nested with the help of savepoints.
  A transaction won't end until a `rollback/1` or `commit/1` have been issued
  for every `begin/1`.

  ## Example

      # Transaction begun
      Postgrex.Connection.begin(pid)
      Postgrex.Connection.query(pid, "INSERT INTO comments (text) VALUES ('first')")

      # Nested subtransaction begun
      Postgrex.Connection.begin(pid)
      Postgrex.Connection.query(pid, "INSERT INTO comments (text) VALUES ('second')")

      # Subtransaction rolled back
      Postgrex.Connection.rollback(pid)

      # Only the first comment will be commited because the second was rolled back
      Postgrex.Connection.commit(pid)
  """
  @spec begin(pid) :: :ok | { :error, Postgrex.Error.t }
  def begin(pid) do
    case :gen_server.call(pid, :begin) do
      Postgrex.Result[] -> :ok
      err -> err
    end
  end

  @doc """
  Rolls back a transaction. See `begin/1` for more information.
  """
  @spec rollback(pid) :: :ok | { :error, Postgrex.Error.t }
  def rollback(pid) do
    case :gen_server.call(pid, :rollback) do
      Postgrex.Result[] -> :ok
      err -> err
    end
  end

  @doc """
  Commits a transaction. See `begin/1` for more information.
  """
  @spec commit(pid) :: :ok | { :error, Postgrex.Error.t }
  def commit(pid) do
    case :gen_server.call(pid, :commit) do
      Postgrex.Result[] -> :ok
      err -> err
    end
  end

  @doc """
  Helper for creating reliable transactions. If an error is raised in the given
  function the transaction is rolled back, otherwise it is commited. A
  transaction can be cancelled with `throw :postgrex_rollback`. If there is a
  connection error `Postgrex.Error` will be raised.

  NOTE: Do not use this function in conjunction with `begin/1`, `commit/1` and
  `rollback/1`.
  """
  @spec in_transaction(pid, (() -> term)) :: term | no_return
  def in_transaction(pid, fun) do
    case begin(pid) do
      :ok ->
        try do
          value = fun.()
          case commit(pid) do
            :ok -> value
            err -> raise err
          end
        catch
          :throw, :postgrex_rollback ->
            case rollback(pid) do
              :ok -> nil
              err -> raise err
            end
          type, term ->
            rollback(pid)
            :erlang.raise(type, term, System.stacktrace)
        end
      err -> raise err
    end
  end

  defp fix_opts(opts) do
    opts
      |> Keyword.update!(:hostname, &if is_binary(&1), do: String.to_char_list!(&1), else: &1)
      |> Keyword.put_new(:port, 5432)
  end

  ### GEN_SERVER CALLBACKS ###

  @doc false
  def init([]) do
    { :ok, state(state: :ready, tail: "", parameters: [], rows: [],
                 bootstrap: false, transactions: 0) }
  end

  @doc false
  def handle_call(:stop, from, state(state: :ready) = s) do
    { :stop, :normal, state(s, reply_to: from) }
  end

  def handle_call({ :connect, opts }, from, state(state: :ready) = s) do
    sock_opts = [ { :active, :once }, { :packet, :raw }, :binary ]

    case :gen_tcp.connect(opts[:hostname], opts[:port], sock_opts) do
      { :ok, sock } ->
        params = opts[:parameters] || []
        msg = msg_startup(params: [user: opts[:username], database: opts[:database]] ++ params)
        case send(msg, sock) do
          :ok ->
            { :noreply, state(s, opts: opts, sock: sock, reply_to: from, state: :auth) }
          { :error, reason } ->
            :gen_server.reply(from, Postgrex.Error[reason: "tcp send: #{reason}"])
            { :stop, :normal, s }
        end

      { :error, reason } ->
        :gen_server.reply(from, Postgrex.Error[reason: "tcp connect: #{reason}"])
        { :stop, :normal, s }
    end
  end

  def handle_call({ :query, statement, params }, from, state(state: :ready) = s) do
    case send_query(statement, s) do
      { :ok, s } ->
        { :noreply, state(s, qparams: params, reply_to: from) }
      { :error, reason, s } ->
        :gen_server.reply(from, { :error, reason })
        { :stop, :normal, s }
    end
  end

  def handle_call(:parameters, from, state(parameters: params, state: :ready) = s) do
    :gen_server.reply(from, params)
    { :noreply, s }
  end

  def handle_call(:begin, from, state(transactions: trans, state: :ready) = s) do
    if trans == 0 do
      s = state(s, transactions: 1)
      handle_call({ :query, "BEGIN", [] }, from, s)
    else
      s = state(s, transactions: trans + 1)
      handle_call({ :query, "SAVEPOINT postgrex_#{trans}", [] }, from, s)
    end
  end

  def handle_call(:rollback, from, state(transactions: trans, state: :ready) = s) do
    cond do
      trans == 0 ->
        :gen_server.reply(from, :ok)
        { :noreply, s }
      trans == 1 ->
        s = state(s, transactions: 0)
        handle_call({ :query, "ROLLBACK", [] }, from, s)
      true ->
        trans = trans - 1
        s = state(s, transactions: trans)
        handle_call({ :query, "ROLLBACK TO SAVEPOINT postgrex_#{trans}", [] }, from, s)
    end
  end

  def handle_call(:commit, from, state(transactions: trans, state: :ready) = s) do
    case trans do
      0 ->
        :gen_server.reply(from, :ok)
        { :noreply, s }
      1 ->
        s = state(s, transactions: 0)
        handle_call({ :query, "COMMIT", [] }, from, s)
      _ ->
        :gen_server.reply(from, :ok)
        { :noreply, state(s, transactions: trans - 1) }
    end
  end

  @doc false
  def handle_info({ :tcp, _, data }, state(reply_to: from, sock: sock, tail: tail) = s) do
    case handle_data(tail <> data, state(s, tail: "")) do
      { :ok, s } ->
        :inet.setopts(sock, active: :once)
        { :noreply, s }
      { :error, error, s } ->
        if from do
          :gen_server.reply(from, error)
          { :stop, :normal, s }
        else
          { :stop, error, s }
        end
    end
  end

  def handle_info({ :tcp_closed, _ }, state(reply_to: from) = s) do
    error = Postgrex.Error[reason: "tcp closed"]
    if from do
      :gen_server.reply(from, error)
      { :stop, :normal, s }
    else
      { :stop, error, s }
    end
  end

  def handle_info({ :tcp_error, _, reason }, state(reply_to: from) = s) do
    error = Postgrex.Error[reason: "tcp error: #{reason}"]
    if from do
      :gen_server.reply(from, error)
      { :stop, :normal, s }
    else
      { :stop, error, s }
    end
  end

  @doc false
  def terminate(reason, state(sock: sock) = s) do
    if sock do
      send(msg_terminate(), sock)
      :gen_tcp.close(sock)
    end
    if reason == :normal do
      reply(:ok, s)
    else
      reply(Postgrex.Error[reason: "terminated: #{inspect reason}"], s)
    end
  end

  ### PRIVATE FUNCTIONS ###

  defp handle_data(<< type :: int8, size :: int32, data :: binary >> = tail, s) do
    size = size - 4

    case data do
      << data :: binary(size), tail :: binary >> ->
        msg = Protocol.decode(type, size, data)
        case message(msg, s) do
          { :ok, s } -> handle_data(tail, s)
          { :error, _, _ } = err -> err
        end
      _ ->
        { :ok, state(s, tail: tail) }
    end
  end

  defp handle_data(data, state(tail: tail) = s) do
    { :ok, state(s, tail: tail <> data) }
  end

  ### auth state ###

  defp message(msg_auth(type: :ok), state(state: :auth) = s) do
    { :ok, state(s, state: :init) }
  end

  defp message(msg_auth(type: :cleartext), state(opts: opts, state: :auth) = s) do
    msg = msg_password(pass: opts[:password])
    send_to_result(msg, s)
  end

  defp message(msg_auth(type: :md5, data: salt), state(opts: opts, state: :auth) = s) do
    digest = :crypto.hash(:md5, [opts[:password], opts[:username]]) |> hexify
    digest = :crypto.hash(:md5, [digest, salt]) |> hexify
    msg = msg_password(pass: ["md5", digest])
    send_to_result(msg, s)
  end

  defp message(msg_error(fields: fields), state(state: :auth) = s) do
    { :error, Postgrex.Error[postgres: fields], s }
  end

  ### init state ###

  defp message(msg_backend_key(pid: pid, key: key), state(state: :init) = s) do
    { :ok, state(s, backend_key: { pid, key }) }
  end

  defp message(msg_ready(), state(state: :init) = s) do
    s = state(s, bootstrap: true)
    send_query(Types.bootstrap_query, state(s, qparams: []))
  end

  defp message(msg_error(fields: fields), state(state: :init) = s) do
    { :error, Postgrex.Error[postgres: fields], s }
  end

  ### parsing state ###

  defp message(msg_parse_complete(), state(state: :parsing) = s) do
    { :ok, state(s, state: :describing) }
  end

  ### describing state ###

  defp message(msg_parse_complete(), state(state: :describing) = s) do
    send_params(s, [])
  end

  defp message(msg_parameter_desc(type_oids: oids), state(state: :describing) = s) do
    { :ok, state(s, portal: portal(param_oids: oids)) }
  end

  defp message(msg_row_desc(fields: fields), state(types: types, bootstrap: bootstrap, opts: opts, state: :describing) = s) do
    rfs = []
    if not bootstrap do
      decode_formatter = opts[:decode_formatter]
      { info, rfs, cols } = extract_row_info(fields, types, decode_formatter)
      stat = statement(columns: cols, row_info: list_to_tuple(info))
      s = state(s, statement: stat)
    end

    send_params(s, rfs)
  end

  defp message(msg_no_data(), state(state: :describing) = s) do
    { :ok, s }
  end

  defp message(msg_ready(), state(state: :describing) = s) do
    { :ok, state(s, state: :binding) }
  end

  ### binding state ###

  defp message(msg_bind_complete(), state(state: :binding) = s) do
    { :ok, state(s, state: :executing) }
  end

  ### executing state ###

  # defp message(msg_portal_suspend(), state(state: :executing) = s)

  defp message(msg_data_row(values: values), state(rows: rows, state: :executing) = s) do
    { :ok, state(s, rows: [values|rows]) }
  end

  defp message(msg_command_complete(), state(bootstrap: true, rows: rows, state: :executing) = s) do
    types = Types.build_types(rows)
    s = reply(:ok, s)
    { :ok, state(s, rows: [], bootstrap: false, types: types) }
  end

  defp message(msg_command_complete(tag: tag), state(statement: stat, state: :executing) = s) do
    if nil?(stat) do
      s = reply(create_result(tag), s)
    else
      s = try do
        result = decode_rows(s)
        statement(columns: cols) = stat
        reply(create_result(tag, result, cols), s)
      catch
        { :postgrex_decode, msg } ->
          reply(Postgrex.Error[reason: msg], s)
      end
    end
    { :ok, state(s, rows: [], statement: nil, portal: nil) }
  end

  defp message(msg_empty_query(), state(state: :executing) = s) do
    s = reply(Postgrex.Result[], s)
    { :ok, s }
  end

  ### asynchronous messages ###

  defp message(msg_ready(), s) do
    { :ok, state(s, state: :ready) }
  end

  defp message(msg_parameter(name: name, value: value), state(parameters: params) = s) do
    params = Dict.put(params, name, value)
    { :ok, state(s, parameters: params) }
  end

  defp message(msg_error(fields: fields), s) do
    s = reply(Postgrex.Error[postgres: fields], s)
    # TODO: subscribers
    { :ok, s }
  end

  defp message(msg_notice(), s) do
    # TODO: subscribers
    { :ok, s }
  end

  ### helpers ###

  defp decode_rows(state(statement: stat, types: types, rows: rows, opts: opts)) do
    statement(row_info: info) = stat
    decoder = opts[:decoder]

    Enum.reduce(rows, [], fn values, acc ->
      { _, row } = Enum.reduce(values, { 0, [] }, fn
        nil, { count, list } ->
          { count + 1, [nil|list] }

        value, { count, list } when nil?(decoder) ->
          { _type, sender, _oid, can_decode } = elem(info, count)
          value = decode_value(can_decode, sender, types, value)
          { count + 1, [value|list] }

        value, { count, list } ->
          { type, sender, oid, can_decode } = elem(info, count)
          default_decoder = &decode_value(can_decode, sender, types, &1)
          value = decoder.(type, sender, oid, default_decoder, value)
          { count + 1, [value|list] }
      end)
      row = Enum.reverse(row) |> list_to_tuple
      [ row | acc ]
    end)
  end

  defp decode_value(can_decode, sender, types, value) do
    if can_decode do
      Types.decode(sender, value, types)
    else
      value
    end
  end

  defp send_params(s, rfs) do
    try do
      { pfs, params } = encode_params(s)

      msgs = [
        msg_bind(name_port: "", name_stat: "", param_formats: pfs, params: params, result_formats: rfs),
        msg_execute(name_port: "", max_rows: 0),
        msg_sync() ]

      case send_to_result(msgs, s) do
        { :ok, s } ->
          { :ok, state(s, qparams: nil) }
        err ->
          err
      end
    catch
      { :postgrex_encode, msg } ->
        s = reply(Postgrex.Error[reason: msg], s)
        { :ok, state(s, portal: nil, qparams: nil, state: :ready) }
    end
  end

  defp encode_params(state(qparams: params, portal: portal, types: types, opts: opts)) do
    param_oids = portal(portal, :param_oids)
    zipped = Enum.zip(param_oids, params)
    encoder = opts[:encoder]

    Enum.map(zipped, fn
      { _oid, nil } ->
        { :binary, nil }

      { oid, param } when nil?(encoder) ->
        { type, sender } = Types.oid_to_type(types, oid)
        encode_param(sender, type, oid, types, param)

      { oid, param } ->
        { type, sender } = Types.oid_to_type(types, oid)
        default_encoder = &encode_param(sender, type, oid, types, &1)
        encoder.(type, sender, oid, default_encoder, param)
    end) |> :lists.unzip
  end

  defp encode_param(sender, type, oid, types, param) do
    result = cond do
      Types.can_decode?(types, oid) ->
        bin = Types.encode(sender, param, oid, types)
        if bin, do: { :binary, bin }
      is_binary(param) ->
        { :text, param }
      true ->
        nil
    end

    if nil?(result) do
      throw { :postgrex_encode, "unable to encode value `#{inspect param}` as type #{type}" }
    else
      result
    end
  end

  defp extract_row_info(fields, types, decode_formatter) do
    Enum.map(fields, fn row_field(name: name, type_oid: oid) ->
      { type, sender } = Types.oid_to_type(types, oid)
      can_decode = Types.can_decode?(types, oid)

      format = if decode_formatter do
        decode_formatter.(type, sender, oid)
      else
        if can_decode, do: :binary, else: :text
      end

      { { type, sender, oid, can_decode }, format, name }
    end) |> List.unzip |> list_to_tuple
  end

  defp send_query(statement, s) do
    msgs = [
      msg_parse(name: "", query: statement, type_oids: []),
      msg_describe(type: :statement, name: ""),
      msg_sync() ]

    case send_to_result(msgs, s) do
      { :ok, s } ->
        { :ok, state(s, statement: nil, state: :parsing) }
      err ->
        err
    end
  end

  defp create_result(tag) do
    create_result(tag, nil, nil)
  end

  defp create_result(tag, rows, cols) do
    { command, nrows } = decode_tag(tag)
    Postgrex.Result[command: command, num_rows: nrows || 0, rows: rows,
                    columns: cols]
  end

  # Workaround for 0.10.3 compatibility
  defmacrop integer_parse(string) do
    if { :parse, 1 } in Integer.__info__(:functions) do
      quote do: Integer.parse(unquote(string))
    else
      quote do: String.to_integer(unquote(string))
    end
  end

  defp decode_tag(tag) do
    words = :binary.split(tag, " ", [:global])
    words = Enum.map(words, fn word ->
      case integer_parse(word) do
        { num, "" } -> num
        :error -> word
      end
    end)

    { command, nums } = Enum.split_while(words, &is_binary(&1))
    command = Enum.join(command, "_") |> String.downcase |> binary_to_atom
    { command, List.last(nums) }
  end

  defp reply(_msg, state(reply_to: nil) = s), do: s

  defp reply(msg, state(reply_to: from) = s) do
    if from, do: :gen_server.reply(from, msg)
    state(s, reply_to: nil)
  end

  defp send(msg, state(sock: sock)), do: send(msg, sock)

  defp send(msgs, sock) when is_list(msgs) do
    binaries = Enum.map(msgs, &Protocol.encode(&1))
    :gen_tcp.send(sock, binaries)
  end

  defp send(msg, sock) do
    binary = Protocol.encode(msg)
    :gen_tcp.send(sock, binary)
  end

  defp send_to_result(msg, s) do
    case send(msg, s) do
      :ok ->
        { :ok, s }
      { :error, reason } ->
        { :error, Postgrex.Error[reason: "tcp send: #{reason}"] , s }
    end
  end

  defp hexify(bin) do
    bc << high :: size(4), low :: size(4) >> inbits bin do
      << hex_char(high), hex_char(low) >>
    end
  end

  defp hex_char(n) when n < 10, do: ?0 + n
  defp hex_char(n) when n < 16, do: ?a - 10 + n
end
