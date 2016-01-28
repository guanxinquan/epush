-module(epush_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok,Rabbit} = application:get_env(epush,rabbit),
    Hosts = proplists:get_value(hosts,Rabbit,"localhost"),
    Vhost = proplists:get_value(vhost,Rabbit,epush),
    Username = proplists:get_value(username,Rabbit,epush),
    Password = proplists:get_value(password,Rabbit,epush),
    {ok, { {one_for_one, 1, 60000}, [
        {epush_rabbit,{epush_rabbit,start_link,[Hosts,Vhost,Username,Password]},permanent,infinity,worker,[epush_rabbit]}
    ]} }.

