%%%-----------------------------------------------------------------------------
%%% @author 0xAX <anotherworldofworld@gmail.com>, cleverfox <dev@viruzzz.org>
%%% @doc
%%% Xmpp client with ssl support.
%%% @end
%%%-----------------------------------------------------------------------------
-module(xmpp_client).

-behaviour(gen_server).

-include("xmpp.hrl").
-include_lib("xmerl/include/xmerl.hrl").

-export([start_link/3,start_link/4]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% @doc Xmpp client internal state
-record (state, {
        % Xmpp client socket
        socket = null,
        % Is auth state or not
        is_auth = false,
        % client callback module or pid
        callback,
        % Xmpp client login
        login,
        % Xmpp client password
        password,
        % jabber server host
        host,
        % Jabber room
        room,
        % Nick in jabber room
        nick,
        % Client resource
        resource,
        % Xmpp server port
        port = 5222,
        % socket mode
        socket_mod = null,
        % reconnect timeout
        reconnect_timeout = 0,
        % is_authorizated
        success = false,
        cur_mod = gen_tcp
    }).

%%%=============================================================================
%%% API
%%%=============================================================================

start_link(CallbackModule, Login, Password) ->
    start_link(CallbackModule, Login, Password,[]).
start_link(CallbackModule, Login, Password, Options) when is_list(Options) ->
    gen_server:start_link(?MODULE, [CallbackModule, Login, Password, Options], []).

%%%=============================================================================
%%% xmpp_client callbacks
%%%=============================================================================

init([CallbackModule, Login, Password, Options ]) ->
    % try to connect
    gen_server:cast(self(), connect),
    % init process internal state
    [Nick, Server] = binary:split(Login,<<"@">>),
    SocketMode=proplists:get_value(port, Options, tls),
    {ok, #state{
            callback = CallbackModule,
            login = Login,
            password = Password,
            host = proplists:get_value(server, Options, Server),
            room = proplists:get_value(room, Options, undefined),
            nick = proplists:get_value(nick, Options, Nick),
            resource = proplists:get_value(resource, Options, <<"yxmpp">>),
            port = proplists:get_value(port, Options, 5222),
            socket_mod = SocketMode,
            reconnect_timeout = proplists:get_value(reconnect_timeout, Options, 5000),
            cur_mod = case SocketMode of
                          ssl -> ssl;
                          gen_tcp -> gen_tcp;
                          tls -> gen_tcp
                      end
           }
    }.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

