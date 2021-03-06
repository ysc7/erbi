%%% -*- coding:utf-8; Mode: erlang; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*-
%%% ex: set softtabstop=4 tabstop=4 shiftwidth=4 expandtab fileencoding=utf-8:
-module(erbi_temp_db_helpers).
-include("erbi.hrl").

% Helper functions for drivers implementing
% erbi_temp_db behaviour
-export([create_dir/1,
         del_dir/1,
         kill_db_pid/2,
         get_free_db_port/2,
         save_in_db_data_file/3,
         read_integer/2,
         find_bin_dir/3,
         search_dirs/2,
         wait_for/4,
         getenv/2,
         exec_cmd/2, exec_cmd/3, exec_cmd/4
	]).


% Helper functions for drivers implementing
% erbi_temp_db behaviour

create_dir(Dir)->
    os:cmd("mkdir -p "++ Dir).


del_dir(Dir) ->
   lists:foreach(fun(D) ->
                         io:format(standard_error,"del_dir ~p~n",[D]),
                         ok = file:del_dir(D)
                 end, del_all_files([Dir], [])).

del_all_files([], EmptyDirs) ->
    EmptyDirs;
del_all_files([Dir | T], EmptyDirs) ->
    io:format(standard_error,"deleting files in ~p~n",[Dir]),
    {ok, FilesInDir} = file:list_dir(Dir),
    {Files, Dirs} = lists:foldl(fun(F, {Fs, Ds}) ->
                                        Path = Dir ++ "/" ++ F,
                                        case filelib:is_dir(Path) of
                                            true ->
                                                {Fs, [Path | Ds]};
                                            false ->
                                                {[Path | Fs], Ds}
                                        end
                                end, {[],[]}, FilesInDir),
    case search_dirs([],"sh") of
        {ok,Path} ->
            exec_cmd(Path++"/sh",["-c","rm " ++ Dir ++ "/* " ++ Dir ++ "/.*" ++ " 2> /dev/null"]);
        _ ->
            lists:foreach(fun(F) ->
                                  ok = file:delete(F)
                          end, Files)
    end,
    del_all_files(T ++ Dirs, [Dir | EmptyDirs]).

kill_db_pid(Dir,PidFile)->
    case read_integer(Dir,PidFile) of
        {error,_} = Error ->
            Error;
         Pid ->
            os:cmd("kill -9 "++integer_to_list(Pid)),
            ok
        end.


get_free_db_port(MinPort,MaxPort)->
    StartingPort=trunc(random:uniform()*(MaxPort-MinPort))+MinPort,
    get_free_db_port(StartingPort+1,StartingPort,MinPort,MaxPort).

get_free_db_port(Port,StartingPort,MinPort,MaxPort) when Port > MaxPort->
    get_free_db_port(MinPort,StartingPort,MinPort,MaxPort);
get_free_db_port(Port,StartingPort,_MinPort,_MaxPort) when Port == StartingPort ->
    {error,no_free_port};
get_free_db_port(Port,StartingPort,MinPort,MaxPort) ->
    case gen_tcp:listen(Port,[]) of
       {ok,TmpSock}->
            gen_tcp:close(TmpSock),
            {ok,Port};
        _ ->
            get_free_db_port(Port+1,StartingPort,MinPort,MaxPort)
      end.

save_in_db_data_file(Term,Path,File)->
                                                %file:write_file(Path++"/"++File,term_to_binary(Term)).
    ok = file:write_file(Path++"/"++File,io_lib:fwrite("~p\n",[Term])).

read_integer(Path,File)->
    case file:read_file(Path++"/"++File) of
        {ok, Binary} ->
            to_integer(Binary);
        Any ->
            Any
    end.

to_integer(Binary)->
    [Value] = string:tokens(binary_to_list(Binary), "\n" ),
    list_to_integer(Value).

