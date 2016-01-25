-module(epush_opts).

%% API

-export([merge/2, g/2, g/3]).

%%------------------------------------------------------------------------------
%% @doc Merge Options
%% @end
%%------------------------------------------------------------------------------
merge(Defaults, Options) ->
  lists:foldl(
    fun({Opt, Val}, Acc) ->
      case lists:keymember(Opt, 1, Acc) of
        true  -> lists:keyreplace(Opt, 1, Acc, {Opt, Val});
        false -> [{Opt, Val}|Acc]
      end;
      (Opt, Acc) ->
        case lists:member(Opt, Acc) of
          true  -> Acc;
          false -> [Opt | Acc]
        end
    end, Defaults, Options).

%%------------------------------------------------------------------------------
%% @doc Get option
%% @end
%%------------------------------------------------------------------------------
g(Key, Options) ->
  proplists:get_value(Key, Options).

g(Key, Options, Default) ->
  proplists:get_value(Key, Options, Default).