-module(epush_protocol).

%% API
-export([]).
-include("epush.hrl").

-include("epush_protocol.hrl").

-include("epush_internal.hrl").

-include("epush_mq.hrl").

%% API
-export([init/3, info/1, clientid/1, client/1, session/1]).

-export([received/2, send/2, redeliver/2, shutdown/2]).

-export([process/2,send_message/2,send_sync/2,resend_message/2,channel/1]).

%% Protocol State
-record(proto_state, {peername, sendfun, connected = false,
  client_id, client_pid, clean_sess,
  proto_ver, proto_name, username,
  will_msg, keepalive, max_clientid_len = ?MAX_CLIENTID_LEN,
  session, ws_initial_headers, %% Headers from first HTTP request for websocket client
  connected_at,authored = false,password,channels,awaiting_rel,timeout=240,flights=maps:new()}).

-type proto_state() :: #proto_state{}.

-define(INFO_KEYS, [client_id, username, clean_sess, proto_ver, proto_name,
  keepalive, will_msg, ws_initial_headers, connected_at]).

-define(LOG(Level, Format, Args, State),
  lager:Level([{client, State#proto_state.client_id}], "Client(~s@~s): " ++ Format,
    [State#proto_state.client_id, esockd_net:format(State#proto_state.peername) | Args])).

-define(TOPIC(Packet),Packet#mqtt_packet.variable#mqtt_packet_publish.topic_name).

%%------------------------------------------------------------------------------
%% @doc Init protocol
%% @end
%%------------------------------------------------------------------------------
init(Peername, SendFun, Opts) ->%%初始化
  MaxLen = epush_opts:g(max_clientid_len, Opts, ?MAX_CLIENTID_LEN),
  WsInitialHeaders = epush_opts:g(ws_initial_headers, Opts),
  #proto_state{peername           = Peername,
    sendfun            = SendFun,
    max_clientid_len   = MaxLen,
    client_pid         = self(),
    ws_initial_headers = WsInitialHeaders}.

info(ProtoState) ->%%获取对应的info
  ?record_to_proplist(proto_state, ProtoState, ?INFO_KEYS).

clientid(#proto_state{client_id = ClientId}) ->%%获取clientId
  ClientId.

%%计算will topic,返回mqtt_client, mqtt_client与proto_state只差一个willMsg
client(#proto_state{client_id          = ClientId,
  client_pid         = ClientPid,
  peername           = Peername,
  username           = Username,
  clean_sess         = CleanSess,
  proto_ver          = ProtoVer,
  keepalive          = Keepalive,
  will_msg           = WillMsg,
  ws_initial_headers = WsInitialHeaders,
  connected_at       = Time}) ->
  WillTopic = if
                WillMsg =:= undefined -> undefined;
                true -> WillMsg#mqtt_message.topic
              end,
  #mqtt_client{client_id          = ClientId,
    client_pid         = ClientPid,
    username           = Username,
    peername           = Peername,
    clean_sess         = CleanSess,
    proto_ver          = ProtoVer,
    keepalive          = Keepalive,
    will_topic         = WillTopic,
    ws_initial_headers = WsInitialHeaders,
    connected_at       = Time}.

session(#proto_state{session = Session}) ->
  Session.

%% CONNECT – Client requests a connection to a Server

%% A Client can only send the CONNECT Packet once over a Network Connection.
-spec received(mqtt_packet(), proto_state()) -> {ok, proto_state()} | {error, any()}.
received(Packet = ?PACKET(?CONNECT), State = #proto_state{connected = false}) ->%如果是尚未连接的一个连接请求,那么需要处理
  process(Packet, State#proto_state{connected = true});

received(?PACKET(?CONNECT), State = #proto_state{connected = true}) ->%如果已经接收过连接请求,新的连接请求就是错误的,拒绝请求
  {error, protocol_bad_connect, State};

%% Received other packets when CONNECT not arrived.
received(_Packet, State = #proto_state{connected = false}) ->%如果没有处理连接请求,那么拒绝处理其它请求
  {error, protocol_not_connected, State};

received(Packet = ?PACKET(_Type), State) ->%其它类型的消息
  trace(recv, Packet, State),
  process(Packet, State).

%%处理连接消息
process(Packet = ?CONNECT_PACKET(Var), State0) ->

  io:format("var is ~p~n",[Var]),
  #mqtt_packet_connect{proto_ver  = ProtoVer,
    proto_name = ProtoName,
    username   = Username,
    password   = Password,
    clean_sess = CleanSess,
    keep_alive = KeepAlive,
    will_topic = WillTopic,
    client_id  = ClientId} = Var,

  State1 = State0#proto_state{proto_ver  = ProtoVer,
    proto_name = ProtoName,
    username   = Username,
    client_id  = ClientId,
    clean_sess = CleanSess,
    keepalive  = KeepAlive,
    connected_at = os:timestamp()},

  trace(recv, Packet, State1),

  {ReturnCode1, SessPresent, State3} =
    case validate_connect(Var, State1) of
      ?CONNACK_ACCEPT ->
        %% Generate clientId if null
        State2 = maybe_set_clientid(State1),%%如果clientId是空,那么生成id,State2与State1比最多差clientId
        Channels = channel(WillTopic),%%计算channel
        epush_rabbit:sendMsg(#login{username = Username,password = Password,pid = self(),clientId = ClientId,channel = Channels}),
        start_keepalive(KeepAlive),
        %% ACCEPT
        {?CONNACK_ACCEPT, true, State2#proto_state{channels = Channels}};
        %%end;
      ReturnCode ->
        {ReturnCode, false, State1}
    end,
  send(?CONNACK_PACKET(ReturnCode1, sp(SessPresent)), State3);%%调用mqtt_packet

process(Packet = ?PUBLISH_PACKET(Qos, _Topic, _PacketId, _Payload), State) ->
  if Qos =:= 0 ->
      publishQos0(Packet,State);
    Qos =:= 1 ->
      publishQos1(Packet,State)
  end;

process(?PUBACK_PACKET(?PUBACK, _PacketId), State = #proto_state{session = _Session}) ->
  %% do nothing
  {ok, State};

process(?PUBACK_PACKET(?PUBREC, _PacketId), State = #proto_state{session = _Session}) ->
  %% do nothing
  {ok,State};

process(?PUBACK_PACKET(?PUBREL, _PacketId), State = #proto_state{session = _Session}) ->
  %% do nothing
  {ok,State};


process(?PUBACK_PACKET(?PUBCOMP, _PacketId), State = #proto_state{session = _Session})->
  %% do nothing
  {ok, State};


%% Protect from empty topic table
process(?SUBSCRIBE_PACKET(_PacketId, []), State) ->
  %% do nothing
  {ok,State};

process(?SUBSCRIBE_PACKET(_PacketId, _TopicTable), State = #proto_state{session = _Session}) ->
  {ok,State};%%nothing

%% Protect from empty topic list
process(?UNSUBSCRIBE_PACKET(_PacketId, []), State) ->
  {ok,State}; %%nothing

process(?UNSUBSCRIBE_PACKET(_PacketId, _Topics), State = #proto_state{session = _Session}) ->
  {ok,State}; %%nothing

process(?PACKET(?PINGREQ), State) ->
  send(?PACKET(?PINGRESP), State);

process(?PACKET(?DISCONNECT), State) ->
  % Clean willmsg
  {stop, normal, State#proto_state{will_msg = undefined}}.

%% qos0的消息,这里被当作ack的消息
publishQos0(Packet = ?PUBLISH_PACKET(?QOS_0, _PacketId),
    State = #proto_state{client_id = _ClientId, channels = Channels,username = UserName,flights = Flights,awaiting_rel = AwaitRel}) ->%%客户端上行的Qos0消息,实际上是ack消息
  {Ch,Tag} = topic_channel(?TOPIC(Packet)),%%通过分析topic,获取ack消息的信息(消息由两部分组成,ch+tag,中间用逗号隔开
  case maps:find(Ch,Flights) of %% 先要找到指定的flight消息
    {ok,{FTag,_Msg,_Cnt}} ->
      if Tag =:= FTag ->%% flight消息与ack的消息一致,说明响应的就是这条消息
        maps:remove(Ch,Flights),%% 删除flight消息
        NewAwaitRel = cancel_retry(Ch,AwaitRel),%% 删除Retry消息
        NewChannels = update_channel(Ch,Tag,Channels),%% 更新channel的tag值
        epush_rabbit:sendMsg(#sync{channel = Ch,syncTag = Tag, username = UserName, pid = self()}),
        {ok,State#proto_state{channels = NewChannels,awaiting_rel = NewAwaitRel}};
        true ->%% 否则响应的不适这条消息,直接丢弃
          {ok,State}
      end;
    error ->
      {ok,State}
  end.




publishQos1(Packet = ?PUBLISH_PACKET(?QOS_1, _PacketId), State) ->%%客户端上行Qos1消息,实际是客户想发送的消息
    epush_rabbit:sendMsg(
      #pub{
        message = Packet#mqtt_packet.payload,
        username = State#proto_state.username,
        password = State#proto_state.password,
        pid = self(),
        channel = ?TOPIC(Packet)}),%%publish 消息
  with_puback(?PUBACK, Packet, State).

with_puback(Type,?PUBLISH_PACKET(_Qos, PacketId), State) ->
  send(?PUBACK_PACKET(Type, PacketId), State),
  {ok,State}.

-spec send(mqtt_message() | mqtt_packet(), proto_state()) -> {ok, proto_state()}.
send(Msg, State) when is_record(Msg, mqtt_message) ->
  send(epush_message:to_packet(Msg), State);

send(Packet, State = #proto_state{sendfun = SendFun})%%接收的是mqtt_packet
  when is_record(Packet, mqtt_packet) ->
  trace(send, Packet, State),
  Data = epush_serializer:serialize(Packet),%变成binary
  ?LOG(debug, "SEND ~p", [Data], State),
  SendFun(Data),%发送数据
  {ok, State}.

trace(recv, Packet, ProtoState) ->
  ?LOG(info, "RECV ~s", [epush_packet:format(Packet)], ProtoState);

trace(send, Packet, ProtoState) ->
  ?LOG(info, "SEND ~s", [epush_packet:format(Packet)], ProtoState).

%% @doc redeliver PUBREL PacketId
redeliver({?PUBREL, PacketId}, State) ->
  send(?PUBREL_PACKET(PacketId), State).


%% 如果clientId是空的,那么就忽略,否则要取消注册
shutdown(_Error, #proto_state{client_id = undefined}) ->
  ignore;

shutdown(_Other, #proto_state{username = Username,client_id = ClientId}) ->
  epush_rabbit:sendMsg(#logout{username = Username, pid = self(), clientId = ClientId}),%%unregister
  ignore.

%% Generate a client if if nulll
maybe_set_clientid(State = #proto_state{client_id = NullId})
  when NullId =:= undefined orelse NullId =:= <<>> ->
  {_, NPid, _} = epush_guid:new(),%如果clientId是空,那么生成一个ObjectId(与mongodb的id生成策略相似)
  ClientId = iolist_to_binary(["epush_", integer_to_list(NPid)]),
  State#proto_state{client_id = ClientId};

maybe_set_clientid(State) ->
  State.

start_keepalive(0) -> ignore;

start_keepalive(Sec) when Sec > 0 ->
  self() ! {keepalive, start, round(Sec * 1.2)}.

%%----------------------------------------------------------------------------
%% Validate Packets
%%----------------------------------------------------------------------------
validate_connect(Connect = #mqtt_packet_connect{}, ProtoState) ->%%验证mqtt的版本和clientId的长度
  case validate_protocol(Connect) of
    true ->
      case validate_clientid(Connect, ProtoState) of
        true ->
          ?CONNACK_ACCEPT;
        false ->
          ?CONNACK_INVALID_ID
      end;
    false ->
      ?CONNACK_PROTO_VER
  end.

validate_protocol(#mqtt_packet_connect{proto_ver = Ver, proto_name = Name}) ->%验证mqtt版本
  lists:member({Ver, Name}, ?PROTOCOL_NAMES).

validate_clientid(#mqtt_packet_connect{client_id = ClientId},%验证clientId的长度
    #proto_state{max_clientid_len = MaxLen})
  when (size(ClientId) >= 1) andalso (size(ClientId) =< MaxLen) ->
  true;

%% MQTT3.1.1 allow null clientId.
validate_clientid(#mqtt_packet_connect{proto_ver =?MQTT_PROTO_V311,
  client_id = ClientId}, _ProtoState)
  when size(ClientId) =:= 0 ->
  true;

validate_clientid(#mqtt_packet_connect{proto_ver  = ProtoVer,
  clean_sess = CleanSess}, ProtoState) ->
  ?LOG(warning, "Invalid clientId. ProtoVer: ~p, CleanSess: ~s",
    [ProtoVer, CleanSess], ProtoState),
  false.

%%通过willMessage获取Channel信息
channel(TopicStr) ->
  if TopicStr =:= undefined orelse TopicStr =:= <<>> ->
    undefined;
    true ->
      lists:foldl(
        fun(Topic,AccIn) ->
          [ChannelName,SyncTag] = binary:split(Topic,<<",">>),
          maps:put(ChannelName,SyncTag,AccIn)
        end,maps:new(),binary:split(TopicStr,<<";">>)
      )
  end.

topic_channel(Topic) ->
  if Topic =:= undefined orelse Topic =:= <<>> ->
    undefined;
     true ->
      try
        [ChannelName,SyncTag] = string:tokens(Topic,","),
        {ChannelName,SyncTag}
      catch
        _:_ -> {Topic,undefined}
      end

  end.

%%如果来了一条消息,仅当
check_channel(Ch,OTag,Channels,Flights) ->
  case maps:find(Ch,Flights) of%% 如果对应channel上仍然有消息没有发送成功,那么丢弃当前消息
    {ok,_} ->
      false;
    error ->
      case maps:find(Ch,Channels) of%% 如果对应channel上没有消息,并且当前消息的tag与传入的Tag相等,那么验证通过,发送消息
        {ok,CurrTag} ->
          if CurrTag =:= OTag ->%%
            true;
            true ->
              false
          end
      end
  end.

send_sync({sync,Channel},#proto_state{channels = Channels,username = UserName,flights = Flights}) ->
  case maps:find(Channel,Flights) of
    {ok,_} ->%%如果通道上,还有消息未发送成功,那么忽略当前sync
      ignore;
    error ->%%如果通道上没有消息,那么可以发送sync
      case maps:find(Channel,Channels) of
        {ok,Tag} ->%% 如果当前session有这个channel,那么直接返回响应的tag
          epush_rabbit:sendMsg(#sync{channel = Channel,syncTag = Tag,pid = self(),username = UserName});
        error ->%% 如果当前session没有这个channel,那么tag返回的是undefined
          epush_rabbit:sendMsg(#sync{channel = Channel,syncTag = undefined,pid=self(),username = UserName})
      end
  end.


send_message({message,Channel,OTag,NTag,Body},ProtoState=#proto_state{channels = Channels,awaiting_rel = AwaitRel,timeout = Timeout,flights = Flights}) ->
  case check_channel(Channel,OTag,Channels,Flights) of%看看通道上是否有消息,如果没有消息才能发送
    true ->
      Msg = #mqtt_message{topic = Channel,payload = Body,qos = 0,dup = false},%创建消息
      TRef = timer(Timeout,{timeout,awaiting_ack,{Channel,NTag}}),%设定重新尝试的时间
      AwaitRel1 = maps:put(Channel,{TRef,NTag},AwaitRel),
      self() ! {deliver,Msg},%发送消息
      ProtoState#proto_state{awaiting_rel = AwaitRel1,flights = maps:put(Channel,{NTag,Msg,1})};
    _ ->
      ProtoState
  end.



resend_message({Ch,Tag},ProtoState=#proto_state{flights = Flights,awaiting_rel = AwaitRel,timeout = Timeout}) ->
 case maps:find(ch,AwaitRel) of
   {ok,{_Ref,Tag}} ->%% 先删除await
     maps:remove(ch,AwaitRel);
   _ ->
     ok
 end,
  case maps:find(ch,Flights) of
    {Tag,Msg,1} ->%% 找到对应的消息
      TRef = timer(Timeout,{timeout,awaiting_ack,{Ch,Tag}}),%设定重新尝试的时间
      AwaitRel1 = maps:put(Ch,{TRef,Tag},AwaitRel),
      self() ! {deliver,Msg},%发送消息
      {ok,ProtoState#proto_state{awaiting_rel = AwaitRel1,flights = maps:put(Ch,{Tag,Msg,2})}};
    _ ->
      {error,retry_send_error}%%重发次数过多,直接断开连接
  end.

cancel_retry(Ch,AwaitRel) ->
  case maps:find(Ch,AwaitRel) of
    {ok,TRef} ->
      cancel_timer(TRef),
      maps:remove(Ch,AwaitRel);
    error ->
      AwaitRel
  end.

cancel_timer(undefined) ->
  undefined;
cancel_timer(Ref) ->
    catch erlang:cancel_timer(Ref).

update_channel(Ch,Tag,Channels) ->
  case maps:is_key(Ch) of
    true ->
      maps:update(Ch,Tag,Channels);
    flase ->
      Channels
  end.


timer(TimeoutSec, TimeoutMsg) ->
  erlang:send_after(timer:seconds(TimeoutSec), self(), TimeoutMsg).

sp(true)  -> 1;
sp(false) -> 0.