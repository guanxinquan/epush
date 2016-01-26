-module(epush_rabbit).

-behavior(gen_server).

%% API
-export([]).

-record(state,{
  connection,
  channel
}).

-record(conn_info,{
  hosts,
  vhost,
  username,
  password
  }).

-include_lib("amqp_client/include/amqp_client.hrl").

start_link(Hosts,VHost,Username,Password) ->
  gen_server:start({local,?MODULE},?MODULE,{Hosts,VHost,Username,Password},[]).

sendMsg(Exchange,RouteKey,Payload) ->
  gen_server:cast(?MODULE,{send,{Exchange,RouteKey,Payload}}).

init({Hosts,VHost,Username,Password}) ->
  {ok,Connection} = amqp_connection:start(#amqp_params_network{
    virtual_host = term_to_binary(VHost),
    username = term_to_binary(Username),
    host = Hosts,
    password = term_to_binary(Password)
    }),
  {ok,Channel} = amqp_connection:open_channel(Connection),
  {ok,#state{connection = Connection,channel = Channel}}.

handle_cast({send,{Exchange,RouteKey,Payload}},State = #state{channel = Ch}) ->
  Publish =  #'basic.publish'{exchange = Exchange,routing_key = RouteKey},
  amqp_channel:call(Ch,Publish,#amqp_msg{payload = Payload}),
  {noreply,State}.

terminate(_Reason,#state{connection = Conn,channel = Ch}) ->
  amqp_channel:close(Ch),
  amqp_connection:close(Conn),
  ok.
