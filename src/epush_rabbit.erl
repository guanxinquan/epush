-module(epush_rabbit).

-behavior(gen_server).

%% API
-export([start_link/4,sendMsg/1]).


-export([init/1,handle_call/3,handle_cast/2,handle_info/2,code_change/3,terminate/2]).

-define(LOG(Req),lager:info("epush rabbit unknow invoke ~p~n",[Req])).

-define(PUB(Exchange,RouteKey),#'basic.publish'{exchange = Exchange,routing_key = RouteKey}).

-record(state,{
  connection,
  channel
}).

-include("epush_mq.hrl").

-include_lib("amqp_client/include/amqp_client.hrl").

start_link(Hosts,VHost,Username,Password) ->
  gen_server:start({local,?MODULE},?MODULE,{Hosts,VHost,Username,Password},[]).

sendMsg(Payload,Publish) ->
  gen_server:cast(?MODULE,{send,{Payload,Publish}}).

sendMsg(Payload) when is_record(Payload,pub)->
  sendMsg(Payload,?PUB(<<"epush-pub">>,<<"epush-pub-queue">>));

sendMsg(Payload) when is_record(Payload,login) ->
  sendMsg(Payload,?PUB(<<"epush-login">>,<<"epush-login-queue">>));

sendMsg(Payload) when is_record(Payload,sync) ->
  sendMsg(Payload,?PUB(<<"epush-sync">>,<<"epush-sync-queue">>));

sendMsg(Payload) when is_record(Payload,logout) ->
  sendMsg(Payload,?PUB(<<"epush-logout">>,<<"epush-logout-queue">>)).


init({Hosts,VHost,Username,Password}) ->
  {ok,Connection} = amqp_connection:start(#amqp_params_network{
    virtual_host = VHost,
    username = Username,
    host = Hosts,
    password = Password
    }),
  {ok,Channel} = amqp_connection:open_channel(Connection),
  {ok,#state{connection = Connection,channel = Channel}}.

handle_call(Req,_From,State) ->
  ?LOG(Req),
  {noreply,State}.

handle_cast({send,{Payload,Publish}},State = #state{channel = Ch}) ->
  amqp_channel:call(Ch,Publish,#amqp_msg{payload = Payload}),
  {noreply,State};

handle_cast(Req,State) ->
  ?LOG(Req),
  {noreply,State}.

handle_info(Req,State) ->
  ?LOG(Req),
  {noreply,State}.

terminate(_Reason,#state{connection = Conn,channel = Ch}) ->
  amqp_channel:close(Ch),
  amqp_connection:close(Conn),
  ok.

code_change(_OldVsn,State,_Extra) ->
  {ok,State}.
