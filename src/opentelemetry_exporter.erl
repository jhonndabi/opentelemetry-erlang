-module(opentelemetry_exporter).

-export([init/1,
         export/2,
         shutdown/1]).

-include_lib("kernel/include/logger.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/ot_span.hrl").

-define(DEFAULT_ENDPOINTS, [{http, "localhost", 8080, []}]).

-record(state, {channel_pid :: pid(),
                endpoints :: map()}).

init(Opts) ->
    Endpoints = maps:get(endpoints, Opts, ?DEFAULT_ENDPOINTS),
    ChannelOpts = maps:get(channel_opts, Opts, #{}),

    ChannelPid = grpcbox_channel:start_link(dfeault_channel, Endpoints, ChannelOpts),

    {ok, #state{channel_pid=ChannelPid}}.

export(Tab, #state{channel_pid=_ChannelPid}) ->
    ResourceSpans = ets:foldl(fun(Span, Acc) ->
                                      [to_proto(Span) | Acc]
                              end, [], Tab),
    ExportRequest = #{resource_spans => ResourceSpans},
    opentelemetry_trace_service:export(ExportRequest),
    ok.

shutdown(#state{channel_pid=Pid}) ->
    _ = grpcbox_channel:stop(Pid),
    ok.

%%

to_proto(#span{trace_id=TraceId,
               span_id=SpanId,
               tracestate=TraceState,
               parent_span_id=MaybeParentSpanId,
               name=Name,
               kind=Kind,
               start_time=StartTime,
               end_time=EndTime,
               attributes=Attributes,
               timed_events=TimedEvents,
               links=Links,
               status=Status,
               child_span_count=ChildSpanCount,
               trace_options=_TraceOptions,
               is_recording=_IsRecording,
               library_resource=_LibraryResource}) ->
    ParentSpanId = case MaybeParentSpanId of undefined -> <<>>; _ -> <<MaybeParentSpanId:64>> end,
    #{name                     => Name,
      trace_id                 => <<TraceId:128>>,
      span_id                  => <<SpanId:64>>,
      parent_span_id           => ParentSpanId,
      tracestate               => TraceState,
      kind                     => Kind,
      start_time_unixnano      => to_unixnano(StartTime),
      end_time_unixnano        => to_unixnano(EndTime),
      attributes               => to_attributes(Attributes),
      dropped_attributes_count => 0,
      events                   => to_events(TimedEvents),
      dropped_events_count     => 0,
      links                    => to_links(Links),
      dropped_links_count      => 0,
      status                   => to_status(Status),
      local_child_span_count   => ChildSpanCount}.

-spec to_unixnano(wts:timestamp()) -> non_neg_integer().
to_unixnano({Timestamp, Offset}) ->
    erlang:convert_time_unit(Timestamp + Offset, native, nanosecond).

to_attributes(Attributes) ->
    to_attributes(Attributes, []).

to_attributes([], Acc) ->
    Acc;
to_attributes([{Key, Value} | Rest], Acc) when is_binary(Value) ->
    to_attributes(Rest, [#{key => Key,
                           type => 'STRING',
                           string_value => Value} | Acc]);
to_attributes([{Key, Value} | Rest], Acc) when is_integer(Value) ->
    to_attributes(Rest, [#{key => Key,
                           type => 'INT',
                           int_value => Value} | Acc]);
to_attributes([{Key, Value} | Rest], Acc) when is_float(Value) ->
    to_attributes(Rest, [#{key => Key,
                           type => 'DOUBLE',
                           double_value => Value} | Acc]);
to_attributes([{Key, Value} | Rest], Acc) when is_boolean(Value) ->
    to_attributes(Rest, [#{key => Key,
                           type => 'BOOL',
                           bool_value => Value} | Acc]);
to_attributes([_ | Rest], Acc) ->
    to_attributes(Rest, Acc).

to_status(#status{code=Code,
                  message=Message}) ->
    #{code => Code,
      message => Message};
to_status(_) ->
    #{}.

to_events(Events) ->
    to_events(Events, []).

to_events([], Acc)->
    Acc;
to_events([#timed_event{time_unixnano=Time,
                        event=#event{name=Name,
                                    attributes=Attributes}} | Rest], Acc) ->
    to_events(Rest, [#{time_unixnano => Time,
                       name => Name,
                       attributes => to_attributes(Attributes)} | Acc]);
to_events([_ | Rest], Acc) ->
    to_events(Rest, Acc).

to_links(Links) ->
    to_links(Links, []).

to_links([], Acc)->
    Acc;
to_links([#link{trace_id=TraceId,
                span_id=SpanId,
                attributes=Attributes,
                tracestate=TraceState} | Rest], Acc) ->
    to_links(Rest, [#{trace_id => <<TraceId:128>>,
                      span_id => <<SpanId:64>>,
                      tracestate => TraceState,
                      attributes => to_attributes(Attributes),
                      dropped_attributes_count => 0} | Acc]);
to_links([_ | Rest], Acc) ->
    to_links(Rest, Acc).
