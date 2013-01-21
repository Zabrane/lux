%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Copyright (c) 2012 Hakan Mattsson
%%
%% See the file "LICENSE" for information on usage and redistribution
%% of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(lux_html).

-export([annotate_log/1, history/2]).
-export([keysplit/2, keysplit/3]).

-include_lib("kernel/include/file.hrl").

-record(astate, {log_dir, log_file}).

annotate_log(LogFile) ->
    annotate_log(true, LogFile).

annotate_log(IsRecursive, LogFile) ->
    LogFile2 = filename:absname(LogFile),
    IsEventLog = lists:suffix("event.log", LogFile2),
    LogDir = filename:dirname(LogFile2),
    A = #astate{log_dir = LogDir, log_file = LogFile2},
    Res =
        case IsEventLog of
            true  -> annotate_event_log(A);
            false -> annotate_summary_log(IsRecursive, A)
        end,
    case Res of
        {ok, IoList} ->
            safe_write_file(LogFile2 ++ ".html", IoList);
        {error, _File, _ReasonStr} = Error ->
            Error
    end.

safe_write_file(File, IoList) ->
    case filelib:ensure_dir(File) of
        ok ->
            TmpFile = File ++ ".tmp",
            case file:write_file(TmpFile, IoList) of
                ok ->
                    case file:rename(TmpFile, File) of
                        ok ->
                            ok;
                        {error, FileReason} ->
                            {error, File, file:format_error(FileReason)}
                    end;
                {error, FileReason} ->
                    {error, TmpFile, file:format_error(FileReason)}
            end;
        {error, FileReason} ->
            {error, filename:dirname(File), file:format_error(FileReason)}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Annotate a summary log and all its event logs

annotate_summary_log(IsRecursive, A) ->
    case parse_summary_log(IsRecursive, A) of
        {ok, SummaryLog, Result, Groups, ArchConfig, _FileInfo} ->
            Html = html_groups(A, SummaryLog, Result, Groups, ArchConfig),
            {ok, Html};
        {error, _File, _Reason} = Error ->
            Error
    end.

