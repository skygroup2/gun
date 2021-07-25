defmodule Gun do
  use Application

  def start(type, args) do
    :gun_app.start(type, args)
  end

  def stop(state) do
    :gun_app.stop(state)
  end


  def test_wss() do
    url = "wss://demo.piesocket.com/v3/channel_1?api_key=oCdCMcMPQpbvNjUIzqtvF1d2X2okWpDQj4AwARJuAgtjhzKxVEjQU6IdCjwm&notify_self"
    headers = %{
      "accept-language" => "en-US,en;q=0.9",
      "accept-encoding" => "gzip, deflate, br",
      "cache-control" => "no-cache",
      "pragma" => "no-cache",
      "origin" => "https://www.piesocket.com",
      "user-agent" => "Mozilla/5.0 (Linux; Android 11; Pixel 3 XL) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.164 Mobile Safari/537.36",
    }
    proxy_opts = Map.merge(default_option(25_000), %{protocols: [:http], proxy: "http://127.0.0.1:8080", proxy_auth: nil})
    Gun.ws_upgrade(url, headers, proxy_opts)
  end


  def default_option(connect_timeout, recv_timeout\\ 30000) do
    %{
      connect_timeout: connect_timeout,
      recv_timeout: recv_timeout,
      tcp_opts: [{:reuseaddr, true}, {:linger, {false, 0}}],
      tls_opts: [{:verify, :verify_none}, {:logging_level, :error}, {:log_alert, false}],
      http_opts: %{version: :"HTTP/1.1"},
      http2_opts: %{settings_timeout: 15000, preface_timeout: 30000},
      ws_opts: %{
        compress: true,
        reply_to: self(),
      },
    }
  end

  def format_gun_opts(opts) do
    Map.drop(opts, [:recv_timeout])
  end

  def ws_upgrade(url, headers, opts) do
    u = :gun_url.parse_url(url)
    case :gun.open(u.host, u.port, format_gun_opts(opts)) do
      {:ok, conn} ->
        mref = Process.monitor(conn)
        http_await_make_upgrade(conn, mref, u.raw_path, headers, opts)
      exp ->
        exp
    end
  end

  def http_await_make_upgrade(conn, mref, raw_path, headers, opts) do
    case :gun.await_up(conn, Map.get(opts, :connect_timeout, 15000), mref) do
      {:ok, _protocols} ->
        stream = :gun.ws_upgrade(conn, raw_path, headers, Map.get(opts, :ws_opts, %{}))
        case http_recv(conn, stream, nil, mref, Map.get(opts, :recv_timeout, 10000)) do
          {:error, :retry} ->
            http_await_make_upgrade(conn, mref, raw_path, headers, opts)
          resp ->
            Map.merge(resp, %{pid: conn, mref:  mref})
        end
      {:error, reason} ->
        Process.demonitor(mref, [:flush])
        http_close(nil, conn)
        http_format_error(reason)
    end
  end

  def http_request(method, url, headers, body, opts, ref) do
    u = :gun_url.parse_url(url)
    conn = Process.get(ref)
    if is_pid(conn) and Process.alive?(conn) do
      mref = Process.monitor(conn)
      stream = :gun.request(conn, method, u.raw_path, headers, body, format_gun_opts(opts))
      case http_recv(conn, stream, ref, mref, Map.get(opts, :connect_timeout, 20000)) do
        {:error, :retry} ->
          http_await_make_request(conn, ref, mref, method, u.raw_path, headers, body, opts)
        resp ->
          resp
      end
    else
      opts =
        if u.scheme == :https, do: Map.merge(opts, %{transport: :tls}), else: opts
      case :gun.open(u.host, u.port, format_gun_opts(opts)) do
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
        http_format_error(reason)
    end
  end

  def http_recv(conn, stream, ref, mref, timeout) do
    resp = http_recv(conn, stream, ref, mref, timeout, %{status_code: 200,
      headers: [], body: "", protocols: [], mref: nil, cookies: [], reason: nil})
    case resp do
      {:error, :retry} ->
        resp
      {:error, _} ->
        Process.demonitor(mref, [:flush])
        http_close(ref, conn)
        http_format_error(resp)
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

  def http_format_error(reason) do
    case reason do
      :normal -> {:error, :closed}
      :close -> {:error, :closed}
      {:error, {:shutdown, :closed}} -> {:error, :closed}
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
      {:gun_upgrade, ^conn, ^stream, protocols, headers} ->
        %{resp| status_code: 101, headers: headers, protocols: protocols}
      {:DOWN, ^mref, :process, ^conn, reason} ->
        http_format_error(reason)
      {:gun_down, ^conn, _proto, reason, retry, _killed_stream, _unprocessed_stream} ->
        if retry > 0 do
          {:error, :retry}
        else
          http_format_error(reason)
        end
      {:gun_error, ^conn, ^stream, reason} ->
        http_format_error(reason)
      {:gun_error, ^conn, reason} ->
        http_format_error(reason)
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