%% @doc connect to jabber server
handle_cast(connect, #state{host = Host, port = Port} = State) ->
    % Connection options
    Options = case State#state.socket_mod of
                             ssl -> 
                                 [list, {verify, 0}];
                             gen_tcp -> 
                                 [list];
                             tls -> 
                                 [list]
                         end,
    % connect
    case (State#state.cur_mod):connect(binary_to_list(Host), Port, Options) of
        {ok, Socket} ->
            neg_session(Socket, State) ;
        {error, Reason} ->
            % Some log
            lager:error("Unable to connect to xmpp server with reason ~p", [Reason]),
            % try to reconnect
            try_reconnect(State)
    end;

%% @doc send message to jabber
handle_cast({send_message, From, Message}, State) ->
    % Check private or public message
    case From of
        % this is public message
        "" ->
            % Make room
            [Room | _] = string:tokens(binary_to_list(State#state.room), "/"),
            % send message to jabber
            (State#state.cur_mod):send(State#state.socket, xmpp_xml:message(Room, Message));
        _ ->
            % send message to jabber
            (State#state.cur_mod):send(State#state.socket, xmpp_xml:private_message(From, Message))
    end,
    
    % return
    {noreply, State};

handle_cast({status, Type, Message}, State) ->
    Msg=xmpp_xml:presence_msg(Type, Message),
    (State#state.cur_mod):send(State#state.socket, Msg),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({ssl_closed, Reason}, State) ->
    % Some log
    lager:info("ssl_closed with reason: ~p~n", [Reason]),
    % try reconnect
    try_reconnect(State);

handle_info({ssl_error, _Socket, Reason}, State) ->
    % Some log
    lager:error("tcp_error: ~p~n", [Reason]),
    % try reconnect
    try_reconnect(State);

handle_info({tcp_closed, Reason}, State) ->
    % Some log
    lager:info("tcp_closed with reason: ~p~n", [Reason]),
    % try reconnect
    try_reconnect(State);

handle_info({tcp_error, _Socket, Reason}, State) ->
    % Some log
    lager:error("tcp_error: ~p~n", [Reason]),
    % try reconnect
    try_reconnect(State);

%% handle chat message
handle_info({_, _, "<message " ++ Rest}, State) ->
    % parse xml
    case xmerl_scan:string("<message " ++ Rest) of
        [] ->
            {noreply, State};
        {Xml, _} ->
            % Try to catch incoming xmpp message and send it to hander
            ok = is_xmpp_message(Xml, State#state.callback),
            % return
            {noreply, State}
    end;

%% @doc Handle incoming XMPP message
handle_info({_, _Socket, Data}, State) ->
    lager:debug("recv ~p ~p",[self(),Data]),
    case State#state.success of
        true ->
%            try 
%                case xmerl_scan:string(Data) of
%                    {Element1,_Rest} ->
%                        case element(2,Element1) of
%                            presence -> 
%                                lager:info("presence ~p",[element(8,Element1)]),
%                                ok;
%                            _ -> ok
%                        end;
%                    _ -> ok
%                end,
%                {noreply, State}
%            catch _:_ ->
                      {noreply, State};
%            end;
        false ->
            case parse_data(Data) of
                success ->
                    % make xmpp stream string
                    NewStream = lists:last(string:tokens(binary_to_list(State#state.login), "@")),
                    % create new stream
                    (State#state.cur_mod):send(State#state.socket, ?STREAM(NewStream)),
                    % bind resource
                    (State#state.cur_mod):send(State#state.socket, xmpp_xml:bind(binary_to_list(State#state.resource))),
                    % create session
                    (State#state.cur_mod):send(State#state.socket, xmpp_xml:create_session()),
                    % send presence
                    (State#state.cur_mod):send(State#state.socket, xmpp_xml:presence()),
                    % Join to muc
                    (State#state.cur_mod):send(State#state.socket, xmpp_xml:muc(State#state.room)),
                    % set is_auth = true and return
                    {noreply, State#state{is_auth = true, success = true}};
                ok ->
                    {noreply, State}
            end
    end;

handle_info(_Info, State) ->
    {noreply, State}.

parse_data("<success " ++ _) ->
    success;

parse_data(_) ->
    ok.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%% @doc try reconnect
-spec try_reconnect(State :: #state{}) -> {normal, stop, State} | {noreply, State}.
try_reconnect(#state{reconnect_timeout = Timeout, host = Host, port = Port} = State) ->
    case Timeout > 0 of
        false ->
            % no need in reconnect
            {normal, stop, State};
        true ->
            lager:info("Reconnect"),
            % sleep
            timer:sleep(Timeout),
            % Try reconnect
            gen_server:cast(self(), {connect, Host, Port}),
            % return
            {noreply, State}
    end.

%% @doc Check incomming message type and send it to handler
-spec send_message_to_handler(Xml :: #xmlDocument{}, Callback :: pid(), IncomingMessage :: binary()) -> ok.
send_message_to_handler(Xml, Callback, IncomingMessage) ->
    % Try to get message type
    case xmerl_xpath:string("/message/@type", Xml) of
        % this is group-chat
        [{_,_,_,_, _, _, _, _,"groupchat", _}] ->
            % Send public message to callback
            Callback ! {incoming_message, "", IncomingMessage};
            % This is private message
        [{_,_,_,_, _, _, _, _,"chat", _}] ->
            % Get From parameter
            [{_,_,_,_, _, _, _, _, From, _}] = xmerl_xpath:string("/message/@from", Xml),
            % Send private message to callback
            lager:debug("~p Got msg from ~p: ~p",[self(),From,IncomingMessage]),
            Callback ! {incoming_message, From, IncomingMessage}
    end,
    % return
    ok.

%% @doc Check is it incoming message
-spec is_xmpp_message(Xml :: #xmlDocument{}, Callback :: pid()) -> ok.
is_xmpp_message(Xml, Callback) ->
    case xmerl_xpath:string("/message", Xml) of
        [] ->
            % this is not xmpp message. do nothing
            pass;
        _ ->
            % Get message body
            case xmerl_xpath:string("/message/body/text()", Xml) of
                [{xmlText, _, _, _, IncomingMessage, text}] ->
                    % Check message type and send it to handler
                    ok = send_message_to_handler(Xml, Callback, IncomingMessage);
                _ ->
                    error
            end
    end,
    ok.
neg_session(Socket, State) ->
    % Get new stream
    case State#state.cur_mod of
        gen_tcp ->
            inet:setopts(Socket, [{active, false}]);
        ssl ->
            ssl:setopts(Socket, [{active, false}])
    end,
    NewStream = lists:last(string:tokens(binary_to_list(State#state.login), "@")),
    % handshake with jabber server
    (State#state.cur_mod):send(Socket, ?STREAM(NewStream)),
    D1=(State#state.cur_mod):recv(Socket,0),
    D2=(State#state.cur_mod):recv(Socket,0),
    lager:debug("Recv ~p",[D1]),
    lager:debug("Recv ~p",[D2]),
    % Format login/password
    case {State#state.socket_mod,State#state.cur_mod} of
        {tls, gen_tcp} -> 
            (State#state.cur_mod):send(Socket, 
                                       <<"<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls' />">>
                                      ),
            DC=(State#state.cur_mod):recv(Socket,0),
            lager:debug("Recv ~p",[DC]),
            case ssl:connect(Socket,[{verify,0}],1000) of
                {ok, NewFD}  ->
                    ssl:setopts(NewFD, [{active, true}]),
                    neg_session(NewFD, State#state{cur_mod=ssl});
                {error, Error} ->
                    throw({'cant_start_tls',Error})
            end;
        {_, ssl} -> 
            ssl:setopts(Socket, [{active, true}]),
            Auth = binary_to_list(base64:encode("\0" ++ binary_to_list(State#state.login) ++ "\0" ++ binary_to_list(State#state.password))),
            % Send authorization (PLAIN method)
            (State#state.cur_mod):send(Socket, xmpp_xml:auth_plain(Auth)),
            % init
            {noreply, State#state{socket = Socket}};
        {_, gen_tcp} -> 
            inet:setopts(Socket, [{active, true}]),
            Auth = binary_to_list(base64:encode("\0" ++ binary_to_list(State#state.login) ++ "\0" ++ binary_to_list(State#state.password))),
            % Send authorization (PLAIN method)
            (State#state.cur_mod):send(Socket, xmpp_xml:auth_plain(Auth)),
            % init
            {noreply, State#state{socket = Socket}}
    end.
