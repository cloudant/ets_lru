% Copyright 2012 Cloudant. All rights reserved.

-module(ets_lru).
-behavior(gen_server).


-export([
    start_link/2,
    stop/1,

    insert/3,
    lookup/2,
    remove/2,
    clear/1,

    % Dirty functions read straight from
    % the ETS tables which means there are
    % race conditions with concurrent access.
    lookup_d/2
]).

-export([
    init/1,
    terminate/2,

    handle_call/3,
    handle_cast/2,
    handle_info/2,

    code_change/3
]).

-record(entry, {
    key,
    val,
    atime,
    ctime
}).

-record(st, {
    objects,
    atimes,
    ctimes,

    max_objs,
    max_size,
    max_lifetime,

    skip_fun=fun(_, _) -> false end
}).


start_link(Name, Options) when is_atom(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, {Name, Options}, []).


stop(LRU) ->
    gen_server:cast(LRU, stop).


lookup(LRU, Key) ->
    gen_server:call(LRU, {lookup, Key}).


insert(LRU, Key, Val) ->
    gen_server:call(LRU, {insert, Key, Val}).


remove(LRU, Key) ->
    gen_server:call(LRU, {remove, Key}).


clear(LRU) ->
    gen_server:call(LRU, clear).


lookup_d(Name, Key) when is_atom(Name) ->
    case ets:lookup(obj_table(Name), Key) of
        [#entry{val=Val}] ->
            gen_server:cast(Name, {accessed, Key}),
            {ok, Val};
        [] ->
            not_found
    end.


init({Name, Options}) ->
    St = set_options(#st{}, Options),
    ObjOpts = [set, named_table, protected, {keypos, #entry.key}],
    TimeOpts = [ordered_set, named_table, protected],

    {ok, St#st{
        objects = ets:new(obj_table(Name), ObjOpts),
        atimes = ets:new(at_table(Name), TimeOpts),
        ctimes = ets:new(ct_table(Name), TimeOpts)
    }}.


terminate(_Reason, St) ->
    true = ets:delete(St#st.objects),
    true = ets:delete(St#st.atimes),
    true = ets:delete(St#st.ctimes),
    ok.


handle_call({lookup, Key}, _From, St) ->
    Reply = case ets:lookup(St#st.objects, Key) of
        [#entry{val=Val}] ->
            accessed(St, Key),
            {ok, Val};
        [] ->
            not_found
    end,
    {reply, Reply, St, 0};

handle_call({insert, Key, Val}, _From, St) ->
    NewATime = erlang:now(),
    Pattern = #entry{key=Key, atime='$1', _='_'},
    case ets:match(St#st.objects, Pattern) of
        [[ATime]] ->
            Update = [{#entry.val, Val}, {#entry.atime, NewATime}],
            true = ets:update_element(St#st.objects, Key, Update),
            true = ets:delete(St#st.atimes, ATime),
            true = ets:insert(St#st.atimes, {NewATime, Key});
        [] ->
            Entry = #entry{key=Key, val=Val, atime=NewATime, ctime=NewATime},
            true = ets:insert(St#st.objects, Entry),
            true = ets:insert(St#st.atimes, {NewATime, Key}),
            true = ets:insert(St#st.ctimes, {NewATime, Key})
    end,
    {reply, ok, St, 0};

handle_call({remove, Key}, _From, St) ->
    Pattern = #entry{key=Key, atime='$1', ctime='$2', _='_'},
    Reply = case ets:match(St#st.objects, Pattern) of
        [[ATime, CTime]] ->
            true = ets:delete(St#st.objects, Key),
            true = ets:delete(St#st.atimes, ATime),
            true = ets:delete(St#st.ctimes, CTime),
            ok;
        [] ->
            not_found
    end,
    {reply, Reply, St, 0};

handle_call(clear, _From, St) ->
    true = ets:delete_all_objects(St#st.objects),
    true = ets:delete_all_objects(St#st.atimes),
    true = ets:delete_all_objects(St#st.ctimes),
    % No need to timeout here and evict cache
    % entries because its now empty.
    {reply, ok, St};

handle_call(Msg, _From, St) ->
    {stop, {invalid_call, Msg}, {invalid_call, Msg}, St}.


handle_cast({accessed, Key}, St) ->
    accessed(St, Key),
    {noreply, St, 0};

handle_cast(stop, St) ->
    {stop, normal, St};


handle_cast(Msg, St) ->
    {stop, {invalid_cast, Msg}, St}.


handle_info(timeout, St) ->
    trim(St),
    {noreply, St, next_timeout(St)};

handle_info(Msg, St) ->
    {stop, {invalid_info, Msg}, St}.


code_change(_OldVsn, St, _Extra) when not is_record(St, st) ->
    {st, Objs, ATimes, CTimes, MaxObjs, MaxSize, MaxLife} = St,
    St0 = #st{
        objects=Objs,
        atimes=ATimes,
        ctimes=CTimes,
        max_objs=MaxObjs,
        max_size=MaxSize,
        max_lifetime=MaxLife,
        skip_fun=fun(_, _) -> false end
    },
    {ok, St0};

code_change(_OldVsn, St, _Extra) ->
    {ok, St}.

% Internal

maybe_drop_key(St, Key, Val) ->
    SkipFun = St#st.skip_fun,
    case SkipFun(Key, Val) of
        true ->
            skipped;
        false ->
            Pattern = #entry{key=Key, atime='$1', ctime='$2', _='_'},
            [[ATime, CTime]] = ets:match(St#st.objects, Pattern),
            true = ets:delete(St#st.objects, Key),
            true = ets:delete(St#st.atimes, ATime),
            true = ets:delete(St#st.ctimes, CTime)
    end.


accessed(St, Key) ->
    Pattern = #entry{key=Key, atime='$1', _='_'},
    case ets:match(St#st.objects, Pattern) of
        [[ATime]] ->
            NewATime = erlang:now(),
            Update = {#entry.atime, NewATime},
            true = ets:update_element(St#st.objects, Key, Update),
            true = ets:delete(St#st.atimes, ATime),
            true = ets:insert(St#st.atimes, {NewATime, Key}),
            ok;
        [] ->
            ok
    end.


trim(St) ->
    trim_count(St),
    trim_size(St),
    trim_lifetime(St).


should_trim_count(#st{max_objs=undefined}) ->
    false;
should_trim_count(St=#st{max_objs=Max}) ->
    ets:info(St#st.objects, size) > Max.


trim_count(St) ->
    trim_by_access_time(St, fun should_trim_count/1).


should_trim_size(#st{max_size=undefined}) ->
    false;
should_trim_size(#st{max_size=Max}=St) ->
    ets:info(St#st.objects, memory) > Max.
trim_size(St) ->
    trim_by_access_time(St, fun should_trim_size/1).


trim_by_access_time(St, WhileFun) ->
    trim_by_access_time(St, WhileFun, ets:first(St#st.atimes)).

trim_by_access_time(_St, _WhileFun, '$end_of_table') ->
    ok;
trim_by_access_time(St, WhileFun, Current) ->
    case WhileFun(St) of
        true ->
            [{_ATime, Key}] = ets:lookup(St#st.atimes, Current),
            [#entry{val=Val}] = ets:lookup(St#st.objects, Key),
            maybe_drop_key(St, Key, Val),
            trim_by_access_time(St, WhileFun, ets:next(St#st.atimes, Current));
        false ->
            ok
    end.


should_trim_lifetime(#st{max_lifetime=undefined}, _CTime) ->
    false;
should_trim_lifetime(_St, '$end_of_table') ->
    false;
should_trim_lifetime(#st{max_lifetime=Max}, CTime) ->
    Now = os:timestamp(),
    DiffInMilli = timer:now_diff(Now, CTime) div 1000,
    DiffInMilli > Max.


trim_lifetime(St) ->
    First = ets:first(St#st.ctimes),
    case should_trim_lifetime(St, First) of
        true ->
            trim_lifetime(St, First);
        false ->
            ok
    end.

trim_lifetime(St, Current) ->
    case should_trim_lifetime(St, Current) of
        true ->
            [{_CTime, Key}] = ets:lookup(St#st.ctimes, Current),
            [#entry{val=Val}] = ets:lookup(St#st.objects, Key),
            maybe_drop_key(St, Key, Val),
            trim_lifetime(St, ets:next(St#st.ctimes, Current));
        false ->
            ok
    end.


next_timeout(#st{max_lifetime=undefined}) ->
    infinity;
next_timeout(St) ->
    case ets:first(St#st.ctimes) of
        '$end_of_table' ->
            infinity;
        CTime ->
            Now = os:timestamp(),
            DiffInMilli = timer:now_diff(Now, CTime) div 1000,
            erlang:max(St#st.max_lifetime - DiffInMilli, 0)
    end.


set_options(St, []) ->
    St;
set_options(St, [{max_objects, N} | Rest]) when is_integer(N), N > 0 ->
    set_options(St#st{max_objs=N}, Rest);
set_options(St, [{max_size, N} | Rest]) when is_integer(N), N > 0 ->
    set_options(St#st{max_size=N}, Rest);
set_options(St, [{max_lifetime, N} | Rest]) when is_integer(N), N > 0 ->
    set_options(St#st{max_lifetime=N}, Rest);
set_options(St, [{skip_fun, Fun} | Rest]) when is_function(Fun) ->
    set_options(St#st{skip_fun=Fun}, Rest);
set_options(_, [Opt | _]) ->
    throw({invalid_option, Opt}).


obj_table(Name) ->
    table_name(Name, "_objects").


at_table(Name) ->
    table_name(Name, "_atimes").


ct_table(Name) ->
    table_name(Name, "_ctimes").


table_name(Name, Ext) ->
    list_to_atom(atom_to_list(Name) ++ Ext).
