%%%-------------------------------------------------------------------
%%% @author guanxinquan
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 25. 一月 2016 下午4:46
%%%-------------------------------------------------------------------
-author("guanxinquan").

-define(PROTOCOL_VERSION, "MQTT/3.1.1").

-define(ERTS_MINIMUM, "6.0").

%% System Topics.
-define(SYSTOP, <<"$SYS">>).

%% Queue Topics.
-define(QTop, <<"$Q">>).

%%------------------------------------------------------------------------------
%% PubSub
%%------------------------------------------------------------------------------
-type pubsub() :: publish | subscribe.

-define(IS_PUBSUB(PS), (PS =:= publish orelse PS =:= subscribe)).

%%------------------------------------------------------------------------------
%% MQTT Topic
%%------------------------------------------------------------------------------
-record(mqtt_topic, {
  topic   :: binary(),
  node    :: node()
}).

-type mqtt_topic() :: #mqtt_topic{}.

%%------------------------------------------------------------------------------
%% MQTT Subscription
%%------------------------------------------------------------------------------
-record(mqtt_subscription, {
  subid   :: binary() | atom(),
  topic   :: binary(),
  qos = 0 :: 0 | 1 | 2
}).

-type mqtt_subscription() :: #mqtt_subscription{}.

%%------------------------------------------------------------------------------
%% MQTT Client
%%------------------------------------------------------------------------------

-type header_key() :: atom() | binary() | string().
-type header_val() :: atom() | binary() | string() | integer().

-record(mqtt_client, {
  client_id     :: binary() | undefined,
  client_pid    :: pid(),
  username      :: binary() | undefined,
  peername      :: {inet:ip_address(), integer()},
  clean_sess    :: boolean(),
  proto_ver     :: 3 | 4,
  keepalive = 0,
  will_topic    :: undefined | binary(),
  ws_initial_headers :: list({header_key(), header_val()}),
  connected_at  :: erlang:timestamp()
}).

-type mqtt_client() :: #mqtt_client{}.

%%------------------------------------------------------------------------------
%% MQTT Session
%%------------------------------------------------------------------------------
-record(mqtt_session, {
  client_id   :: binary(),
  sess_pid    :: pid(),
  persistent  :: boolean()
}).

-type mqtt_session() :: #mqtt_session{}.

%%------------------------------------------------------------------------------
%% MQTT Message
%%------------------------------------------------------------------------------
-type mqtt_msgid() :: binary() | undefined.
-type mqtt_pktid() :: 1..16#ffff | undefined.

-record(mqtt_message, {
  msgid           :: mqtt_msgid(),      %% Global unique message ID
  pktid           :: mqtt_pktid(),      %% PacketId
  topic           :: binary(),          %% Topic that the message is published to
  from            :: binary() | atom(), %% ClientId of publisher
  qos    = 0      :: 0 | 1 | 2,         %% Message QoS
  retain = false  :: boolean(),         %% Retain flag
  dup    = false  :: boolean(),         %% Dup flag
  sys    = false  :: boolean(),         %% $SYS flag
  payload         :: binary(),          %% Payload
  timestamp       :: erlang:timestamp() %% os:timestamp
}).

-type mqtt_message() :: #mqtt_message{}.

%%------------------------------------------------------------------------------
%% MQTT Alarm
%%------------------------------------------------------------------------------
-record(mqtt_alarm, {
  id          :: binary(),
  severity    :: warning | error | critical,
  title       :: iolist() | binary(),
  summary     :: iolist() | binary(),
  timestamp   :: erlang:timestamp() %% Timestamp
}).

-type mqtt_alarm() :: #mqtt_alarm{}.

%%------------------------------------------------------------------------------
%% MQTT Plugin
%%------------------------------------------------------------------------------
-record(mqtt_plugin, {
  name,
  version,
  descr,
  config,
  active = false
}).

-type mqtt_plugin() :: #mqtt_plugin{}.

%%------------------------------------------------------------------------------
%% MQTT CLI Command
%% For example: 'broker metrics'
%%------------------------------------------------------------------------------
-record(mqtt_cli, {
  name,
  action,
  args = [],
  opts = [],
  usage,
  descr
}).

-type mqtt_cli() :: #mqtt_cli{}.