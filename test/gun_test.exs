defmodule GunTest do
  use ExUnit.Case
  doctest Gun

  test "without_proxy" do
    # http
    url = "http://lumtest.com/myip"
    headers = %{"connection" => "close"}
    opts = Gun.default_option(25000)
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
    opts = Gun.default_option(25000) |> Map.merge(proxy)
    ret1 = Gun.http_request("GET", url, headers, "", opts, nil)
    # https
    url = "https://lumtest.com/myip"
    ret2 = Gun.http_request("GET", url, headers, "", opts, nil)
    assert(ret1.body == ret2.body)
  end

  test "http_proxy" do
    # run
    %{"proxy" => h, "proxy_user" => u, "proxy_password" => p} = Jason.decode! File.read!("./test/test_data.json")
    proxy = %{proxy: h, proxy_auth: {u, p}}
#    IO.inspect proxy
    url = "http://lumtest.com/myip"
    headers = %{"connection" => "close"}
    opts = Gun.default_option(25000) |> Map.merge(proxy)
    ret1 = Gun.http_request("GET", url, headers, "", opts, nil)
    # https
    url = "https://lumtest.com/myip"
    ret2 = Gun.http_request("GET", url, headers, "", opts, nil)
    assert(ret1.body == ret2.body)
  end

  test "error_code" do
    proxy = %{proxy: {:socks5, {127, 0, 0, 1}, 1081}}
    url = "http://lumtest.com/myip"
    headers = %{"connection" => "close"}
    opts = Gun.default_option(25000) |> Map.merge(proxy)
    ret1 = Gun.http_request("GET", url, headers, "", opts, nil)
    assert ret1 == {:error, :econnrefused}
  end

end
