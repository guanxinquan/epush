-module(epush_app).

%% Application callbacks
-export([start/0, stop/1,start_listeners/0,stop_listeners/0,is_running/1,start/2]).

-behavior(application).

-define(APP,epush).

-define(MQTT_SOCKOPTS, [
    binary,
    {packet,    raw},
    {reuseaddr, true},
    {backlog,   512},
    {nodelay,   true}]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

-spec env(atom()) -> list().
env(Group) ->
    application:get_env(?APP, Group, []).

%%-spec env(atom(), atom()) -> undefined | any().
%%env(Group, Name) ->
%%    proplists:get_value(Name, env(Group)).



-spec start() -> ok | {error,any()}.
start() ->%启动app
    application:start(?APP).

start(_Type,_) ->
    start_listeners(),
    {ok,self()}.

-spec start_listeners() -> any().
start_listeners() ->%启动listeners
    {ok, Listeners} = application:get_env(?APP, listeners),
    lists:foreach(fun start_listener/1, Listeners).

start_listener({mqtt, Port, Options}) ->
    start_listener(mqtt, Port, Options).

start_listener(Protocol, Port, Options) ->
    MFArgs = {epush_client, start_link, []},
    esockd:open(Protocol, Port, merge_sockopts(Options) , MFArgs).


stop_listeners() ->%停止所有listerners
    {ok, Listeners} = application:get_env(?APP, listeners),
    lists:foreach(fun stop_listener/1, Listeners).

stop_listener({Protocol, Port, _Options}) ->
    esockd:close({Protocol, Port}).



stop(_State) ->
    ok.


is_running(Node) ->%判断是否还在运行
    case rpc:call(Node, erlang, whereis, [?APP]) of
        {badrpc, _}          -> false;
        undefined            -> false;
        Pid when is_pid(Pid) -> true
    end.



merge_sockopts(Options) ->
    SockOpts = epush_opts:merge(?MQTT_SOCKOPTS,
        proplists:get_value(sockopts, Options, [])),
    epush_opts:merge(Options, [{sockopts, SockOpts}]).
