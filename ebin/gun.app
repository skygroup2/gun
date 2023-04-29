{application, 'gun', [
	{description, "HTTP/1.1, HTTP/2 and Websocket client for Erlang/OTP."},
	{vsn, "2.x"},
	{modules, ['gun','gun_app','gun_content_handler','gun_data_h','gun_http','gun_http2','gun_sse_h','gun_sup','gun_tcp','gun_tls','gun_ws','gun_ws_h',
		'gun_bstr','gun_http_date','gun_http_proxy','gun_socks5_msg','gun_socks5_proxy','gun_stats','gun_url','gun_util']},
	{registered, [gun_sup]},
	{applications, [kernel,stdlib,ssl,cowlib]},
	{mod, {gun_app, []}},
	{env, []}
]}.