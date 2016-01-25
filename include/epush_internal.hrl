%%%-------------------------------------------------------------------
%%% @author guanxinquan
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. 一月 2016 下午4:48
%%%-------------------------------------------------------------------
-author("guanxinquan").
-define(GPROC_POOL(JoinOrLeave, Pool, I),
  (begin
     case JoinOrLeave of
       join  -> gproc_pool:connect_worker(Pool, {Pool, Id});
       leave -> gproc_pool:disconnect_worker(Pool, {Pool, I})
     end
   end)).

-define(record_to_proplist(Def, Rec),
  lists:zip(record_info(fields, Def),
    tl(tuple_to_list(Rec)))).

-define(record_to_proplist(Def, Rec, Fields),
  [{K, V} || {K, V} <- ?record_to_proplist(Def, Rec),
    lists:member(K, Fields)]).

-define(UNEXPECTED_REQ(Req, State),
  (begin
     lager:error("Unexpected Request: ~p", [Req]),
     {reply, {error, unexpected_request}, State}
   end)).

-define(UNEXPECTED_MSG(Msg, State),
  (begin
     lager:error("Unexpected Message: ~p", [Msg]),
     {noreply, State}
   end)).

-define(UNEXPECTED_INFO(Info, State),
  (begin
     lager:error("Unexpected Info: ~p", [Info]),
     {noreply, State}
   end)).

