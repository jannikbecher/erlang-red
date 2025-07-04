-module(ered_node).

-behaviour(gen_server).

-export([
    start/2,
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

%%
%% the basis for every node type and each node type will become one or more
%% processes.
%%

%%
%% Behaviour definition
-callback start(NodeDef :: map(), WsName :: atom()) ->
    {ok, Pid :: pid()}.

-callback handle_msg(Msg :: tuple(), NodeDef :: map()) ->
    {unhandled, NodeDef2 :: map()}
    | {handled, NodeDef2 :: map(), Msg2 :: map()}
    | {handled, NodeDef2 :: map(), dont_send_complete_msg}.

-callback handle_event(Event :: tuple(), NodeDef :: map()) ->
    NodeDef2 :: map().

%%
%%
-import(ered_nodered_comm, [
    unsupported/3
]).

-import(ered_nodes, [
    add_state/2,
    post_exception_or_debug/3,
    this_should_not_happen/2
]).

-import(ered_nodered_comm, [
    ws_from/1
]).

-import(ered_message_exchange, [
    post_completed/2
]).

%%
%% Register the NodePid with the pg module. This avoids filling the atom
%% table with unnecessary entries.
start(NodeDef, Module) ->
    {ok, NodePid} = maps:find('_node_pid_', NodeDef),
    {ok, Pid} = gen_server:start(?MODULE, {Module, NodeDef}, []),
    pg:join(NodePid, Pid),
    {ok, Pid}.

init({Module, NodeDef}) ->
    {ok, {Module, NodeDef}}.

%%
%% Sync calls to the node.

%% Filter nodes is a call to the supervisor to remove all the nodes from the
%% list for which it is responsible, It then stops and starts these nodes
%% as required.
handle_call({filter_nodes, NodeDefs}, _From, {Module, NodeDef}) ->
    {NewListOfNodeDefs, ModuleNodeDef} =
        Module:handle_event({filter_nodes, NodeDefs}, NodeDef),
    {reply, NewListOfNodeDefs, {Module, ModuleNodeDef}};
handle_call({registered, WsName, Pid}, _From, {Module, NodeDef}) ->
    NodeDef2 = Module:handle_event({registered, WsName, Pid}, NodeDef),
    {reply, NodeDef2, {Module, NodeDef2}};
handle_call(Msg, _From, {Module, NodeDef}) ->
    io:format("Unknown call to node ~p: ~p~n", [self(), Msg]),
    {reply, NodeDef, {Module, NodeDef}}.

%%
%% ---------------------------------- Handle Cast -----------------------
%%

%%
%% Inter-node communication, messages that pass from one node to other nodes.

%% completed msg are posted by the post_completed call which called here
%% also! Endless loops are prevented by complete nodes (which receive these
%% messages) marking messages with their ids.
handle_cast({MsgType = completed_msg, FromNodeDef, Msg}, {Module, NodeDef}) ->
    Results = Module:handle_msg(
        {MsgType, FromNodeDef, Msg},
        bump_counter(MsgType, NodeDef)
    ),
    handle_msg_responder(MsgType, Msg, Module, Results, post_completed);
%% exception raised by some other node and caught be a catch node - if
%% it exists.
handle_cast({MsgType = exception, From, Msg, ErrMsg}, {Module, NodeDef}) ->
    Results = Module:handle_msg(
        {MsgType, From, Msg, ErrMsg},
        bump_counter(MsgType, NodeDef)
    ),
    handle_msg_responder(MsgType, Msg, Module, Results, post_completed);
%%
%% This is for setting the active flag on the NodeDef - this is used for
%% the debug node.
handle_cast({disable, _WsName}, {Module, NodeDef}) ->
    {noreply, {Module, maps:put(active, false, NodeDef)}};
handle_cast({enable, _WsName}, {Module, NodeDef}) ->
    {noreply, {Module, maps:put(active, true, NodeDef)}};
%% outgoing messages are those generated by nodes such inject or http-in
%% these are messages sources and pass these messages off.
handle_cast({MsgType = outgoing, Msg}, {Module, NodeDef}) ->
    Results = Module:handle_msg({MsgType, Msg}, bump_counter(MsgType, NodeDef)),
    handle_msg_responder(MsgType, Msg, Module, Results, dont_post_completed);
%% ws_event is a websocket event that is passed to an assert node.
handle_cast({MsgType = ws_event, Details}, {Module, NodeDef}) ->
    Results = Module:handle_msg(
        {MsgType, Details},
        bump_counter(MsgType, NodeDef)
    ),
    handle_msg_responder(
        MsgType, Details, Module, Results, dont_post_completed
    );
%% This function signature can match the following messages:
%%    - {incoming, Msg}
%%    - {link_return, Msg}
%%    - {mqtt_incoming, Msg}
%%    - {delay_push_out, Msg}
%%    - {mqtt_not_sent, Msg}
%% These post_completed messages, hence they differ from the more general
%% use case.
handle_cast({MsgType, Msg}, {Module, NodeDef}) ->
    Results = Module:handle_msg({MsgType, Msg}, bump_counter(MsgType, NodeDef)),
    handle_msg_responder(MsgType, Msg, Module, Results, post_completed);
handle_cast(Msg, {Module, NodeDef}) ->
    unsupported(NodeDef, Msg, <<"Unsupported Msg Received">>),
    {noreply, {Module, NodeDef}}.
%%
%% ---------------------------------- Handle Info -----------------------
%%

%% Events generate by the system.
handle_info({registered, WsName, Pid}, {Module, NodeDef}) ->
    NodeDef2 = Module:handle_event({registered, WsName, Pid}, NodeDef),
    {noreply, {Module, NodeDef2}};
handle_info({reload}, {Module, NodeDef}) ->
    {ok, NodePid} = maps:find('_node_pid_', NodeDef),
    NodeDef2 = Module:handle_event(deploy, add_state(NodeDef, NodePid)),
    {noreply, {Module, NodeDef2}};
handle_info({mqtt_disconnected, ReasonCode, Properties}, {Module, NodeDef}) ->
    NodeDef2 = Module:handle_event(
        {mqtt_disconnected, ReasonCode, Properties}, NodeDef
    ),
    {noreply, {Module, NodeDef2}};
handle_info({deploy, NewNodeDef}, {Module, NodeDef}) ->
    {ok, NodePid} = maps:find('_node_pid_', NodeDef),
    NodeDef2 = Module:handle_event(deploy, add_state(NewNodeDef, NodePid)),
    {noreply, {Module, NodeDef2}};
%%
%% If any node decides to monitor other processes, then it will generate
%% these messages. Pass them on
handle_info(Event = {'DOWN', _, _, _, _}, {Module, NodeDef}) ->
    NodeDef2 = Module:handle_event(Event, NodeDef),
    {noreply, {Module, NodeDef2}};
%%
%% timeout event is generated by a erlang:start_timer(...) that can
%% be useful for auot reconnecting to services that should be available
handle_info({timeout, _TimerREf, Msg}, {Module, NodeDef}) ->
    NodeDef2 = Module:handle_event(Msg, NodeDef),
    {noreply, {Module, NodeDef2}};
handle_info({supervisor_node, Tuple}, {Module, NodeDef}) ->
    NodeDef2 = Module:handle_event(Tuple, NodeDef),
    {noreply, {Module, NodeDef2}};
%%
%% Now this is bad. Stopping is really the last thing that should happen.
handle_info({stop, WsName}, {Module, NodeDef}) ->
    Module:handle_event({stop, WsName}, NodeDef),
    {stop, normal, {Module, NodeDef}};
handle_info(Event, {Module, NodeDef}) ->
    io:format(
        "Node ~p Received unsupported event {{{ ~p }}}~n",
        [self(), Event]
    ),
    % unsupported(NodeDef, Event, <<"Unsupported Event Received">>),
    {noreply, {Module, NodeDef}}.

%%
%% ------------------------ Termination
%%

%%
%%
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

terminate(normal, _State) ->
    ok;
terminate(fake_crash, _State) ->
    % used by the supervisor test to demonstrate a non-normal exit.
    ok;
terminate(Event, State) ->
    io:format("Node ~p: Non-normal Termination: '~p' State: {{{ ~p }}}~n",
              [self(), Event, State]),
    ok.

%%
%% ------------------------ Helpers
%%

%%
%%
handle_msg_responder(MsgType, Msg, Module, Results, post_completed) ->
    case Results of
        {handled, NodeDef2, dont_send_complete_msg} ->
            {noreply, {Module, NodeDef2}};
        {handled, NodeDef2, Msg2} ->
            post_completed(NodeDef2, Msg2),
            {noreply, {Module, NodeDef2}};
        {unhandled, NodeDef2} ->
            bad_routing(NodeDef2, MsgType, Msg),
            {noreply, {Module, NodeDef2}}
    end;
handle_msg_responder(MsgType, Msg, Module, Results, dont_post_completed) ->
    case Results of
        {handled, NodeDef2, _Msg2} ->
            {noreply, {Module, NodeDef2}};
        {unhandled, NodeDef2} ->
            bad_routing(NodeDef2, MsgType, Msg),
            {noreply, {Module, NodeDef2}}
    end.

%%
%%

bad_routing(NodeDef, Type, Msg) ->
    this_should_not_happen(
        NodeDef,
        io_lib:format(
            "Node received unhandled message type ~p Node: ~p Msg: ~p\n",
            [Type, NodeDef, Msg]
        )
    ).

%%
%%
increment_message_counter(NodeDef, CntName) ->
    {ok, V} = maps:find(CntName, NodeDef),
    maps:put(CntName, V + 1, NodeDef).

%%
%% this needs to be in sync with ered_nodes:add_state/2
bump_counter(exception, NodeDef) ->
    increment_message_counter(NodeDef, '_mc_exception');
bump_counter(link_return, NodeDef) ->
    increment_message_counter(NodeDef, '_mc_link_return');
bump_counter(ws_event, NodeDef) ->
    increment_message_counter(NodeDef, '_mc_websocket');
bump_counter(outgoing, NodeDef) ->
    increment_message_counter(NodeDef, '_mc_outgoing');
bump_counter(incoming, NodeDef) ->
    increment_message_counter(NodeDef, '_mc_incoming');
bump_counter(_, NodeDef) ->
    NodeDef.
