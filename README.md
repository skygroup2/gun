# GunEx

**Gun with proxy**

### Online documentation

* [User guide](https://ninenines.eu/docs/en/gun/1.3/guide)
* [Function reference](https://ninenines.eu/docs/en/gun/1.3/manual)

### Changes

* Forked from https://github.com/ninenines/gun
* Reuse HTTP/1.1, HTTP/2 Websocket client
* Reuse proxy from hackney

### TODO

* Add feature to determine traffic usage via callback function
* [Refactor test for ExUnit](https://elixirforum.com/t/commoner-elixir-wrapper-for-common-test-library/23966/4)


### Patch/Merge

* Keep tracking upstream source code
* Remove unused things : event_handler, socks, raw, tls_proxy
* Support simpler proxy code from hackney