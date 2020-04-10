defmodule GunTest do
  use ExUnit.Case
  doctest Gun

  test "without_proxy" do
    # http
    url = "http://lumtest.com/myip"
    headers = %{"connection" => "close"}
    opts = Gun.default_option(25000, 25000)
    ret1 = Gun.http_request("GET", url, headers, "", opts, nil)
    # https
    url = "https://lumtest.com/myip"
    ret2 = Gun.http_request("GET", url, headers, "", opts, nil)
    assert(ret1.body == ret2.body)
  end

  test "socks5_proxy" do
    # run ssh -D 1080 -q -C -N user@ma.ttias.be
    proxy = %{proxy: {:socks5, {127, 0, 0, 1}, 1080}}
    url = "http://lumtest.com/myip"
    headers = %{"connection" => "close"}
    opts = Gun.default_option(25000, 25000) |> Map.merge(proxy)
    ret1 = Gun.http_request("GET", url, headers, "", opts, nil)
    # https
    url = "https://lumtest.com/myip"
    ret2 = Gun.http_request("GET", url, headers, "", opts, nil)
    assert(ret1.body == ret2.body)
  end

  test "http_proxy" do
    # run
    proxy = %{proxy: "xxx", proxy_auth: {"a", "b"}}
    url = "http://lumtest.com/myip"
    headers = %{"connection" => "close"}
    opts = Gun.default_option(25000, 25000) |> Map.merge(proxy)
    ret1 = Gun.http_request("GET", url, headers, "", opts, nil)
    # https
    url = "https://lumtest.com/myip"
    ret2 = Gun.http_request("GET", url, headers, "", opts, nil)
    assert(ret1.body == ret2.body)
  end

end
