{application, gun, [
	{description, "HTTP/1.1, HTTP/2 and Websocket client for Erlang/OTP."},
	{vsn, "1.0.0-pre.2"},
	{modules, ['gun','gun_app','gun_http','gun_http2','gun_spdy','gun_sup','gun_ws']},
	{registered, [gun_sup]},
	{applications, [kernel,stdlib,ssl,cowlib,ranch]},
	{mod, {gun_app, []}},
	{env, []}
]}.