find_bin_dir(#erbi{properties=Props}=DataSource,Candidates,File) ->
    case getenv(DataSource,bin) of
        false ->
            search_dirs([proplists:get_value(bin_dir,Props,"") | Candidates],File);
        EnvFile ->
            {ok,EnvFile}
    end.

search_dirs(PossiblePaths,Filename)->
    SearchPath = PossiblePaths ++ get_os_path(),
    case lists:filter(fun(Path)->
                              filelib:is_file(Path++"/"++Filename)
                      end,SearchPath) of
        []->
            {error,{not_found,Filename,{search_path,SearchPath}}};
        [H|_]->
            {ok,H}
    end.

get_os_path()->
    StrPaths=os:getenv("PATH"),
    string:tokens(StrPaths,":").

wait_for(_Fun,Error,_Interval,0 ) ->
    Error;
wait_for(Fun,Error, Interval, Tries) ->
    case Fun() of
        wait ->
            receive
            after Interval->
                    wait_for(Fun,Error,Interval,Tries-1)
            end;
        Any->
            Any
    end.

getenv(#erbi{driver=Driver},Key) ->
    EnvName = "ERBI_TEMPDB_" ++ string:to_upper(atom_to_list(Key) ++ "_" ++ atom_to_list(Driver)),
    os:getenv(EnvName).

%%@doc execute command, returning OS PID
%%
%% Arguments:
%%
%%@end
-type exec_cmd_return() :: {ok,{os_pid,integer()},any()} |
                           {ok,{exit_status,integer()},any()} |
                           {error,any()}.
-type exec_cmd_scanfn() :: fun( (string(),any()) -> any() ).

-spec exec_cmd( Command :: unicode:chardata(),
                Args :: [unicode:chardata()] ) -> exec_cmd_return().

exec_cmd( Command, Args ) ->
    exec_cmd(Command,Args,wait).

-spec exec_cmd( Command :: unicode:chardata(),
                Args :: [unicode:chardata()],
                wait | nowait | {exec_cmd_scanfn(),any()}
              ) -> exec_cmd_return().


exec_cmd( Command, Args, wait ) ->
    WaitScanner =
        fun(_Data,_Acc) ->
                undefined %returning undefined means output processor goes until exit.
        end,
    exec_cmd( Command, Args, {WaitScanner,undefined}, standard_error );
exec_cmd( Command, Args, nowait ) ->
    NoWaitScanner =
        fun(_Data,_Acc) ->
                {ok,undefined} % returning {ok,Acc} ends scanning phase
        end,
    exec_cmd( Command, Args, {NoWaitScanner,undefined}, standard_error );
exec_cmd( Command, Args, {Scanner,Acc} ) ->
    exec_cmd( Command, Args, {Scanner,Acc}, standard_error ).


%%@doc execute command, with processing of output
%%
%% Allows a command to be executed, while capturing the OS pid or exit status, and the output.
%% Output can be printed or logged, and can also be scanned or collected.
%% Arguments:
%% <ul>
%%   <li>Command: absolute path to executable</li>
%%   <li>Args: List of arguments; these do not need to be quoted or escaped; command is exec'ed
%%       directly.</li>
%%   <li>Scanner -- output parser/accumulator, and flow control function.  See below.</li>
%%   <li>Logger -- output/logging control.  Can be:
%%     <ul><li>A device, like the first arg of io:format/3</li>
%%         <li>A fun, accepting string(); will be called for all output of Command;
%%             return is ignored.</li>
%%         <li>'none'</li>
%%     </ul></li>
%% </ul>
%% Return values:
%% <ul>
%%   <li>{ok,{os_pid,Pid},Acc} -- Acc is the accumulated output of Scanner (q.v.)</li>
%%   <li>{ok,{exit_status,Status},Acc}</li>
%%   <li>{error,Reason}</li>
%% </ul>
%%
%% Scanner
%%
%% The scanner argument is a pair of {Scanner,InitAcc}.  Scanner takes two arguments:
%% <ul>
%%   <li>Data: string() -- a chunk of output from the command.</li>
%%   <li>Acc: any() -- accumulator; starts with InitAcc</li>
%% </ul>
%% Scanner returns one of:
%% <ul>
%%   <li>{ok,Acc} -- exec_cmd will return immediately, with {ok,{os_pid,Pid},Acc}</li>
%%   <li>{error,Reason} -- exec_cmd returns immediately with this value</li>
%%   <li>{acc,Acc} -- continue processing output, with new accumulator value</li>
%% </ul>
%% Scanner can also accept 'wait' and 'nowait' which make the function wait (or not) for
%% Command to finish; output Acc will be 'undefined'.ls
%%@end

-spec exec_cmd( Command :: unicode:chardata(),
                Args :: [unicode:chardata()],
                wait | nowait | {exec_cmd_scanfn(),any()},
                none | io:device()
              ) -> exec_cmd_return().


exec_cmd( Command, Args, {Scanner,Acc}, Output ) ->
    StrCmd = string:join( lists:map( fun unicode:characters_to_list/1,
                                     [Command|Args] ), " " ),
    OutFun =
        case Output of
            none ->
                fun(_) ->
                        ok
                end;
            H when is_atom(H) ->
                fun(Fmt,Dat) ->
                        io:format(Output,Fmt,Dat)
                end
        end,
    TopPid = self(),
    {SpawnPid,_Mon} =
        spawn_monitor(
          fun() ->
                  OutFun("Executing ~s: ",[StrCmd]),
                  Port =
                      open_port
                        ( {spawn_executable,
                           unicode:characters_to_list(Command)},
                        %{spawn,StrCmd},
                          [{args,lists:map
                                   ( fun unicode:characters_to_binary/1, Args )},
                           stream,use_stdio,stderr_to_stdout,exit_status,
                           {cd, filename:absname("")} ] ),
                  {os_pid,OSPid} = erlang:port_info(Port,os_pid),
                  TopPid ! {{self(),undefined},{os_pid,OSPid}},
                  Ret = port_loop(Port,TopPid,{self(),OSPid},OutFun),
                  OutFun("'~s' terminated: ~p~n",[StrCmd,Ret])
          end),
    output_loop( SpawnPid, Scanner, Acc ).

output_loop( SpawnPid, Scanner, Acc ) ->
    output_loop( SpawnPid, undefined, Scanner, Acc ).

output_loop(SpawnPid,OSPid,Scanner,Acc) ->
    receive
        {{SpawnPid,OSPid},{os_pid,OSPid1}} ->
            output_loop(SpawnPid,OSPid1,Scanner,Acc,{data,""});
        {{SpawnPid,OSPid},Msg} ->
            output_loop(SpawnPid,OSPid,Scanner,Acc,Msg);
        {'DOWN',_,process,SpawnPid,Reason} ->
            case OSPid of
                undefined -> {error,{exec_failed,Reason}};
                _ ->         {error,{unexpected_termination,Reason}}
            end;
        {'DOWN',_,process,_,_} ->
            output_loop(SpawnPid,OSPid,Scanner,Acc);
        {{_OtherPid,_},_} ->
            output_loop(SpawnPid,OSPid,Scanner,Acc)
    after 1000 ->
            case OSPid of
                undefined -> {error,timeout};
                _ ->
                    output_loop(SpawnPid,OSPid,Scanner,Acc)
            end
    end.

output_loop(SpawnPid,OSPid,Scanner,Acc,Msg) ->
    case Msg of
        {data,Data} ->
            case Scanner(Data,Acc) of
                {ok,Acc1} ->
                    {ok,{os_pid,OSPid},Acc1};
                {error,Reason} ->
                    {error,Reason};
                Acc2 ->
                    output_loop(SpawnPid,OSPid,Scanner,Acc2)
            end;
        {exit_status,Status} ->
            {ok,{exit_status,Status},Acc};
        Other ->
            Other
    end.


port_loop(Port,Parent,Ident,Logger) ->
    receive
        {Port,{data,Data}} ->
            Parent ! {Ident,{data,Data}},
            Logger("~s",[Data]),
            port_loop(Port,Parent,Ident,Logger);
        {Port,{exit_status,Status}} ->
            Parent ! {Ident,{exit_status,Status}},
            {exit_status,Status};
        {'EXIT',Port,Reason}->
            Parent ! {Ident,{error,Reason}},
            {port_terminated,Reason};
        {Port,closed} ->
            Parent ! {Ident,{error,port_closed}},
            {port_terminated,closed};
        Other ->
            Parent ! {Ident,{error,{unhandled_message,Other}}},
            {unhandled_message,Other}
    after 1000 ->
            case erlang:port_info(Port) of
                undefined ->
                    Parent ! {Ident,{error,port_gone}},
                    {error,port_gone};
                _ ->
                    port_loop(Port,Parent,Ident,Logger)
            end
    end.