parse_summary_log(IsRecursive, #astate{log_file = SummaryLog}) ->
    try
        case file:read_file(SummaryLog) of
            {ok, LogBin} ->
                Sections = binary:split(LogBin, <<"\n\n">>, [global]),
                [Summary, ArchConfig | Rest] = Sections,
                [_, SummaryLog2] = binary:split(Summary, <<": ">>),
                [Result | Rest2] = lists:reverse(Rest),
                Result2 = split_result(Result),
                Groups = split_groups(IsRecursive, Rest2, []),
                {ok, FI} = file:read_file_info(SummaryLog),
                {ok, SummaryLog2, Result2, Groups, ArchConfig, FI};
            {error, FileReason} ->
                {error, SummaryLog, file:format_error(FileReason)}
        end
    catch
        error:Reason2 ->
            ReasonStr =
                lists:flatten(io_lib:format("ERROR in ~s\n~p\n\~p\n",
                                            [SummaryLog,
                                             Reason2,
                                             erlang:get_stacktrace()])),
            io:format("~s\n", [ReasonStr]),
            {error, SummaryLog, ReasonStr}
    end.

split_result(Result) ->
    Lines = binary:split(Result, <<"\n">>, [global]),
    [_, Summary | Rest] = lists:reverse(Lines),
    [_, Summary2] = binary:split(Summary, <<": ">>),
    Lines2 = lists:reverse(Rest),
    Sections = split_result2(Lines2, []),
    {result, Summary2, Sections}.

split_result2([Heading | Lines], Acc) ->
    [Slogan, Count] = binary:split(Heading, <<": ">>),
    [Slogan2, _] = binary:split(Slogan, <<" ">>),
    Pred = fun(Line) ->
                   case Line of
                       <<"\t", _File/binary>> -> true;
                       _ -> false
                   end
           end,
    {Files, Lines2} = lists:splitwith(Pred, Lines),
    Parse = fun(<<"\t", File/binary>>) ->
                    [File2, LineNo] = binary:split(File, <<":">>),
                    {file, File2, LineNo}
            end,
    Files2 = lists:map(Parse, Files),
    split_result2(Lines2, [{section, Slogan2, Count, Files2} | Acc]);
split_result2([], Acc) ->
    Acc. % Return in reverse order (most important first)

split_groups(IsRecursive, [GroupEnd | Groups], Acc) ->
    Pred = fun(Case) ->
                   case binary:split(Case, <<": ">>) of
                       %% BUGBUG: Kept for backwards compatibility a while
                       [<<"test suite begin", _/binary>> |_] -> false;
                       [<<"test group begin", _/binary>> |_] -> false;
                       _ -> true
                   end
           end,
    Split = lists:splitwith(Pred, Groups),
    {Cases, [GroupBegin | Groups2]} = Split,
    [_, Group] = binary:split(GroupBegin, <<": ">>),
    [_, Group] = binary:split(GroupEnd, <<": ">>),
    Cases2 = split_cases(IsRecursive, lists:reverse(Cases), []),
    split_groups(IsRecursive, Groups2, [{test_group, Group, Cases2} | Acc]);
split_groups(_IsRecursive, [], Acc) ->
    Acc.

split_cases(IsRecursive, [Case | Cases], Acc) ->
    [NameRow | Sections] = binary:split(Case, <<"\n">>, [global]),
    [<<"test case", _/binary>>, Name] = binary:split(NameRow, <<": ">>),
    case Sections of
        [] ->
            Res = {result_case, Name, <<"ERROR">>, <<"unknown">>},
            split_cases(IsRecursive, Cases, [Res | Acc]);
        [Reason] ->
            Res =
                case binary:split(Reason,    <<": ">>) of
                    [<<"result", _/binary>>, Reason2] ->
                        {result_case, Name, Reason2, Reason};
                    [<<"error", _/binary>>, Reason2] ->
                        {result_case, Name, <<"ERROR">>, Reason2}
                end,
            split_cases(IsRecursive, Cases, [Res | Acc]);
        [_ScriptRow, LogRow | DocAndResult] ->
            [<<"event log", _/binary>>, RawEventLog] =
                binary:split(LogRow,  <<": ">>),
            EventLog = binary_to_list(RawEventLog),
            case IsRecursive of
                true ->
                    case annotate_log(EventLog) of
                        ok ->
                            ok;
                        {error, _, Reason} ->
                            io:format("ERROR in ~s\n\~p\n", [EventLog, Reason])
                    end;
                false ->
                    ignore
            end,
            {Doc, ResultCase} = split_doc(DocAndResult, []),
            Result = parse_result(ResultCase),
            HtmlLog = EventLog ++ ".html",
            Res = {test_case, Name, EventLog, Doc, HtmlLog, Result},
            split_cases(IsRecursive, Cases, [Res | Acc])
    end;
split_cases(_IsRecursive, [], Acc) ->
    lists:reverse(Acc).

split_doc([H|T] = Rest, AccDoc) ->
    case binary:split(H, <<": ">>) of
        [<<"doc", _/binary>>, Doc] ->
            split_doc(T, [Doc | AccDoc]);
        _ ->
            {lists:reverse(AccDoc), Rest}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Return summary log as HTML

html_groups(A, SummaryLog, Result, Groups, ArchConfig) ->
    Dir = filename:basename(filename:dirname(binary_to_list(SummaryLog))),
    RelSummaryLog = drop_prefix(A, SummaryLog),
    [
     html_header(["Lux summary log (", Dir, ")"]),
     html_href("h2", "Raw summary log: ", "", RelSummaryLog, RelSummaryLog),
     html_href("h3", "", "", "#suite_config", "Suite configuration"),
     html_summary_result(A, Result, Groups),
     html_groups2(A, Groups),
     html_anchor("h2", "", "suite_config", "Suite configuration:"),
     html_div(<<"annotate">>, ArchConfig),
     html_footer()
    ].

html_summary_result(A, {result, Summary, Sections}, Groups) ->
    %% io:format("Sections: ~p\n", [Sections]),
    [
     "\n<h2>Result: ", Summary, "</h2>\n",
     "<div class=case><pre>",
     [html_summary_section(A, S, Groups) || S <- Sections],
     "</pre></div>"
    ].

html_summary_section(A, {section, Slogan, Count, Files}, Groups) ->
    [
     "<strong>", Slogan, ": ", Count, "</strong>\n",
     case Files of
         [] ->
             [];
         _ ->
             [
              "<div class=annotate><pre>",
              [html_summary_file(A, F, Groups) || F <- Files],
              "</pre></div>"
             ]
     end
    ].

html_summary_file(A, {file, File, LineNo}, Groups) ->
    Files =
        [HtmlLog ||
            {test_group, _Group, Cases} <- Groups,
            {test_case, Name, _Log, _Doc, HtmlLog, _Res} <- Cases,
            File =:= Name],
    RelFile = drop_prefix(A, File),
    Label = [RelFile, ":", LineNo],
    case Files of
        [] ->
            [html_href("", "#" ++ RelFile, Label), "\n"];
        [HtmlLog|_] ->
            [html_href("", drop_prefix(A, HtmlLog), Label), "\n"]
    end.

html_groups2(A, [{test_group, Group, Cases} | Groups]) ->
    [
     "\n\n<h2>Test group: ", drop_prefix(A, Group), "</h2>\n",
     html_cases(A, Cases),
     html_groups2(A, Groups)
    ];
html_groups2(_A, []) ->
    [].

html_cases(A, [{test_case, Name, EventLog, Doc, HtmlLog, Res} | Cases]) ->
    Tag = "a",
    RelFile = drop_prefix(A, Name),
    RelHtmlLog = drop_prefix(A, HtmlLog),
    RelEventLog = drop_prefix(A, EventLog),
    [
     html_anchor(RelFile, ""),
     "\n",
     html_href("h3", "Test case: ", "", RelHtmlLog, RelFile),
     "\n<div class=case><pre>",
     html_doc(Tag, Doc),
     html_href(Tag, "Raw event log: ", "", RelEventLog, RelEventLog),
     html_href(Tag, "Annotated script: ", "", RelHtmlLog, RelHtmlLog),
     html_result(Tag, Res, RelHtmlLog),
     "\n",
     "</pre></div>",
     html_cases(A, Cases)
    ];
html_cases(A, [{result_case, Name, Reason, Details} | Cases]) ->
    Tag = "a",
    File = drop_prefix(A, Name),
    [
     html_anchor(File, ""),
     html_href("h3", "Test case: ", "", File, File),
     "\n<div class=case><pre>",
     "\n<", Tag, ">Result: <strong>", Reason, "</strong></", Tag, ">\n",
     "\n",
     Details,
     "</pre></div>",
     html_cases(A, Cases)
    ];
html_cases(_A, []) ->
    [].

html_doc(_Tag, []) ->
    [];
html_doc(Tag, [Slogan | Desc]) ->
    [
     "\n<", Tag, ">Description: <strong>", Slogan,"</strong></", Tag, ">\n",
     case Desc of
         [] ->
             [];
         _ ->
             html_div(<<"annotate">>, expand_lines(Desc))
     end
    ].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Annotate a lux with events from the log

annotate_event_log(#astate{log_file=EventLog} = A) ->
    try
        case scan(EventLog) of
            {ok, EventLog2, ConfigLog,
             Script, RawEvents, RawConfig, RawLogs, RawResult} ->
                Events = parse_events(RawEvents, []),
                Config = parse_config(RawConfig),
                Logs = parse_logs(RawLogs, []),
                Result = parse_result(RawResult),
                {Annotated, Files} =
                    interleave_code(A, Events, Script, 1, 999999, [], []),
                Html = html_events(A, EventLog2, ConfigLog, Script, Result,
                                   lists:reverse(Files),
                                   Logs, Annotated, Config),
                {ok, Html};
            {error, _File, _ReasonStr} = Error ->
                Error
        end
    catch
        error:Reason2 ->
            ReasonStr =
                lists:flatten(io_lib:format("ERROR in ~s\n~p\n\~p\n",
                                            [EventLog,
                                             Reason2,
                                             erlang:get_stacktrace()])),
            io:format("~s\n", [ReasonStr]),
            {error, EventLog, ReasonStr}
    end.

scan(EventLog) ->
    case file:read_file(EventLog) of
        {ok, <<"event log         : 0.1\n\n", LogBin/binary>>} ->
            scan_0_1(EventLog, LogBin);
        {ok, LogBin} ->
            scan_old(EventLog, LogBin);
        {error, FileReason} ->
            {error, EventLog, file:format_error(FileReason)}
    end.

scan_0_1(EventLog, LogBin) ->
    EventSections = binary:split(LogBin, <<"\n\n">>, [global]),
    EventSections2 = [binary:split(S, <<"\n">>, [global]) ||
                         S <- EventSections],
    case EventSections2 of
        [[Script], EventBins, ResultBins] -> ok;
        [[Script], ResultBins]            -> EventBins = []
    end,
    Dir = filename:dirname(EventLog),
    Base = filename:basename(EventLog, ".event.log"),
    ConfigLog = filename:join([Dir, Base ++ ".config.log"]),
    case file:read_file(ConfigLog) of
        {ok, <<"config log        : 0.1\n", ConfigBin/binary>>} ->
            ConfigSections = binary:split(ConfigBin, <<"\n\n">>, [global]),
            ConfigSections2 = [binary:split(S, <<"\n">>, [global])
                               || S <- ConfigSections],
            [ConfigBins, LogBins] = ConfigSections2,
            {ok, EventLog, ConfigLog,
             Script, EventBins, ConfigBins, LogBins, ResultBins};
        {error, FileReason} ->
            {error, ConfigLog, file:format_error(FileReason)}
    end.

scan_old(EventLog, LogBin) ->
    Sections = binary:split(LogBin, <<"\n\n">>, [global]),
    Sections2 = [binary:split(S, <<"\n">>, [global]) ||
                    S <- Sections],
    case Sections2 of
        [ScriptBins, EventBins, ConfigBins, LogBins, ResultBins] ->
            ok;
        [ScriptBins, EventBins, ConfigBins, [<<>>|ResultBins]] ->
            LogBins = [];
        [ScriptBins, [<<>>|ConfigBins], [<<>>|ResultBins]] ->
            LogBins = [],
            EventBins = []
    end,
    [Script] = ScriptBins,
    {ok, EventLog, <<"">>, Script, EventBins, ConfigBins, LogBins, ResultBins}.

parse_events([<<>>], Acc) ->
    %% Error case
    lists:reverse(Acc);
parse_events(Events, Acc) ->
    do_parse_events(Events, Acc).

do_parse_events([<<"include_begin ", SubFile/binary>> | Events], Acc) ->
    %% include_begin 11 47 53 demo/test.include
    %% include_end 11 47 53 demo/test.include
    Pred = fun(E) ->
                   case E of
                       <<"include_end ", SubFile/binary>> ->
                           false;
                       _ ->
                           true
                   end
           end,
    {SubEvents, [_| Events2]} = lists:splitwith(Pred, Events),
    [RawLineNoRange, SubFile2] = binary:split(SubFile, <<" \"">>),
    [RawLineNo, RawFirstLineNo, RawLastLineNo] =
        binary:split(RawLineNoRange, <<" ">>, [global]),
    Len = byte_size(SubFile2) - 1 ,
    <<SubFile3:Len/binary, _/binary>> = SubFile2,
    LineNo = list_to_integer(binary_to_list(RawLineNo)),
    FirstLineNo = list_to_integer(binary_to_list(RawFirstLineNo)),
    LastLineNo = list_to_integer(binary_to_list(RawLastLineNo)),
    SubEvents2 = parse_events(SubEvents, []),
    E = {include, LineNo, FirstLineNo, LastLineNo, SubFile3, SubEvents2},
    do_parse_events(Events2, [E | Acc]);
do_parse_events([Event | Events], Acc) ->
    [Prefix, Details] = binary:split(Event, <<"): ">>),
    [Shell, RawLineNo] = binary:split(Prefix, <<"(">>),
    LineNo = list_to_integer(binary_to_list(RawLineNo)),
    [Item | RawContents] = binary:split(Details, <<" ">>),
    Data =
        case RawContents of
            [] ->
                %% cli(86): suspend
                [<<>>];
            [Contents] ->
                case unquote(Contents) of
                    {quote, C} ->
                        %% cli(26): recv "echo ==$?==\r\n==0==\r\n$ "
                        split_lines(C);
                    {plain, C} ->
                        %% cli(70): timer start (10 seconds)
                        [C]
                end
        end,
    E = {event, LineNo, Item, Shell, Data},
    do_parse_events(Events, [E | Acc]);
do_parse_events([], Acc) ->
    lists:reverse(Acc).

split_lines(Bin) ->
    Opts = [global],
    Bin2 = binary:replace(Bin, <<"[\\r\\n]+">>, <<"\n">>, Opts),
    Bin3 = binary:replace(Bin2, <<"\\r">>, <<"">>, Opts),
    binary:split(Bin3, <<"\\n">>, Opts).

parse_config(RawConfig) ->
    %% io:format("Config: ~p\n", [RawConfig]),
    RawConfig.

parse_logs([StdinLog, StdoutLog | Logs], Acc) ->
    [_, Shell, Stdin] = binary:split(StdinLog, <<": ">>, [global]),
    [_, Shell, Stdout] = binary:split(StdoutLog, <<": ">>, [global]),
    L = {log, Shell, Stdin, Stdout},
    %% io:format("Logs: ~p\n", [L]),
    parse_logs(Logs, [L | Acc]);
parse_logs([<<>>], Acc) ->
    lists:reverse(Acc);
parse_logs([], Acc) ->
    lists:reverse(Acc).

parse_result(RawResult) ->
    case RawResult of
        [<<>>, LongResult | Rest] -> ok;
        [LongResult | Rest]       -> ok
    end,
    [_, Result] = binary:split(LongResult, <<": ">>),
    R =
        case Result of
            <<"SUCCESS">> ->
                success;
            <<"ERROR at ", Error/binary>> ->
                [RawLineNo, Reason] = binary:split(Error, <<":">>),
                {error_line, RawLineNo, [Reason | Rest]};
            <<"ERROR ", Reason/binary>> ->
                {error, [Reason | Rest]};
            <<"FAIL at ", Fail/binary>> ->
                [<<"expected">>, Expected,
                 <<"actual ", Actual/binary>>, Details | _] = Rest,
                [Script, RawLineNo] = binary:split(Fail, <<":">>),
                {quote, Expected2} = unquote(Expected),
                Expected3 = split_lines(Expected2),
                {quote, Details2} = unquote(Details),
                Details3 = split_lines(Details2),
                {fail, Script, RawLineNo, Expected3, Actual, Details3}
        end,
    %% io:format("Result: ~p\n", [R]),
    {result, R}.

interleave_code(A, Events, Script, FirstLineNo, MaxLineNo, CallStack, Files) ->
    {ok, Cwd} = file:get_cwd(),
    SplitFiles = lux_utils:filename_split(Cwd, Script),
    case file:read_file(Script) of
        {ok, ScriptBin} ->
            NewScript = orig_script(A, Script),
            case file:write_file(NewScript, ScriptBin) of
                ok ->
                    ok;
                {error, FileReason} ->
                    ReasonStr = binary_to_list(Script) ++ ": " ++
                        file:format_error(FileReason),
                    erlang:error(ReasonStr)
            end,
            CodeLines = binary:split(ScriptBin, <<"\n">>, [global]),
            CodeLines2 =
                try
                    lists:nthtail(FirstLineNo-1, CodeLines)
                catch
                    _X:_Y ->
                        CodeLines
                end,
            Files2 =
                case lists:keymember(Script, 2, Files) of
                    false -> [{file, Script, NewScript} | Files];
                    true  -> Files
                end,
            do_interleave_code(A, Events, SplitFiles, CodeLines2,
                               FirstLineNo, MaxLineNo, [], CallStack, Files2);
        {error, FileReason} ->
            ReasonStr = binary_to_list(Script) ++ ": " ++
                file:format_error(FileReason),
            io:format("ERROR(lux): ~s\n", [ReasonStr]),
            do_interleave_code(A, Events, SplitFiles, [],
                               FirstLineNo, MaxLineNo, [], CallStack, Files)
    end.

do_interleave_code(A, [{include, LineNo, FirstLineNo, LastLineNo,
                        SubScript, SubEvents} |
                       Events],
                   SplitFiles, CodeLines, CodeLineNo, MaxLineNo,
                   Acc, CallStack, Files) ->
    CallStack2 = [{SplitFiles, LineNo} | CallStack],
    {SubAnnotated, Files2} =
        interleave_code(A, SubEvents, SubScript, FirstLineNo, LastLineNo,
                        CallStack2, Files),
    Event = {include_html, CallStack2, FirstLineNo, SubScript, SubAnnotated},
    do_interleave_code(A, Events, SplitFiles, CodeLines, CodeLineNo,
                       MaxLineNo, [Event | Acc], CallStack, Files2);
do_interleave_code(A, [{event, SingleLineNo, Item, Shell, Data},
                       {event, SingleLineNo, Item, Shell, Data2} | Events],
                   SplitFiles, CodeLines, CodeLineNo, MaxLineNo,
                   Acc, CallStack, Files) when Item =:= <<"recv">>,
                                               Data2 =/= [<<"timeout">>]->
    %% Combine two chunks of recv data into one in order to improve readability
    [Last | Rev] = lists:reverse(Data),
    [First | Rest] = Data2,
    Data3 = lists:reverse(Rev, [<<Last/binary, First/binary>> | Rest]),
    do_interleave_code(A, [{event, SingleLineNo, Item, Shell, Data3} | Events],
                       SplitFiles, CodeLines, CodeLineNo,
                       MaxLineNo, Acc, CallStack, Files);
do_interleave_code(A, [{event, SingleLineNo, _Item, Shell, Data} | Events],
                   SplitFiles, CodeLines, CodeLineNo, MaxLineNo,
                   Acc, CallStack, Files) ->
    {CodeLines2, CodeLineNo2, Code} =
        pick_code(SplitFiles, CodeLines, CodeLineNo, SingleLineNo,
                  [], CallStack),
    CallStack2 = [{SplitFiles, SingleLineNo} | CallStack],
    Acc2 = [{event_html, CallStack2, _Item, Shell, Data}] ++ Code ++ Acc,
    do_interleave_code(A, Events, SplitFiles, CodeLines2, CodeLineNo2,
                       MaxLineNo, Acc2, CallStack, Files);
do_interleave_code(_A, [], SplitFiles, CodeLines, CodeLineNo, MaxLineNo,
                   Acc, CallStack, Files) ->
    X = pick_code(SplitFiles, CodeLines, CodeLineNo, MaxLineNo, [], CallStack),
    {_Skipped, _CodeLineNo, Code} = X,
    {lists:reverse(Code ++ Acc), Files}.

pick_code(SplitFiles, [Line | Lines], CodeLineNo, LineNo, Acc, CallStack)
  when LineNo >= CodeLineNo ->
    CallStack2 = [{SplitFiles, CodeLineNo} | CallStack],
    pick_code(SplitFiles, Lines, CodeLineNo+1, LineNo,
              [{code_html, CallStack2, Line} | Acc], CallStack);
pick_code(_SplitFiles, Lines, CodeLineNo, _LineNo, Acc, _CallStack) ->
    {Lines, CodeLineNo, Acc}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Return event log as HTML

html_events(A, EventLog, ConfigLog, Script, Result, Files,
            Logs, Annotated, Config) ->
    Dir = filename:basename(filename:dirname(EventLog)),
    [
     html_header(["Lux event log (", Dir, ")"]),
     "\n<h2>", drop_prefix(A, Script), "</h2>\n",
     html_result("h2", Result, ""),
     html_href("h3", "", "", "#config", "Script configuration"),
     html_href("h3", "", "", "#cleanup", "Cleanup"),
     "\n<h3>Source files: ",
     html_files(A, Files),
     "\n</h3>",
     html_href("h3", "", "", drop_prefix(A, EventLog), "Raw event log"),
     html_href("h3", "", "", drop_prefix(A, ConfigLog), "Raw config log"),
     html_logs(A, Logs),
     "\n<h2>Annotated source code</h2>\n",
     html_code(A, Annotated),

     "<div class=code><pre><a name=\"cleanup\"></a></pre></div>\n",

     html_anchor("h2", "", "config", "Script configuration:"),
     html_config(Config),
     html_footer()
    ].

html_result(Tag, {result, Result}, HtmlLog) ->
    case Result of
        success ->
            ["\n<", Tag, ">Result: <strong>SUCCESS</strong></", Tag, ">\n"];
        skip ->
            ["\n<", Tag, ">Result: <strong>SKIP</strong></", Tag, ">\n"];
        {error_line, RawLineNo, Reason} ->
            Anchor = RawLineNo,
            [
             "\n<", Tag, ">Result: <strong>ERROR at line ",
             html_href("", [HtmlLog, "#", Anchor], Anchor),
             "<h3>Reason</h3>",
             html_div(<<"annotate">>, expand_lines(Reason))
            ];
        {error, Reason} ->
            [
             "\n<", Tag, ">Result: <strong>ERROR</strong></", Tag, ">\n",
             "<h3>Reason</h3>",
             html_div(<<"annotate">>, expand_lines(Reason))
            ];
        {fail, _Script, RawLineNo, Expected, Actual, Details} ->
            Anchor = RawLineNo,
            [
             "\n<", Tag, ">Result: <strong>FAILED at line ",
             html_href("", [HtmlLog, "#", Anchor], Anchor),
             "</strong></", Tag, ">\n",
             "<h3>Expected</h3>",
             html_div(<<"annotate">>, expand_lines(Expected)),
             "<h3>Actual: ", html_cleanup(Actual), "</h3>",
             html_div(<<"annotate">>, expand_lines(Details))
            ]
    end.

html_config(Config) ->
    html_div(<<"annotate">>, expand_lines(Config)).

html_logs(A, [{log, Shell, Stdin, Stdout} | Logs]) ->
    [
     "\n<h3>Logs for shell ", Shell, ": ",
     html_href("", drop_prefix(A, Stdin), "stdin"),
     " ",
     html_href("", drop_prefix(A, Stdout), "stdout"),
     "</h3>\n",
     html_logs(A, Logs)
    ];
html_logs(_A, []) ->
    [].

html_code(A, Annotated) ->
    [
     "\n<div class=code><pre>\n",
     html_code2(A, Annotated, code),
     "</pre></div>\n"
    ].

html_code2(A, [Ann | Annotated], Prev) ->
    case Ann of
        {code_html, CallStack, Code} ->
            Curr = code,
            PrettyCallStack = lux_utils:pretty_call_stack(CallStack),
            [
             html_toggle_div(Curr, Prev),
             case Code of
                 <<"[cleanup]">> -> "<a name=\"cleanup\"></a>";
                 _               -> ""
             end,
             html_anchor(CallStack, PrettyCallStack), ": ",
             html_cleanup(Code),
             "\n",
             html_code2(A, Annotated, Curr)
            ];
        {event_html, CallStack, Item, Shell, Data} ->
            Curr = event,
            PrettyCallStack = lux_utils:pretty_call_stack(CallStack),
            Html = [Shell, "(", PrettyCallStack, "): ", Item, " "],
            [
             html_toggle_div(Curr, Prev),
             html_cleanup(Html),
             html_opt_div(Item, Data),
             html_code2(A, Annotated, Curr)
            ];
        {include_html, CallStack, _MacroLineNo, SubScript, SubAnnotated} ->
            PrettyCallStack = lux_utils:pretty_call_stack(CallStack),
            RelSubScript = drop_prefix(A, SubScript),
            [
             html_toggle_div(code, Prev),
             html_toggle_div(event, code),
             html_opt_div(<<"include">>,
                          [<<"entering file: ", RelSubScript/binary>>]),
             "</pre></div>",
             html_code(A, SubAnnotated),
             html_toggle_div(code, event),
             html_anchor(PrettyCallStack, PrettyCallStack), ": ",
             html_toggle_div(event, code),
             html_opt_div(<<"include">>,
                          [<<"exiting file: ", RelSubScript/binary>>]),
             "</pre></div>",
             html_code(A, Annotated)
            ]
    end;
html_code2(_A, [], _Prev) ->
    [].

html_toggle_div(Curr, Prev) ->
    case {Curr, Prev} of
        {code, code}   -> "";
        {code, event}  -> "</pre></div>\n<div class=code><pre>";
        {event, event} -> "";
        {event, code}  -> "</pre></div>\n<div class=annotate><pre>\n"
    end.

html_opt_div(Item, Data) ->
    Html = expand_lines(Data),
    case Item of
        <<"send">>   -> html_div(Item, Html);
        <<"recv">>   -> html_div(Item, Html);
        <<"expect">> -> html_div(Item, Html);
        <<"skip">>   -> html_div(Item, Html);
        <<"match">>  -> html_div(Item, Html);
        _            -> html_cleanup(Html)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% History

-define(DEFAULT_LOG, <<"unknown">>).
-define(DEFAULT_HOSTNAME, <<"unknown">>).
-define(DEFAULT_CONFIG_NAME, <<"unknown">>).
-define(DEFAULT_SUITE, <<"unknown">>).
-define(DEFAULT_RUN, <<"unknown">>).
-define(DEFAULT_REV, <<"">>).
-define(DEFAULT_TIME, <<"yyyy-mm-dd hh:mm:ss">>).

-record(run,
        {id,
         test,
         result,
         log,
         start_time,
         hostname,
         config_name,
         run_dir,
         repos_rev,
         details}).

history(TopDir, HtmlFile) ->
    TopDir2 = filename:absname(TopDir),
    AbsHtmlFile = filename:absname(HtmlFile),
    AllRuns = parse_summary_logs(AbsHtmlFile, TopDir2, []),
    io:format("~p test runs", [length(AllRuns)]),
    SplitHosts = keysplit(#run.hostname, AllRuns),
    LatestRuns = latest_runs(SplitHosts),
    HostTables = html_history_table_hosts(SplitHosts, AbsHtmlFile),
    SplitConfigs = keysplit(#run.config_name, AllRuns, fun compare_run/2),
    ConfigTables = html_history_table_configs(SplitConfigs, AbsHtmlFile),
    OverviewIoList =
        [
         html_history_header("overview", AllRuns,
                             ConfigTables, HostTables, HtmlFile),
         html_history_table_latest(LatestRuns, AbsHtmlFile),
         html_history_table_all(AllRuns, AbsHtmlFile),
         html_footer()
        ],
    ConfigIoList =
        [
         html_history_header("config", AllRuns,
                             ConfigTables, HostTables, HtmlFile),
         [IoList || {table, _, _, IoList} <- ConfigTables],
         html_footer()
        ],
    HostIoList =
        [
         html_history_header("host", AllRuns,
                             ConfigTables, HostTables, HtmlFile),
         [IoList || {table, _, _, IoList} <- HostTables],
         html_footer()
        ],
    HtmlDir = filename:dirname(HtmlFile),
    ConfigHtmlFile =
        filename:join(HtmlDir, insert_html_suffix(HtmlFile, "", "_config")),
    HostHtmlFile =
        filename:join(HtmlDir, insert_html_suffix(HtmlFile, "", "_host")),
    safe_write_file(HtmlFile, OverviewIoList),
    safe_write_file(ConfigHtmlFile, ConfigIoList),
    safe_write_file(HostHtmlFile, HostIoList).

latest_runs(SplitHosts) ->
    SplitHostTests =
        [{Host, keysplit(#run.test, HostRuns, fun compare_run/2)} ||
            {Host, HostRuns} <- SplitHosts],
    DeepIds =
        [(hd(TestRuns))#run.id ||
            {_Host, HostTests} <-SplitHostTests,
            {_Test, TestRuns} <- HostTests],
    Ids = lists:usort(lists:flatten(DeepIds)),
    [Run ||
        {_Host, HostTests} <-SplitHostTests,
        {_Test, TestRuns} <- HostTests,
        Run <- TestRuns,
        lists:member(Run#run.id, Ids)].

html_history_header(Section, AllRuns, ConfigTables, HostTables, HtmlFile) ->
    Dir = filename:basename(filename:dirname(HtmlFile)),
    case lists:keysort(#run.repos_rev, AllRuns) of
        [] ->
            Default = <<"unknown">>,
            FirstRev = Default,
            LatestRev = Default,
            FirstTime = Default,
            LatestTime = Default,
            N = 0;
        SortedRuns ->
            FirstRev = (hd(SortedRuns))#run.repos_rev,
            LatestRev = (lists:last(SortedRuns))#run.repos_rev,
            FirstRuns = [R || R <- SortedRuns, R#run.repos_rev =:= FirstRev],
            LatestRuns = [R || R <- SortedRuns, R#run.repos_rev =:= LatestRev],
            FirstRuns2 = lists:keysort(#run.repos_rev, FirstRuns),
            LatestRuns2 = lists:keysort(#run.repos_rev, LatestRuns),
            FirstTime = (hd(FirstRuns2))#run.start_time,
            LatestTime = (hd(LatestRuns2))#run.start_time,
            N = integer_to_list(length(SortedRuns))
    end,
    [
     html_header(["Lux history ", Section, " (", Dir, ")"]),
     "<h1>Lux history ", Section, " (", Dir, ") generated at ",
     lux_utils:now_to_string(erlang:now()),
     "</h1>",

     "<h3>", N, " runs within this range of repository revisions</h3>\n",
     "<table border=0>",
     "<tr>",
     "<td>Latest:</td><td><strong>", LatestRev, "</strong></td>",
     "<td>at ", LatestTime, "</td>\n",
     "</tr>",
     "<tr>",
     "<td>First:</td><td><strong>", FirstRev, "</strong></td>",
     "<td>at ", FirstTime, "</td>\n",
     "</tr>",
     "</table>\n\n",

     html_history_legend(),
     "\n\n"
     "<h3>Configurations</h3>",
     "  <table border=1>\n",
     "    <tr>\n",
     [
      html_config_href_td(HtmlFile, ConfigName, ConfigRes) ||
         {table, ConfigName, ConfigRes, _ConfigIoList} <- ConfigTables
     ],
     "    </tr>\n",
     "  </table>\n",
     "<h3>Hosts</h3>",
     "  <table border=1>\n",
     "    <tr>\n",
     [
      html_host_href_td(HtmlFile, Host, HostRes) ||
         {table, Host, HostRes, _HostIoList} <- HostTables
     ],
     "    </tr>\n",
     "  </table>\n"
    ].

html_history_legend() ->
    [
     "<h3>Legend</h3>\n",
     "  <table border=1>\n",
     "    <tr>\n",
     html_history_td("First fail", fail, "left"),
     html_history_td("Secondary fails on same host", secondary_fail, "left"),
     html_history_td("Skipped", none, "left"),
     html_history_td("Success", success, "left"),
     html_history_td("No data", no_data, "left"),
     "    </tr>\n",
     "  </table>\n"
    ].

html_history_table_latest(LatestRuns, HtmlFile) ->
    {table, _, _, IoList} =
        html_history_table("Latest", "All test suites",
                           LatestRuns, HtmlFile, false, worst),
    [
     "<h3>Latest run on each host</h3>\n",
     IoList
    ].

html_history_table_all(AllRuns, HtmlFile) ->
    {table, _, _, IoList} =
        html_history_table("All", "All test suites",
                           AllRuns, HtmlFile, false, latest),
    [
     "<h3>All runs</h3>\n",
     IoList
    ].

html_history_table_configs(SplitConfigs, HtmlFile) ->
    [
     html_history_double_table(ConfigName,
                               "Config: " ++ ConfigName,
                               Runs,
                               HtmlFile,
                               latest) ||
        {ConfigName, Runs} <- SplitConfigs
    ].

html_history_table_hosts(SplitHosts, HtmlFile) ->
    [
     html_history_double_table(Host,
                               ["Host: ", Host,
                                " (", (hd(Runs))#run.config_name, ")"],
                               Runs,
                               HtmlFile,
                               latest) ||
        {Host, Runs} <- SplitHosts
    ].

html_history_double_table(Name, Label, AllRuns, HtmlFile, ResKind) ->
    Details = [D#run{details=[D]} || R <- AllRuns, D <- R#run.details],
    {table, _, WorstRes, AllIoList} =
        html_history_table(Name, "All test suites",
                           AllRuns, HtmlFile, false, ResKind),
    {table, _, _, FailedIoList} =
        html_history_table(Name, "Failed test cases",
                           Details, HtmlFile, true, ResKind),
    {table,
     Name,
     WorstRes,
     [
      "<br><br>\n",
      ["<h3>", html_anchor(Name, Label), "</h3>\n"],
      AllIoList,
      FailedIoList
     ]
    }.

html_history_table(Name, Grain, Runs, HtmlFile, SuppressSuccess, ResKind) ->
    SplitTests = keysplit(#run.test, Runs, fun compare_run/2),
    SplitIds = keysplit(#run.id, Runs, fun compare_run/2),
    SplitIds2 = lists:sort(fun compare_split/2, SplitIds),
    RowHistory =
        [
         html_history_row(Test, TestRuns, SplitIds2, HtmlFile,
                          ResKind, SuppressSuccess)
         || {Test, TestRuns} <- lists:reverse(SplitTests)
        ],
    PickWorst = fun({row, Worst, _}, Acc) -> lux_utils:summary(Acc, Worst) end,
    WorstRes = lists:foldl(PickWorst, no_data, RowHistory),
    {table,
     Name,
     WorstRes,
     [
      "  <table border=1>\n",
      "    <tr>\n",
      html_history_table_td(Grain, WorstRes, "left"),
      [["      <td>", Rev,
        "<br>", "<strong>", Id, "</strong>",
        "<br>", Time,
        "</td>\n"] ||
          {Id, [#run{start_time=Time, repos_rev=Rev} |_ ]}
              <- SplitIds2
      ],
      "    </tr>\n",
      "    <tr>\n",
      [["      <td>",
        "<strong>",
        html_host_href(HtmlFile, "", "#" ++ Host, Host),
        "</strong>",
        "<br>", html_config_href(HtmlFile, "", "#" ++ ConfigName, ConfigName),
        "</td>\n"] ||
          {_, [#run{hostname=Host, config_name=ConfigName} |_ ]}
              <- SplitIds2
      ],
      "    </tr>\n",
      [RowIoList || {row, _Worst, RowIoList} <- RowHistory],
      "  </table>\n"
     ]
    }.

html_history_row(Test, Runs, SplitIds, HtmlFile, ResKind, SuppressSuccess) ->
    RevRuns = lists:reverse(lists:keysort(#run.id, Runs)),
    EmitCell =
        fun({Id, _}, AccRes) ->
                html_history_cell(Id, RevRuns, HtmlFile, AccRes)
        end,
    {Cells, _} = lists:mapfoldr(EmitCell, [], SplitIds),
    ValidResFilter = fun (Cell) -> valid_res_filter(Cell, SuppressSuccess) end,
    ValidRes = lists:zf(ValidResFilter, Cells),
    case lists:usort(ValidRes) of
        [] when SuppressSuccess ->
            {row, no_data, []}; % Skip row
        [success] when SuppressSuccess ->
            {row, no_data, []}; % Skip row
        [none] when SuppressSuccess ->
            {row, no_data, []}; % Skip row
        _ ->
            Res = select_row_res(Cells, ResKind),
            {row,
             Res,
             [
              "    <tr>\n",
              html_history_td(Test, Res, "left"),
              [Td || {cell, _Res, _Run, Td} <- Cells],
              "    </tr>\n"
             ]
            }
    end.

valid_res_filter({cell, Res, _Run, _Td}, SuppressSuccess) ->
    case Res of
        no_data                      -> false;
        success when SuppressSuccess -> false;
        _                            -> {true, Res}
    end.

select_row_res(Cells, worst) ->
    PickWorst = fun({cell, Res, _, _}, Acc) -> lux_utils:summary(Acc, Res) end,
    lists:foldl(PickWorst, no_data, Cells);
select_row_res([{cell, no_data, _, _} | Cells], latest) ->
    %% Try to find latest true result (not no_data)
    select_row_res(Cells, latest);
select_row_res([{cell, Res, _, _} | _Cells], latest) ->
    Res;
select_row_res([], latest) ->
    no_data.

%% Returns true if first run is newer than (or equal) to second run
%% Compare fields in this order: repos_rev, start_time, hostname and id
compare_run(#run{repos_rev=A}, #run{repos_rev=B}) when A < B ->
    false;
compare_run(#run{repos_rev=A}, #run{repos_rev=B}) when A > B ->
    true;
compare_run(#run{start_time=A}, #run{start_time=B}) when A < B ->
    false;
compare_run(#run{start_time=A}, #run{start_time=B}) when A > B ->
    true;
compare_run(#run{hostname=A}, #run{hostname=B}) when A < B ->
    false;
compare_run(#run{hostname=A}, #run{hostname=B}) when A > B ->
    true;
compare_run(#run{id=A}, #run{id=B}) ->
    A > B.

compare_split({_, []}, {_, [#run{}|_]}) ->
    true;
compare_split({_, [#run{}|_]}, {_, []}) ->
    false;
compare_split({_, [#run{}=R1|_]}, {_, [#run{}=R2|_]}) ->
    %% Test on first run
    compare_run(R1, R2).

html_history_cell(Id, Runs, HtmlFile, AccRes) ->
    case lists:keyfind(Id, #run.id, Runs) of
        false ->
            Td = html_history_td("-", no_data, "right"),
            {{cell, no_data, undefined, Td}, AccRes};
        Run ->
            RunN  = length([run  || R <- Run#run.details,
                                    R#run.result =/= skip]),
            FailN = length([fail || R <- Run#run.details,
                                    R#run.result =:= fail]),
            FailCount = lists:concat([FailN, " (", RunN, ")"]),
            Text =
                case Run#run.log of
                    ?DEFAULT_LOG ->
                        FailCount;
                    Log ->
                        HtmlDir = filename:dirname(HtmlFile),
                        html_href("",
                                  [drop_prefix(HtmlDir, Log), ".html"],
                                  FailCount)
                end,
            OrigRes =
                case RunN of
                    0 -> none;
                    _ -> Run#run.result
                end,
            Host = Run#run.hostname,
            Res =
                case lists:keyfind(Host, 1, AccRes) of
                    {_, fail} when OrigRes =:= fail ->
                        secondary_fail;
                    _ ->
                        OrigRes
                end,
            AccRes2 = [{Host, OrigRes} | AccRes],
            Td = html_history_td(Text, Res, "right"),
            {{cell, Res, Run, Td}, AccRes2}
    end.

html_config_href_td(HtmlFile, Text, skip) ->
    html_config_href_td(HtmlFile, Text, none);
html_config_href_td(HtmlFile, Text, Res) ->
    [
     "    ",
     "<td class=", atom_to_list(Res), "> ",
     html_config_href(HtmlFile,"", "#" ++ Text, Text),
     "</td>\n"
    ].

html_host_href_td(HtmlFile, Text, skip) ->
    html_host_href_td(HtmlFile, Text, none);
html_host_href_td(HtmlFile, Text, Res) ->
    [
     "    ",
     "<td class=", atom_to_list(Res), "> ",
     html_host_href(HtmlFile, "", "#" ++ Text, Text),
     "</td>\n"
    ].

html_history_table_td(Text, skip, Align) ->
    html_history_table_td(Text, none, Align);
html_history_table_td(Text, Res, Align) ->
    [
     "      ",
     "<td class=", atom_to_list(Res), " align=\"", Align, "\" rowspan=\"2\">",
     "<strong>", Text, "</strong>",
     "</td>\n"
    ].

html_history_td(Text, skip, Align) ->
    html_history_td(Text, none, Align);
html_history_td(Text, Res, Align) ->
    [
     "    ",
     "<td class=", atom_to_list(Res), " align=\"", Align, "\"> ",
     Text,
     "</td>\n"
    ].

multi_member([H | T], Files) ->
    case lists:member(H, Files) of
        true ->
            {true, H};
        false ->
            multi_member(T, Files)
    end;
multi_member([], _Files) ->
    false.

parse_summary_logs(HtmlFile, Dir, Acc) ->
    Cands = ["lux.skip",
             "lux_summary.log",
             "lux_summary.log.tmp",
             "qmscript.skip",
             "qmscript_summary.log",
             "qmscript_summary.log.tmp",
             "qmscript.summary.log"],
    do_parse_summary_logs(HtmlFile, Dir, Acc, Cands).

do_parse_summary_logs(HtmlFile, Dir, Acc, Cands) ->
    %% io:format("~s\n", [Dir]),
    case file:list_dir(Dir) of
        {ok, Files} ->
            case multi_member(Cands, Files) of
                {true, Base} ->
                    case lists:suffix(".log", Base) of
                        true ->
                            %% A summary log
                            File = filename:join([Dir, Base]),
                            SumA = #astate{log_dir=Dir, log_file=File},
                            io:format(".", []),
                            Res = parse_summary_log(false, SumA),
                            [parse_run_summary(HtmlFile, Res) | Acc];
                        false ->
                            io:format("s", []),
                            %% Skip
                            Acc
                    end;
                false ->
                    %% No interesting file found. Search subdirs
                    Fun =
                        fun("latest_run", A) ->
                                %% Symlink
                                A;
                           (File, A) ->
                                SubDir = filename:join([Dir, File]),
                                do_parse_summary_logs(HtmlFile, SubDir,
                                                      A, Cands)
                        end,
                    lists:foldl(Fun, Acc, Files)
            end;
        {error, _Reason} ->
            %% Not a dir or problem to read dir
            Acc
    end.

parse_run_summary(HtmlFile,
                  {ok, SummaryLog, SummaryRes, Groups, ArchConfig, FI}) ->
    Split =
        fun(Config) ->
                case binary:split(Config, <<": ">>, []) of
                    [Key, Val] ->
                        {true, {lux_utils:strip_trailing_whitespaces(Key),
                                Val}};
                    _          ->
                        false
                end
        end,
    Config = lists:zf(Split, binary:split(ArchConfig, <<"\n">>, [global])),
    Ctime =
        list_to_binary(lux_utils:datetime_to_string(FI#file_info.ctime)),
    StartTime = find_config(<<"start time">>, Config, Ctime),
    Host = find_config(<<"hostname">>, Config, ?DEFAULT_HOSTNAME),
    ConfigName0 = find_config(<<"architecture">>, Config, ?DEFAULT_CONFIG_NAME),
    ConfigName =
        if
            ConfigName0 =/= ?DEFAULT_CONFIG_NAME,
            ConfigName0 =/= <<"undefined">> ->
                ConfigName0;
            true ->
                find_config(<<"config name">>, Config, ?DEFAULT_CONFIG_NAME)
        end,
    Suite = find_config(<<"suite">>, Config, ?DEFAULT_SUITE),
    RunId = find_config(<<"run">>, Config, ?DEFAULT_RUN),
    ReposRev = find_config(<<"revision">>, Config, ?DEFAULT_REV),
    {ok, Cwd} = file:get_cwd(),
    RunDir = binary_to_list(find_config(<<"workdir">>,
                                        Config,
                                        list_to_binary(Cwd))),
    Cases = [parse_run_case(HtmlFile, RunDir, StartTime, Host, ConfigName,
                            Suite, RunId, ReposRev, Case) ||
                {test_group, _Group, Cases} <- Groups,
                Case <- Cases],
    HtmlDir = filename:dirname(HtmlFile),
    #run{test = Suite,
         id = RunId,
         result = run_result(SummaryRes),
         log = drop_prefix(HtmlDir, SummaryLog),
         start_time = StartTime,
         hostname = Host,
         config_name = ConfigName,
         run_dir = RunDir,
         repos_rev = ReposRev,
         details = Cases};
parse_run_summary(HtmlFile, {error, SummaryLog, _ReasonStr}) ->
    HtmlDir = filename:dirname(HtmlFile),
    {ok, Cwd} = file:get_cwd(),
    #run{test = ?DEFAULT_SUITE,
         id = ?DEFAULT_RUN,
         result = fail,
         log = drop_prefix(HtmlDir, SummaryLog),
         start_time = ?DEFAULT_TIME,
         hostname = ?DEFAULT_HOSTNAME,
         config_name = ?DEFAULT_CONFIG_NAME,
         run_dir = Cwd,
         repos_rev = ?DEFAULT_REV,
         details = []}.

parse_run_case(HtmlFile, RunDir, Start, Host, ConfigName,
               Suite, RunId, ReposRev,
               {test_case, Name, Log, _Doc, _HtmlLog, CaseRes}) ->
    HtmlDir = filename:dirname(HtmlFile),
    File = drop_prefix(RunDir, Name),
    File2 = drop_some_dirs(File),
    #run{test = <<Suite/binary, ":", File2/binary>>,
         id = RunId,
         result = run_result(CaseRes),
         log = drop_prefix(HtmlDir, Log),
         start_time = Start,
         hostname = Host,
         config_name = ConfigName,
         run_dir = RunDir,
         repos_rev = ReposRev,
         details = []};
parse_run_case(_HtmlFile, RunDir, Start, Host, ConfigName, Suite,
               RunId, ReposRev,
               {result_case, Name, Res, _Reason}) ->
    File = drop_prefix(RunDir, Name),
    File2 = drop_some_dirs(File),
    #run{test = <<Suite/binary, ":", File2/binary>>,
         id = RunId,
         result = run_result(Res),
         log = ?DEFAULT_LOG,
         start_time = Start,
         hostname = Host,
         config_name = ConfigName,
         run_dir = RunDir,
         repos_rev = ReposRev,
         details = []}.

drop_some_dirs(File) when is_binary(File) -> % BUGBUG: Temporary solution
    Q = <<"lux">>,
    Comp = filename:split(File),
    case lists:dropwhile(fun(E) -> E =/= Q end, Comp) of
        [Q | Rest] -> filename:join(Rest);
        _Rest      -> File
    end.

run_result({result, Res, _}) ->
    run_result(Res);
run_result({result, Res}) ->
    run_result(Res);
run_result(Res) ->
    case Res of
        success                                                -> success;
        {fail, _Script, _LineNo, _Expected, _Actual, _Details} -> fail;
        {error, _Reason}                                       -> fail;
        <<"SUCCESS">>                                          -> success;
        <<"SKIP", _/binary>>                                   -> skip;
        <<"FAIL", _/binary>>                                   -> fail;
        <<"ERROR", _/binary>>                                  -> fail
    end.

find_config(Key, Tuples, Default) ->
    case lists:keyfind(Key, 1, Tuples) of
        false         -> Default;
        {_, Hostname} -> Hostname
    end.

%% Keysort list of tuples and group items with same tag
%%
%% Items are returned in reverse order:
%%
%%   lux_html:keysplit(1, [{3,3},{3,1},{3,2},{1,1},{1,2},{2,2},{2,1},{1,3}]).
%%   [{1,[{1,3},{1,2},{1,1}]},
%%    {2,[{2,1},{2,2}]},
%%    {3,[{3,2},{3,1},{3,3}]}]

keysplit(Index, List) ->
    keysplit(Index, List, undefined).

keysplit(Index, List, Fun) ->
    do_keysplit(Index, lists:keysort(Index, List), Fun, [], []).

do_keysplit(Index, [H, N | T], Fun, Siblings, Acc)
  when element(Index, H) =:= element(Index, N) ->
    %% Collect items with same tag
    do_keysplit(Index, [N | T], Fun, [H | Siblings], Acc);
do_keysplit(Index, [H | T], Fun, Siblings, Acc) ->
    Siblings2 = [H | Siblings],
    Siblings3 =
        if
            Fun =:= undefined ->
                Siblings2;
            is_function(Fun, 2) ->
                lists:sort(Fun, Siblings2)
        end,
    do_keysplit(Index, T, Fun, [], [{element(Index, H), Siblings3} | Acc]);
do_keysplit(_Index, [], _Fun, [], Acc) ->
    lists:reverse(Acc).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Helpers

expand_lines([Line | Lines]) ->
    [Line, "\n", expand_lines(Lines)];
expand_lines([]) ->
    [].

html_div(Class, Html) ->
    [
     "\n<div class=",
     Class,
     "><pre>",
     html_cleanup(Html),
     "</pre></div>\n"
    ].

html_cleanup(List) ->
    Bin = list_to_binary([List]),
    Opts = [global],
    Bin2 = binary:replace(Bin, <<"&">>, <<"&amp;">>, Opts),
    Bin3 = binary:replace(Bin2, <<"<">>, <<"&lt;">>, Opts),
    Bin4 = binary:replace(Bin3, <<">">>, <<"&gt;">>, Opts),
    binary:replace(Bin4, <<"\"">>, <<"&quot;">>, Opts).

html_files(A, [{file, Path, OrigPath} | Files]) ->
    [
     "\n<br>",
     html_href("", drop_prefix(A, OrigPath), drop_prefix(A, Path)),
     html_files(A, Files)
    ];
html_files(_A, []) ->
    [].

unquote(Bin) ->
    Quote = <<"\"">>,
    Size = byte_size(Bin)-2,
    case Bin of
        <<Quote:1/binary, Plain:Size/binary, Quote:1/binary>> ->
            {quote, Plain};
        Plain ->
            {plain, Plain}
    end.

drop_prefix(#astate{log_dir=LogDir}, File) ->
    drop_prefix(LogDir, File);
drop_prefix(LogDir, File) when is_binary(File) ->
    list_to_binary(drop_prefix(LogDir, binary_to_list(File)));
drop_prefix(LogDir, File) when is_binary(LogDir) ->
    drop_prefix(binary_to_list(LogDir), File);
drop_prefix(LogDir, File) when is_list(LogDir), is_list(File) ->
    lux_utils:drop_prefix(LogDir, File).

orig_script(A, Script) ->
    orig_script(A, A#astate.log_file, Script).

orig_script(A, LogFile, Script) ->
    Dir = filename:dirname(drop_prefix(A, LogFile)),
    Base = filename:basename(binary_to_list(Script)),
    filename:join([A#astate.log_dir, Dir, Base ++ ".orig"]).

html_config_href(HtmlFile, Protocol, Name, Label) ->
    Name2 = insert_html_suffix(HtmlFile, Name, "_config"),
    html_href(Protocol, Name2, Label).

html_host_href(HtmlFile, Protocol, Name, Label) ->
    Name2 = insert_html_suffix(HtmlFile, Name, "_host"),
    html_href(Protocol, Name2, Label).

insert_html_suffix(HtmlFile, Name, Suffix) ->
    Ext = filename:extension(HtmlFile),
    BaseName = filename:basename(HtmlFile, Ext),
    BaseName ++ Suffix ++ Ext ++ Name.

html_href(Protocol, Name, Label) ->
    [
     "<a href=\"", Protocol, Name, "\">", Label, "</a>"
    ].

html_href("a", "", Protocol, Name, Label) ->
    ["\n",html_href(Protocol, Name, Label)];
html_href(Tag, Prefix, Protocol, Name, Label) when Tag =/= "" ->
    [
     "\n<", Tag, ">",
     Prefix, html_href(Protocol, Name, Label),
     "</", Tag, ">\n"
    ].

html_anchor(Name, Label) ->
    [
     "<a name=\"", Name, "\">", Label, "</a>"
    ].

html_anchor(Tag, Prefix, Name, Label) ->
    [
     "\n<", Tag, ">", Prefix, html_anchor(Name, Label), "</", Tag, ">\n"
    ].

html_header(Title) ->
    [
     <<"<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\" "
       "\"http://www.w3.org/TR/html4/strict.dtd\">\n">>,
     <<"<html>\n">>,
     <<"<head>\n">>,
     html_style(),
     <<"<title>">>, Title, <<"</title>\n">>,
     <<"</head>\n\n">>,
     <<"<body>">>
    ].

html_footer() ->
    <<"</body>\n">>.

html_style() ->
<<"
<style>
  body {
        color: #000000;
        background-color: white
  }

  div {
        <--- width: 300px; !--->
        overflow: auto;
        padding: 2px;
        border: 1px solid #b00;
        margin-left: 2%;
        margin-bottom: 2px;
        margin-top: 2px;
        color: #000000;
        background-color: #FFFFE0
  }

  div.annotate {
        font-weight: normal;
  }

  div.result {
  }

  div.config {
  }

  div.code {
        font-weight: bold;
        overflow: visible;
        padding: 0px;
        border: 0px;
        margin-left: 0%;
        margin-bottom: 0px;
        margin-top: 0px;
        color: #000000;
        background-color: white
  }

  div.send {
        background-color: #FFEC8B;
  }

  div.recv {
        background-color: #E9967A;
  }

  div.skip {
        background-color: #FFFFE0
  }

  div.match {
        background-color: #FFFFE0
  }

  div.expect {
        background-color: #FFFFE0
  }

  div.case {
        background-color: #D3D3D3
  }

  td.fail {
        background-color: #CC3333
  }

  td.secondary_fail {
        background-color: #F26C4F
  }

  td.none {
        background-color: #80FF80
  }

  td.success {
        background-color: #00A651
  }

  td.no_data {
        background-color: #FFFFFF
  }
  </style>

">>.
