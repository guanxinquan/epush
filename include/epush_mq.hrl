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
  clientId,
  channel,
  pid
}).


-record(sync,{
  username,
  channel,
  syncTag,
  pid
}).


-record(logout,{
  username,
  clientId,
  pid
}).

-record(pub,{
  username,
  channel,
  message,
  pid
}).