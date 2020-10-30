defmodule SocksTest do
  use ExUnit.Case

  test "socks5_msg" do
    # AUTH
    auth = %{type: :auth, method: [Enum.random(0..255)]}
    bin = :gun_socks5_msg.encode(:c, auth)
    assert(auth == :gun_socks5_msg.decode(:s, bin))
    # CONNECT
    connect = %{type: :connect, host: {127, 0, 0, 1}, port: Enum.random(2000..50000)}
    bin = :gun_socks5_msg.encode(:c, connect)
    assert(connect == :gun_socks5_msg.decode(:s, bin))
    connect = %{type: :connect, host: '127.0.0.1', port: Enum.random(2000..50000)}
    bin = :gun_socks5_msg.encode(:c, connect)
    assert(connect == :gun_socks5_msg.decode(:s, bin))
    connect = %{type: :connect, host: {0, 0, 0, 0, 0, 0, 0, 1}, port: Enum.random(2000..50000)}
    bin = :gun_socks5_msg.encode(:c, connect)
    assert(connect == :gun_socks5_msg.decode(:s, bin))
    # AUTH DATA
    auth_data = %{type: :auth_data,
      user: Base.encode64(:crypto.strong_rand_bytes(Enum.random(3..8))),
      password: Base.encode64(:crypto.strong_rand_bytes(Enum.random(10..20)))
    }
    bin = :gun_socks5_msg.encode(:c, auth_data)
    assert(auth_data == :gun_socks5_msg.decode(:s, bin))
    # Reply
    reply = %{type: :reply, reply: Enum.random(0..255), reserve: Enum.random(0..255), host: {127, 0, 0, 1}, port: Enum.random(2000..50000)}
    bin = :gun_socks5_msg.encode(:s, reply)
    assert(reply == :gun_socks5_msg.decode(:c, bin))
    reply = %{type: :reply, reply: Enum.random(0..255), reserve: Enum.random(0..255), host: '127.0.0.1', port: Enum.random(2000..50000)}
    bin = :gun_socks5_msg.encode(:s, reply)
    assert(reply == :gun_socks5_msg.decode(:c, bin))
    reply = %{type: :reply, reply: Enum.random(0..255), reserve: Enum.random(0..255), host: {0, 0, 0, 0, 0, 0, 0, 1}, port: Enum.random(2000..50000)}
    bin = :gun_socks5_msg.encode(:s, reply)
    assert(reply == :gun_socks5_msg.decode(:c, bin))
    # AUTH RESP
    auth_resp = %{type: :auth_resp, method: Enum.random(0..255)}
    bin = :gun_socks5_msg.encode(:s, auth_resp)
    assert(auth_resp == :gun_socks5_msg.decode(:c, bin))
    # AUTH STATUS
    auth_status = %{type: :auth_status, status: Enum.random(0..255)}
    bin = :gun_socks5_msg.encode(:s, auth_status)
    assert(auth_status == :gun_socks5_msg.decode(:c, bin))
  end

  test "socks6_msg" do
    :ok
  end
end