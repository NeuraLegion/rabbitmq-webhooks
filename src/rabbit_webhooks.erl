% -*- tab-width: 2 -*-
-module(rabbit_webhooks).
-behaviour(gen_server).

-include("rabbit_webhooks.hrl").

-export([start_link/2]).
% gen_server callbacks
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).
% Helper methods
-export([
  send_request/6
]).

-define(NOW, erlang:timestamp()).
-define(REQUESTED_WITH, "RabbitMQ-Webhooks").
-define(VERSION, "0.19").
-define(ACCEPT, "application/json;q=.9,text/plain;q=.8,text/xml;q=.6,application/xml;q=.7,text/html;q=.5,*/*;q=.4").
-define(ACCEPT_ENCODING, "gzip").
-define(SEC_MSEC, 1000).
-define(MIN_MSEC, 60000).
-define(HOUR_MSEC, 3600000).
-define(DAY_MSEC, 86400000).
-define(WEEK_MSEC, 604800000).

-record(state, {
  channel,
  config = #webhook{},
  queue,
  consumer,
  sent = 0,
  mark,
  next_window
}).

start_link(_Name, Config) ->
  gen_server:start_link(?MODULE, [Config], []).

init([Config]) ->
  Username = case application:get_env(username) of
               {ok, U} ->
                 U;
               _ ->
                 <<"guest">>
             end,
  Password = case application:get_env(password) of
               {ok, P} ->
                 P;
               _ ->
                 <<"guest">>
             end,
  VHost = case application:get_env(virtual_host) of
            {ok, V} ->
              V;
            _ ->
              <<"/">>
          end,
  AmqpParams = #amqp_params_direct{
    username = Username,
    password = Password,
    virtual_host = VHost
  },
  {ok, Connection} = amqp_connection:start(AmqpParams),
  {ok, Channel} = amqp_connection:open_channel(Connection),

  Webhook = #webhook{
    url = proplists:get_value(url, Config),
    method = proplists:get_value(method, Config),
    exchange = case proplists:get_value(exchange, Config) of
                 [{exchange, Xname} | Xconfig] ->
                   #'exchange.declare'{
                     exchange = Xname,
                     type = proplists:get_value(type, Xconfig, <<"topic">>),
                     auto_delete = proplists:get_value(auto_delete, Xconfig, true),
                     durable = proplists:get_value(durable, Xconfig, false)
                   }
               end,
    queue = case proplists:get_value(queue, Config) of
              % Allow for load-balancing by using named queues (optional)
              [{queue, Qname} | Qconfig] ->
                #'queue.declare'{
                  queue = Qname,
                  auto_delete = proplists:get_value(auto_delete, Qconfig, true),
                  durable = proplists:get_value(durable, Qconfig, false)
                };
              % Default to an anonymous queue
              _ ->
                #'queue.declare'{auto_delete = true}
            end,
    routing_key = proplists:get_value(routing_key, Config),
    max_send = case proplists:get_value(max_send, Config) of
                 {Max, second} ->
                   {second, Max, ?SEC_MSEC};
                 {Max, minute} ->
                   {minute, Max, ?MIN_MSEC};
                 {Max, hour} ->
                   {hour, Max, ?HOUR_MSEC};
                 {Max, day} ->
                   {day, Max, ?DAY_MSEC};
                 {Max, week} ->
                   {week, Max, ?WEEK_MSEC};
                 {_, Freq} ->
                   rabbit_log:error("Invalid frequency: ~p~n", [Freq]),
                   invalid;
                 _ ->
                   infinity
               end,
    send_if = proplists:get_value(send_if, Config, always)
  },

  % Declare exchange
  case amqp_channel:call(Channel, Webhook#webhook.exchange) of
    #'exchange.declare_ok'{} ->
      rabbit_log:info("Declared webhooks exchange ~p~n", [Webhook#webhook.exchange]);
    XError ->
      rabbit_log:error("ERROR creating exchange ~p~n", [XError])
  end,

  % Declare queue
  QName = case amqp_channel:call(Channel, Webhook#webhook.queue) of
            #'queue.declare_ok'{queue = Q} ->
              rabbit_log:info("Declared webhooks queue ~p~n", [Q]),
              Q;
            QError ->
              rabbit_log:error("ERROR creating queue ~p~n", [QError])
          end,

  % Bind queue
  QueueBind = #'queue.bind'{
    queue = QName,
    exchange = (Webhook#webhook.exchange)#'exchange.declare'.exchange,
    routing_key = Webhook#webhook.routing_key
  },
  case amqp_channel:call(Channel, QueueBind) of
    #'queue.bind_ok'{} ->
      rabbit_log:info("Bound webhooks queue ~p -> ~p (~p)~n", [
        Webhook#webhook.queue,
        Webhook#webhook.exchange,
        Webhook#webhook.routing_key
      ]);
    BError ->
      rabbit_log:error("ERROR binding webhooks queue ~p~n", [BError])
  end,

  amqp_selective_consumer:register_default_consumer(Channel, self()),

  erlang:send_after(100, self(), check_window),
  {ok, #state{
    channel = Channel,
    config = Webhook,
    queue = QName,
    mark = get_time()}
  }.

handle_call(Msg, _From, State = #state{channel = _Channel, config = _Config}) ->
  rabbit_log:warning(" Unkown call: ~p~n State: ~p~n", [Msg, State]),
  {noreply, State}.

handle_cast(Msg, State = #state{channel = _Channel, config = _Config}) ->
  rabbit_log:warning(" Unkown cast: ~p~n State: ~p~n", [Msg, State]),
  {noreply, State}.

handle_info(subscribe, State = #state{channel = Channel, queue = Q}) ->
  % Subscribe to these events
  #'basic.consume_ok'{consumer_tag = Tag} = amqp_channel:subscribe(Channel, #'basic.consume'{queue = Q, no_ack = false},
                                                                   self()),
  {noreply, State#state{consumer = Tag}};

handle_info(cancel, State = #state{channel = Channel, consumer = Tag}) ->
  amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = Tag}),
  {noreply, State#state{consumer = undefined}};

handle_info(check_window, State = #state{config = Config}) ->
  [Vote, NextWindow] = case Config#webhook.send_if of
                         always ->
                           [-1, always];
                         SendIf ->
                           {_, {Hr, Min, _}} = erlang:localtime(),
                           Time = hour_to_msec(Hr) + min_to_msec(Min),
                           lists:foldl(fun(C, Acc) ->
                             [Vote, Delay] = Acc,
                             case C of
                               {between, {StartHr, StartMin}, {EndHr, EndMin}} ->
                                 Start = hour_to_msec(StartHr) + min_to_msec(StartMin),
                                 End = hour_to_msec(EndHr) + min_to_msec(EndMin),
                                 case Time >= Start andalso Time < End of
                                   false ->
                                     NewDelay = case Start > Time of
                                                  true ->
                                                    (Start - Time);
                                                  false ->
                                                    (Start + (hour_to_msec(24) - Time))
                                                end,
                                     [Vote - 1, case NewDelay > Delay of
                                                  true ->
                                                    case Delay of
                                                      0 ->
                                                        NewDelay;
                                                      _ ->
                                                        Delay
                                                    end;
                                                  false ->
                                                    NewDelay
                                                end];
                                   true ->
                                     [Vote, 0]
                                 end;
                               _ ->
                                 Acc
                             end
                                       end, [length(SendIf), 0], SendIf)
                       end,
  NewState = case Vote of
               0 ->
                 % Outside any submission window, update state
                 rabbit_log:info("Outside submission window, checking again in: ~p minutes~n",
                                 [erlang:round(NextWindow / 1000 / 60)]),
                 self() ! cancel,
                 erlang:send_after(NextWindow, self(), check_window),
                 State#state{next_window = NextWindow, mark = get_time()};
               _ ->
                 self() ! subscribe,
                 case NextWindow of
                   always ->
                     State#state{next_window = always};
                   NextWindow ->
                     % Within submission window, check again in 15 secs
                     erlang:send_after(15000, self(), check_window),
                     State#state{next_window = 0}
                 end
             end,
  {noreply, NewState};

handle_info(#'basic.cancel_ok'{consumer_tag = _Tag}, State) ->
  {noreply, State};

handle_info(#'basic.consume_ok'{consumer_tag = _Tag}, State) ->
  {noreply, State};

handle_info({#'basic.deliver'{delivery_tag = DeliveryTag},
             #amqp_msg{props = #'P_basic'{
               content_type = ContentType,
               headers = Headers,
               reply_to = ReplyTo},
                       payload = Payload} = _Msg},
            State = #state{channel = Channel, config = Config}) ->

  % Transform message headers to HTTP headers
  [Xhdrs, Params] = process_headers(Headers),
  HttpHdrs = try Xhdrs ++
    [{"Content-Type", maybe_add_content_type(ContentType)},
     {"Accept", ?ACCEPT},
     {"Accept-Encoding", ?ACCEPT_ENCODING},
     {"X-Requested-With", ?REQUESTED_WITH},
     {"X-Webhooks-Version", ?VERSION}]
    ++
    case ReplyTo of
      undefined ->
        [];
      _ ->
        [{"X-ReplyTo", binary_to_list(ReplyTo)}]
    end
    ++
    case os:getenv("RABBITMQ_WEBHOOKS_SECRET") of
      undefined ->
        [];
      false ->
        [];
      S ->
        generate_signature(S, Payload)
    end
             catch Ex ->
    rabbit_log:error("Error creating headaers: ~p~n",
                           [Ex])
             end,
  Url = case proplists:get_value("url", Params) of
          undefined ->
            parse_url(Config#webhook.url, Params);
          NewUrl ->
            parse_url(NewUrl, Params)
        end,
  Method = case proplists:get_value("method", Params) of
             undefined ->
               Config#webhook.method;
             NewMethod ->
               list_to_atom(string:to_lower(NewMethod))
           end,

  % Issue the actual request.
  worker_pool:submit_async(
    fun() ->
      send_request(Channel, DeliveryTag, Url, Method, HttpHdrs, Payload)
    end),

  Sent = State#state.sent + 1,
  NewState = case Config#webhook.max_send of
               infinity ->
                 State#state{sent = Sent};
               {_, Max, _} when Sent < Max ->
                 State#state{sent = Sent};
               {_, _, Delay} ->
                 timer:sleep(Delay),
                 State#state{sent = 0}
             end,

  {noreply, NewState};

handle_info(Msg, State) ->
  rabbit_log:warning("Unkown message: ~p~n State: ~p~n", [Msg, State]),
  {noreply, State}.

terminate(_, #state{channel = Channel, config = _Webhook, queue = _Q, consumer = Tag}) ->
  rabbit_log:info("Terminating ~p ~p~n", [self(), Tag]),
  if
    Tag /= undefined ->
      amqp_channel:call(Channel, #'basic.cancel'{consumer_tag = Tag})
  end,
  amqp_channel:call(Channel, #'channel.close'{}),
  ok.

generate_signature(Secret, Payload) ->
  Timestamp =
    integer_to_list(os:system_time(millisecond)),
  SignaturePayload =
    list_to_binary(string:join([Timestamp, Payload], ":")),
  Signature = crypto:mac(hmac, sha256, Secret,
                         SignaturePayload),
  [{"X-Webhooks-Signature", bin_to_hex_list(Signature)},
   {"X-Webhooks-Request-Timestamp", Timestamp}].



bin_to_hex_list(Bin) when is_binary(Bin) ->
  lists:flatten([io_lib:format("~2.16.0B", [X]) ||
                  X <- binary_to_list(Bin)]).

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

get_time() ->
  {Msec, Sec, Misecs} = ?NOW,
  Misecs + (1000 * Sec) + (Msec * 1000000).

hour_to_msec(Hr) ->
  (Hr * 60 * 60 * 1000).

min_to_msec(Min) ->
  (Min * 60 * 1000).

process_headers(Headers) ->
  lists:foldl(fun(Hdr, AllHdrs) ->
    case Hdr of
      {Key, _, Value} ->
        [HttpHdrs, Params] = AllHdrs,
        case <<Key:2/binary>> of
          <<"X-">> ->
            [[{binary_to_list(Key), binary_to_list(Value)} | HttpHdrs], Params];
          _ ->
            [HttpHdrs, [{binary_to_list(Key), binary_to_list(Value)} | Params]]
        end
    end
              end, [[], []], case Headers of
                               undefined ->
                                 [];
                               Else ->
                                 Else
                             end).

parse_url(From, Params) ->
  lists:foldl(fun(P, NewUrl) ->
    case P of
      {Param, Value} ->
        re:replace(NewUrl, io_lib:format("{~s}", [Param]), Value, [{return, list}])
    end
              end, From, Params).

send_request(Channel, DeliveryTag, Url, Method, HttpHdrs, Payload) ->
  try
    % Issue the actual request.
    case dlhttpc:request(Url, Method, HttpHdrs, Payload, infinity) of
      % Only process if the server returns 20x.
      {ok, {{Status, _}, Hdrs, _Response}} when Status >= 200 andalso Status < 300 ->
        % Check to see if we need to unzip this response
        case re:run(proplists:get_value("Content-Encoding", Hdrs, ""), "(gzip)", [{capture, [1], list}]) of
          nomatch ->
            ok;
          {match, ["gzip"]} ->
            ok
        end,
        amqp_channel:call(Channel, #'basic.ack'{delivery_tag = DeliveryTag});
      {error, busy} ->
        rabbit_log:error("dlhttp is busy nack", []),
        amqp_channel:call(Channel, #'basic.nack'{delivery_tag = DeliveryTag});
      Else ->
        rabbit_log:error("Received ~p from dlhttp nack", [Else]),
        amqp_channel:call(Channel, #'basic.nack'{delivery_tag = DeliveryTag})
    end
  catch Ex ->
    rabbit_log:error("Error requesting ~p: ~p~n", [Url, Ex]) end.

maybe_add_content_type(undefined) ->
  "application/octet-stream";
maybe_add_content_type(ContentType) when is_binary(ContentType) ->
  binary_to_list(ContentType);
maybe_add_content_type(ContentType) ->
  ContentType.
