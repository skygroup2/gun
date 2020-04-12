defmodule Gun do
  use Application

  def start(type, args) do
    :gun_app.start(type, args)
  end

  def stop(state) do
    :gun_app.stop(state)
  end

  def default_option(connect_timeout) do
    %{
      connect_timeout: connect_timeout,
      tcp_opts: [{:reuseaddr, true}, {:reuse_sessions, false}, {:linger, {false, 0}}],
      tls_opts: [{:versions, [:"tlsv1.2"]}]
    }
  end

  def http_request(method, url, headers, body, opts, ref) do
    u = :gun_url.parse_url(url)
    conn = Process.get(ref)
    if is_pid(conn) and Process.alive?(conn) do
      mref = Process.monitor(conn)
      stream = :gun.request(conn, method, u.raw_path, headers, body, opts)
      case http_recv(conn, stream, ref, mref, Map.get(opts, :recv_timeout, 20000)) do
        {:error, :retry} ->
          http_await_make_request(conn, ref, mref, method, u.raw_path, headers, body, opts)
        resp ->
          resp
      end
    else
      opts =
        if u.scheme == :https, do: Map.merge(opts, %{transport: :tls}), else: opts
      case :gun.open(u.host, u.port, opts) do
        {:ok, conn} ->
          mref = Process.monitor(conn)
          Process.put(conn, u.raw_path)
          http_await_make_request(conn, ref, mref, method, u.raw_path, headers, body, opts)
        resp ->
          resp
      end
    end
  end

  def http_await_make_request(conn, ref, mref, method, raw_path, headers, body, opts) do
    case :gun.await_up(conn, Map.get(opts, :connect_timeout, 15000), mref) do
      {:ok, _protocols} ->
        if ref != nil, do: Process.put(ref, conn)
        stream = :gun.request(conn, method, raw_path, headers, body, opts)
        case http_recv(conn, stream, ref, mref, Map.get(opts, :recv_timeout, 10000)) do
          {:error, :retry} ->
            http_await_make_request(conn, ref, mref, method, raw_path, headers, body, opts)
          resp ->
            resp
        end
      {:error, reason} ->
        Process.demonitor(mref, [:flush])
        http_close(ref, conn)
        {:error, reason}
    end
  end

  def http_recv(conn, stream, ref, mref, timeout) do
    resp = http_recv(conn, stream, ref, mref, timeout, %{status_code: 200, headers: [], body: "", reason: nil})
    case resp do
      {:error, :retry} ->
        resp
      {:error, _} ->
        Process.demonitor(mref, [:flush])
        http_close(ref, conn)
        resp
      _ ->
        Process.demonitor(mref, [:flush])
        if ref == nil do
          http_close(ref, conn)
          resp
        else
          resp
        end
    end
  end

  defp http_format_error(reason) do
    case reason do
      :normal -> {:error, :closed}
      :close -> {:error, :closed}
      {:error, _} -> reason
      _ -> {:error, reason}
    end
  end

  def http_recv(conn, stream, ref, mref, timeout, resp) do
    receive do
      {:gun_response, ^conn, ^stream, :fin, status, headers} ->
        Map.merge(resp, %{status_code: status, headers: headers})
      {:gun_response, ^conn, ^stream, :nofin, status, headers} ->
        http_recv(conn, stream, ref, mref, timeout, Map.merge(resp, %{status_code: status, headers: headers}))
      {:gun_data, ^conn, ^stream, :fin, data} ->
        data1 = resp.body <> data
        %{resp| body: data1}
      {:gun_data, ^conn, ^stream, :nofin, data} ->
        data1 = resp.body <> data
        http_recv(conn, stream, ref, mref, timeout, %{resp| body: data1})
      {:DOWN, ^mref, :process, ^conn, reason} ->
        {:error, reason}
      {:gun_down, ^conn, _proto, reason, retry, _killed_stream, _unprocessed_stream} ->
        if retry > 0 do
          {:error, :retry}
        else
          http_format_error(reason)
        end
      {:gun_error, ^conn, ^stream, reason} ->
        {:error, reason}
      {:gun_error, ^conn, reason} ->
        {:error, reason}
    after
      timeout ->
        {:error, :timeout}
    end
  end

  def http_close(ref, conn) do
    conn1 = Process.delete(ref)
    conn2 = if is_pid(conn1), do: conn1, else: conn
    Process.delete(conn2)
    if is_pid(conn2) do
      if Process.alive?(conn2), do: :gun.shutdown(conn2)
      :gun.flush(conn2)
    else
      :ok
    end
  end
end
