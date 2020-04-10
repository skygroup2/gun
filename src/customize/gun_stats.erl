-module(gun_stats).
-author("subhuti").

%% API
-export([
  create_db/0,
  update_counter/2,
  update_counter/3,
  reset_counter/1,
  read_counter/1,
  stats/0
]).

-export([
  % {conn_pid, counter }
  new_connection/1,
  del_connection/1,
  stop_connection/1,
  connection_active/1
]).

create_db() ->
  ets:new(gun_stats, [public, ordered_set, named_table, {read_concurrency, true}, {write_concurrency, true}]),
  ok.

stats() ->
  [active_connection, total_connection].

update_counter(Key, Incr) ->
  update_counter(Key, Incr, 1000000).

update_counter(Key, Incr, Threshold) ->
  ets:update_counter(gun_stats, {counter, Key}, {2, Incr, Threshold, 1}, {{counter, Key}, 0}).

reset_counter(Key) ->
  [V, _] = ets:update_counter(gun_stats, {counter, Key}, [{2, 0}, {2, 0, 0, 0}], {{counter, Key}, 0}),
  V.

read_counter(Key) ->
  case ets:lookup(gun_stats, {counter, Key}) of
    [{_, V}] ->
      V;
    [] ->
      0
  end.

new_connection(ConnPid) ->
  ets:insert(gun_stats, {ConnPid, true}).

del_connection(ConnPid) ->
  ets:delete(gun_stats, ConnPid).

stop_connection(ConnPid) ->
  case ets:lookup(gun_stats, ConnPid) of
    [_] ->
      ets:insert(gun_stats, {ConnPid, false});
    [] ->
      ok
  end.

connection_active(ConnPid) ->
  case ets:lookup(gun_stats, ConnPid) of
    [{_, V}] ->
      V;
    [] ->
      false
  end.
