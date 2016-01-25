-module(epush_keepalive).

%% API
-export([]).
-export([start/3, check/1, cancel/1]).

-record(keepalive, {statfun, statval,
  tsec, tmsg, tref,
  repeat = 0}).

-type keepalive() :: #keepalive{}.

%%------------------------------------------------------------------------------
%% @doc Start a keepalive 三个参数分别为 用于获取socket统计信息(接收字节数)的接口,超时时间,超时消息
%% @end
%%------------------------------------------------------------------------------
-spec start(fun(), integer(), any()) -> undefined | keepalive().
start(_, 0, _) ->
  undefined;
start(StatFun, TimeoutSec, TimeoutMsg) ->
  {ok, StatVal} = StatFun(),
  #keepalive{statfun = StatFun, statval = StatVal,
    tsec = TimeoutSec, tmsg = TimeoutMsg,
    tref = timer(TimeoutSec, TimeoutMsg)}.

%%------------------------------------------------------------------------------
%% @doc Check keepalive, called when timeout.
%% @end
%%------------------------------------------------------------------------------
-spec check(keepalive()) -> {ok, keepalive()} | {error, any()}.
check(KeepAlive = #keepalive{statfun = StatFun, statval = LastVal, repeat = Repeat}) ->
  case StatFun() of
    {ok, NewVal} ->
      if NewVal =/= LastVal ->
        {ok, resume(KeepAlive#keepalive{statval = NewVal, repeat = 0})};
        Repeat < 1 ->
          {ok, resume(KeepAlive#keepalive{statval = NewVal, repeat = Repeat + 1})};
        true ->
          {error, timeout}
      end;
    {error, Error} ->
      {error, Error}
  end.

resume(KeepAlive = #keepalive{tsec = TimeoutSec, tmsg = TimeoutMsg}) ->
  KeepAlive#keepalive{tref = timer(TimeoutSec, TimeoutMsg)}.

%%------------------------------------------------------------------------------
%% @doc Cancel Keepalive
%% @end
%%------------------------------------------------------------------------------
-spec cancel(keepalive()) -> ok.
cancel(#keepalive{tref = TRef}) ->
  cancel(TRef);
cancel(undefined) ->
  ok;
cancel(TRef) ->
    catch erlang:cancel_timer(TRef).

timer(Sec, Msg) ->
  erlang:send_after(timer:seconds(Sec), self(), Msg).
