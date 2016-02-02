-module(epush_client).

-behaviour(gen_server).

-include("epush.hrl").

-include("epush_protocol.hrl").

-include("epush_internal.hrl").

%% API Function Exports
-export([start_link/2,start_link/1,kick/1]).



%% gen_server Function Exports
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  code_change/3, terminate/2]).

%% Client State
-record(client_state,
  {connection,
    connname,
    await_recv,
    conn_state,
    rate_limit,
    parser_fun,
    pktid = 1,
    proto_state,  %%protocol相关的信息 例如clientId
    packet_opts,
    keepalive     %%用的是epush_keepalive, 初始化的后,指定时间间隔发送{keepalive,check}消息,处理时调用epush_keepalive的check,判断的是前后两次检查,inet的接收字节数是否发生变化
  }).

%-define(INFO_KEYS, [peername, peerhost, peerport, await_recv, conn_state]).

-define(SOCK_STATS, [recv_oct, recv_cnt, send_oct, send_cnt]).

-define(LOG(Level, Format, Args, State),
  lager:Level("Client(~s): " ++ Format, [State#client_state.connname | Args])).

start_link(Connection) ->
  start_link(Connection,[{client,[]},{packet,[]}]).

start_link(Connection, MqttEnv) -> %Connection是连接,对应esockd_connection
  io:format("connect arrival ~p~n",[Connection]),
  {ok, proc_lib:spawn_link(?MODULE, init, [[Connection, MqttEnv]])}.

kick(CPid) ->
  gen_server:call(CPid, kick).

init([OriginConn, MqttEnv]) ->
  {ok, Connection} = OriginConn:wait(),%% 这个wait是必须调用的,在wait之前,连接系统需要处理定义的socket连接,新的Connection可能是具有ssl
  {_PeerHost, _PeerPort, PeerName} =%获取到{IP,port,{ip,port}}
  case Connection:peername() of
    {ok, Peer = {Host, Port}} ->
      {Host, Port, Peer};
    {error, enotconn} ->
      Connection:fast_close(),
      exit(normal);
    {error, Reason} ->
      Connection:fast_close(),
      exit({shutdown, Reason})
  end,
  ConnName = esockd_net:format(PeerName),%%connName是可读的ip地址
  SendFun = fun(Data) ->%%sendFun直接使用了esockd_connection下的async_send
    try Connection:async_send(Data) of
      true -> ok
    catch
      error:Error -> exit({shutdown, Error})
    end
            end,
  PktOpts = proplists:get_value(packet, MqttEnv),
  ParserFun = epush_parser:new(PktOpts),%%创建parser %这个参数只获取了长度max_packet_size限制
  ProtoState = epush_protocol:init(PeerName, SendFun, PktOpts),%%取了两个属性max_clientid_len和ws_initial_headers
  RateLimit = proplists:get_value(rate_limit, Connection:opts()),%%速度限制
  State = run_socket(#client_state{connection   = Connection,%执行这个就开始接收数据了,但只接收一次
    connname     = ConnName,
    await_recv   = false, %% await_recv false 表示可以继续接收来自网络的数据,true为暂停接收,等待已经接收的数据处理完成
    conn_state   = running,%% conn_state running 正在运行,block用于速度调整(限速)
    rate_limit   = RateLimit,
    parser_fun   = ParserFun,
    proto_state  = ProtoState,%%mqtt相关的属性
    packet_opts  = PktOpts}),
  ClientOpts = proplists:get_value(client, MqttEnv),
  IdleTimout = proplists:get_value(idle_timeout, ClientOpts, 10),%%ideal时间
  gen_server:enter_loop(?MODULE, [], State, timer:seconds(IdleTimout)).


handle_call(kick, _From, State) ->
  {stop, {shutdown, kick}, ok, State};

handle_call(Req, _From, State) ->
  ?UNEXPECTED_REQ(Req, State).

handle_cast(Msg, State) ->
  ?UNEXPECTED_MSG(Msg, State).

handle_info(timeout, State) ->%%超时关闭
  shutdown(idle_timeout, State);

%% 发送消息
handle_info({deliver, Message}, State) ->
  with_proto_state(fun(ProtoState) ->
    epush_protocol:send(Message, ProtoState)%里面会调用sendFun
                   end, State);

handle_info({sync,Channel},State=#client_state{proto_state = ProtoState}) ->%% 来自于服务端有新消息到来时调用的sync
  lager:info("sync message arrival ~p ~n",[Channel]),
  epush_protocol:send_sync({sync,Channel},ProtoState),
  hibernate(State);

handle_info({mssage,Channel,OTag,NTag,Body},State=#client_state{proto_state = ProtoState}) ->%%来自于服务端的消息发送
  NProtoState = epush_protocol:send_message({message,Channel,OTag,NTag,Body},ProtoState),
  hibernate(State#client_state{proto_state = NProtoState});

handle_info({timeout, awaiting_ack, {Ch,Tag}},State = #client_state{proto_state = ProtoState}) ->%%来自于timer
  case epush_protocol:resend_message({Ch,Tag},ProtoState) of
    {ok,NProtoState} ->
      hibernate(State#client_state{proto_state = NProtoState});
    {error,Reason} ->%%重试次数过多,直接断开连接
      shutdown(Reason,State)
  end;

handle_info({shutdown, conflict, {ClientId, NewPid}}, State) ->
  ?LOG(warning, "clientid '~s' conflict with ~p", [ClientId, NewPid], State),
  shutdown(conflict, State);

%%来自于rateLimit
handle_info(activate_sock, State) ->%源自于限速
  hibernate(run_socket(State#client_state{conn_state = running}));

%%接收数据,来自于prim_net
handle_info({inet_async, _Sock, _Ref, {ok, Data}}, State) ->%接收到数据
  Size = size(Data),
  ?LOG(debug, "RECV ~p", [Data], State),
  %%先验证速率是否已经超了,如果超时了,就要计算下次接收消息的时间,一段时间后,才能触发接收下一个消息
  received(Data, rate_limit(Size, State#client_state{await_recv = false}));

%%连接错误关闭
handle_info({inet_async, _Sock, _Ref, {error, Reason}}, State) ->%连接错误
  shutdown(Reason, State);

%%这个消息来源于 erlang将消息发送到操作系统tcp队列后,返回的确认消息,不需要特别处理,如果发送失败,就关闭连接
handle_info({inet_reply, _Sock, ok}, State) ->%发送成功后返回的消息(消息推送到操作系统)
  hibernate(State);%发送成功后 让程序休眠

handle_info({inet_reply, _Sock, {error, Reason}}, State) ->%发送失败后推送的消息
  shutdown(Reason, State);

%%启动心跳计时器
handle_info({keepalive, start, Interval}, State = #client_state{connection = Connection}) ->
  ?LOG(debug, "Keepalive at the interval of ~p", [Interval], State),
  StatFun = fun() ->%统计接口,用于获取已经接收的字节数
    case Connection:getstat([recv_oct]) of
      {ok, [{recv_oct, RecvOct}]} -> {ok, RecvOct};
      {error, Error}              -> {error, Error}
    end
            end,
  KeepAlive = epush_keepalive:start(StatFun, Interval, {keepalive, check}),
  hibernate(State#client_state{keepalive = KeepAlive});

%%验证心跳是否过期,消息来源于epush_keepalive的定时任务
handle_info({keepalive, check}, State = #client_state{keepalive = KeepAlive}) ->
  case epush_keepalive:check(KeepAlive) of
    {ok, KeepAlive1} ->
      hibernate(State#client_state{keepalive = KeepAlive1});
    {error, timeout} ->
      ?LOG(debug, "Keepalive timeout", [], State),
      shutdown(keepalive_timeout, State);
    {error, Error} ->
      ?LOG(warning, "Keepalive error - ~p", [Error], State),
      shutdown(Error, State)
  end;



handle_info(Info, State) ->
  ?UNEXPECTED_INFO(Info, State).

%%连接关闭,需要取消心跳,如果clientId非空,需要注销
terminate(Reason, #client_state{connection  = Connection,
  keepalive   = KeepAlive,
  proto_state = ProtoState}) ->
  Connection:fast_close(),
  epush_keepalive:cancel(KeepAlive),
  case {ProtoState, Reason} of
    {undefined, _} ->
      ok;
    {_, {shutdown, Error}} ->
      epush_protocol:shutdown(Error, ProtoState);
    {_, Reason} ->
      epush_protocol:shutdown(Reason, ProtoState)
  end.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

with_proto_state(Fun, State = #client_state{proto_state = ProtoState}) ->
  {ok, ProtoState1} = Fun(ProtoState),
  hibernate(State#client_state{proto_state = ProtoState1}).


%% Receive and parse tcp data
received(<<>>, State) ->%接收到空数据,直接睡眠
  hibernate(State);

received(Bytes, State = #client_state{parser_fun  = ParserFun,
  packet_opts = PacketOpts,
  proto_state = ProtoState}) ->
  case catch ParserFun(Bytes) of%%分析mqtt消息体
    {more, NewParser}  ->%cps模式,continue,需要读取更多的数据
      noreply(run_socket(State#client_state{parser_fun = NewParser}));%%如果接收到的消息未达到一个完整的消息,应该是直接返回,调用run_socket似乎没什么意义,因为这时候await那个量为true
    {ok, Packet, Rest} ->
      case epush_protocol:received(Packet, ProtoState) of%成功接收到一个mqtt消息,用协议的方式处理这条消息
        {ok, ProtoState1} ->
          received(Rest, State#client_state{parser_fun = epush_parser:new(PacketOpts),
            proto_state = ProtoState1});%继续接受下一个消息(或者剩余的binary)
        {error, Error} ->
          ?LOG(error, "Protocol error - ~p", [Error], State),
          shutdown(Error, State);
        {error, Error, ProtoState1} ->
          shutdown(Error, State#client_state{proto_state = ProtoState1});
        {stop, Reason, ProtoState1} ->
          stop(Reason, State#client_state{proto_state = ProtoState1})
      end;
    {error, Error} ->
      ?LOG(error, "Framing error - ~p", [Error], State),
      shutdown(Error, State);
    {'EXIT', Reason} ->
      ?LOG(error, "Parser failed for ~p", [Reason], State),
      ?LOG(error, "Error data: ~p", [Bytes], State),
      shutdown(parser_error, State)
  end.



rate_limit(_Size, State = #client_state{rate_limit = undefined}) ->
  run_socket(State);
rate_limit(Size, State = #client_state{rate_limit = Rl}) ->
  case Rl:check(Size) of
    {0, Rl1} ->
      run_socket(State#client_state{conn_state = running, rate_limit = Rl1});
    {Pause, Rl1} ->
      ?LOG(error, "Rate limiter pause for ~p", [Pause], State),
      erlang:send_after(Pause, self(), activate_sock),%%对应那个handle_info
      State#client_state{conn_state = blocked, rate_limit = Rl1}
  end.


%%接收一次网络数据, 如果是blocked,是限速原因,需要阻塞一段时间,阻塞超时后,计时器会发送{active_socket}来激活
run_socket(State = #client_state{conn_state = blocked}) ->
  State;
%%await_recv相当于一个锁,接收了一次tcp消息后,设置为true,直到这一次被处理完成才设置成false
run_socket(State = #client_state{await_recv = true}) ->
  State;
%%接收一次消息
run_socket(State = #client_state{connection = Connection}) ->
  Connection:async_recv(0, infinity),
  State#client_state{await_recv = true}.

noreply(State) ->
  {noreply, State}.

hibernate(State) ->
  {noreply, State, hibernate}.

shutdown(Reason, State) ->
  stop({shutdown, Reason}, State).

stop(Reason, State) ->
  {stop, Reason, State}.
