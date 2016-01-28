%%%-------------------------------------------------------------------
%%% @author guanxinquan
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 27. 一月 2016 下午5:35
%%%-------------------------------------------------------------------
-author("guanxinquan").

-record(login,{
  username,
  password,
  pid,
  clientId,
  channel
}).


-record(sync,{
  channel,
  syncTag,
  username,
  pid
}).


-record(logout,{
  username,
  pid,
  clientId
}).

-record(pub,{
  username,
  password,
  pid,
  message,
  channel
}).