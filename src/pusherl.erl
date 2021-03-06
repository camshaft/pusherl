-module(pusherl).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% api

-export([start/0]).
-export([start_link/0]).
-export([start_link/1]).
-export([start_link/3]).
-export([start_link/4]).
-export([parse_url/1]).
-export([push/3]).
-export([push_async/3]).

%% gen_server

-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

%% internal

-export([http_request/4]).

%% state record

-record(state,{
  app_id,
  key,
  secret,
  host,
  scheme = <<"http">>
}).

%% api

start() ->
  application:start(crypto),
  application:start(pusherl).

start_link() ->
  {ok, AppId} = application:get_env(pusher_app_id),
  {ok, Key} = application:get_env(pusher_key),
  {ok, Secret} = application:get_env(pusher_secret),
  start_link(list_to_binary(AppId), list_to_binary(Key), list_to_binary(Secret)).

start_link(PusherURL) when is_binary(PusherURL) ->
  {AppId, Key, Secret, Host} = parse_url(PusherURL),
  start_link(AppId, Key, Secret, Host).

start_link(AppId, Key, Secret) ->
  start_link(AppId, Key, Secret, <<"api.pusherapp.com">>).

start_link(AppId, Key, Secret, Host) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [AppId, Key, Secret, Host], []).

parse_url(PusherUrl)->
  [_Proto, Rest] = binary:split(PusherUrl, <<"://">>),
  [Key, Rest2] = binary:split(Rest, <<":">>),
  [Secret, Rest3] = binary:split(Rest2, <<"@">>),
  [Host, AppId] = binary:split(Rest3, <<"/apps/">>),
  {AppId, Key, Secret, Host}.

push(ChannelName, EventName, Payload) when is_list(Payload) ->
  EncodedPayload = jsx:encode(Payload),
  push(ChannelName, EventName, EncodedPayload);
push(ChannelName, EventName, Payload) when is_binary(ChannelName), is_binary(EventName), is_binary(Payload) ->
  gen_server:call(?MODULE, {push, {ChannelName, EventName, Payload}}).

push_async(ChannelName, EventName, Payload) when is_list(Payload) ->
  EncodedPayload = jsx:encode(Payload),
  push_async(ChannelName, EventName, EncodedPayload);
push_async(ChannelName, EventName, Payload) when is_binary(ChannelName), is_binary(EventName), is_binary(Payload) ->
  gen_server:cast(?MODULE, {push, {ChannelName, EventName, Payload}}).

%% gen_server

init([AppId, Key, Secret, Host]) ->
  {ok, #state{app_id=AppId, key=Key, secret=Secret, host=Host}}.

handle_call({push, {ChannelName, EventName, Payload}}, _From, State) ->
  case http_request(ChannelName, EventName, Payload, State) of
    ok ->
      {noreply, ok, State};
    Error ->
      {reply, Error, State}
  end;
handle_call(_Request, _From, State) ->
  {noreply, ok, State}.

handle_cast({push, {ChannelName, EventName, Payload}}, State) ->
  http_request(ChannelName, EventName, Payload, State),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% internal

http_request(ChannelName, EventName, Payload, Config) ->
  {ok, Method, URL, Headers, Body} = http_request_props(ChannelName, EventName, Payload, Config),
  {ok, Client} = cowboy_client:init([]),
  {ok, Client2} = cowboy_client:request(Method, URL, Headers, Body, Client),
  case cowboy_client:response(Client2) of
    {ok, 200, _, Client3} ->
      cowboy_client:skip_body(Client3),
      ok;
    {ok, Code, _Headers, Client3} ->
      {ok, Resp, _} = cowboy_client:response_body(Client3),
      {error, Code, Resp}
  end.

http_request_props(ChannelName, EventName, Payload, State) when is_binary(ChannelName) ->
  http_request_props([ChannelName], EventName, Payload, State);
http_request_props(Channels, EventName, Payload, #state{app_id=AppId, key=AppKey, secret=AppSecret, host=Host, scheme=Scheme}) ->
  Method = <<"POST">>,

  Path = <<"/apps/", AppId/binary, "/events">>,

  Body = jsx:encode([
    {<<"name">>, EventName},
    {<<"channels">>, Channels},
    {<<"data">>, Payload}
  ]),

  QS = binary_join([
    <<"auth_key=", AppKey/binary>>,
    <<"auth_timestamp=", (timestamp())/binary>>,
    <<"auth_version=1.0">>,
    <<"body_md5=", (bin_to_hex(crypto:hash(md5, Body)))/binary>>
  ], <<"&">>),

  ToSign = binary_join([Method, Path, QS], <<"\n">>),

  AuthSignature = bin_to_hex(crypto:hmac(sha256, AppSecret, ToSign)),

  URL = <<Scheme/binary, "://", Host/binary, Path/binary, "?", QS/binary, "&auth_signature=", AuthSignature/binary>>,

  Headers = [
    {<<"content-type">>, <<"application/json">>}
  ],

  {ok, Method, URL, Headers, Body}.

timestamp() ->
  {M, S, _} = now(),
  list_to_binary(integer_to_list(((M * 1000000) + S))).

binary_join([], _Sep) ->
  <<>>;
binary_join([H], _Sep) ->
  << H/binary >>;
binary_join([H | T], Sep) ->
  << H/binary, Sep/binary, (binary_join(T, Sep))/binary >>.

bin_to_hex(Bin) ->
  list_to_binary([hexdigit(I) || <<I:4>> <= Bin]).

%% @doc Convert an integer less than 16 to a hex digit.
hexdigit(C) when C >= 0, C =< 9 ->
    C + $0;
hexdigit(C) when C =< 15 ->
    C + $a - 10.
