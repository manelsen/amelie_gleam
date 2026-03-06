-module(amelie_gleam_ffi).
-export([read_file/1, int_to_string/1, get_env/1]).

%% Lê arquivo do disco.
%% Retorna {ok, Binary} | {error, Binary} — Result(BitArray, String) no Gleam.
read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

int_to_string(N) ->
    list_to_binary(integer_to_list(N)).

%% Lê variável de ambiente.
%% Retorna {ok, Binary} | {error, nil} — Result(String, Nil) no Gleam.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.
