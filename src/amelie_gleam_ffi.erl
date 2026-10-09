-module(amelie_gleam_ffi).
-include_lib("kernel/include/file.hrl").
-export([read_file/1, int_to_string/1, get_env/1, now_ms/0,
         sha256_hex/1, memoria_total_mb/0, memoria_processos_mb/0,
         contagem_processos/0, spawn_fn/1, upload_file/3, debug_log/1,
         strip_timestamps/1, ytdlp_download/1, video_tem_audio/1,
         constant_time_equal/2, validate_bridge_media/1, read_bridge_media/1,
         cache_key/3, write_private_media/1, limpar_midias_antigas/1,
         delete_file/1]).

%% Lê arquivo do disco.
%% Retorna {ok, Binary} | {error, Binary} — Result(BitArray, String) no Gleam.
read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

int_to_string(N) ->
    list_to_binary(integer_to_list(N)).

%% Retorna timestamp atual em milissegundos.
now_ms() ->
    erlang:system_time(millisecond).

%% SHA-256 do dado como string hexadecimal minúscula.
sha256_hex(Data) ->
    Hash = crypto:hash(sha256, Data),
    string:lowercase(binary:encode_hex(Hash)).

%% Serialização estrutural inclui TODOS os argumentos que chegam ao provedor.
cache_key(Prompt, History, Model) ->
    sha256_hex(term_to_binary({cache_v2, Prompt, History, Model})).

constant_time_equal(A, B) ->
    crypto:hash_equals(crypto:hash(sha256, A), crypto:hash(sha256, B)).

%% Nunca aceita caminhos arbitrários do payload nem links no spool privado.
validate_bridge_media(Path) when is_binary(Path) ->
    Root = media_root(),
    Name = binary_to_list(Path),
    Base = filename:basename(Name),
    ValidName = re:run(Base, "^amelie_midia_[a-zA-Z0-9_.-]+$", [{capture, none}]) =:= match,
    case filename:pathtype(Root) =:= absolute andalso
         filename:dirname(Name) =:= Root andalso
         filename:join(Root, Base) =:= Name andalso ValidName of
        false -> {error, <<"caminho de mídia não permitido"/utf8>>};
        true ->
            case {file:read_link_info(Root), file:read_link_info(Name)} of
                {{ok, #file_info{type = directory, mode = Mode}},
                 {ok, #file_info{type = regular, links = 1, size = Size}}}
                    when Mode band 8#777 =:= 8#700, Size =< 50 * 1024 * 1024 ->
                    {ok, Path};
                _ -> {error, <<"arquivo de mídia não permitido"/utf8>>}
            end
    end.

media_root() ->
    case os:getenv("MEDIA_TEMP_DIR") of
        false -> "/tmp/amelie-media";
        "" -> "/tmp/amelie-media";
        Value -> Value
    end.

%% Arquivos internos nunca incorporam IDs externos nem timestamps previsíveis.
write_private_media(Data) when byte_size(Data) =< 50 * 1024 * 1024 ->
    Root = media_root(),
    case filename:pathtype(Root) of
        absolute ->
            case file:make_dir(Root) of
                ok -> _ = file:change_mode(Root, 8#700);
                _ -> ok
            end,
            case file:read_link_info(Root) of
                {ok, #file_info{type = directory, mode = Mode}} when Mode band 8#777 =:= 8#700 ->
                    Name = "amelie_local_" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16))),
                    Path = filename:join(Root, Name),
                    case file:open(Path, [write, binary, exclusive, raw]) of
                        {ok, File} ->
                            Result = case file:change_mode(Path, 8#600) of
                                ok -> file:write(File, Data);
                                Error -> Error
                            end,
                            Closed = file:close(File),
                            case {Result, Closed} of
                                {ok, ok} -> {ok, list_to_binary(Path)};
                                _ -> _ = file:delete(Path), {error, <<"falha ao gravar mídia temporária"/utf8>>}
                            end;
                        _ -> {error, <<"falha ao criar mídia temporária"/utf8>>}
                    end;
                _ -> {error, <<"diretório de mídia não é privado"/utf8>>}
            end;
        _ -> {error, <<"diretório de mídia deve ser absoluto"/utf8>>}
    end;
write_private_media(_) -> {error, <<"mídia excede 50 MiB"/utf8>>}.

%% O diretório 0700 é escrito apenas pelo bridge, com nomes aleatórios.
%% Revalida no momento da leitura e só remove após uma leitura bem-sucedida.
read_bridge_media(Path) ->
    case validate_bridge_media(Path) of
        {ok, Path} ->
            case read_file(Path) of
                {ok, Data} ->
                    _ = file:delete(Path),
                    {ok, Data};
                Error -> Error
            end;
        Error -> Error
    end.

%% Remove arquivo do disco. Retorna {ok, nil} | {error, Reason}.
delete_file(Path) when is_binary(Path) ->
    case file:delete(Path) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end;
delete_file(Path) when is_list(Path) ->
    case file:delete(Path) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end;
delete_file(_) ->
    {error, <<"caminho inválido"/utf8>>}.

%% Varre o diretório de mídias temporárias e remove arquivos órfãos (amelie_midia_*
%% ou amelie_local_*) cuja idade em segundos seja maior ou igual a MaxAgeSeconds.
%% Retorna {ok, QuantidadeRemovida} | {error, Reason}.
limpar_midias_antigas(MaxAgeSeconds) when is_integer(MaxAgeSeconds), MaxAgeSeconds >= 0 ->
    Root = media_root(),
    case file:list_dir(Root) of
        {ok, Filenames} ->
            NowSecs = calendar:datetime_to_gregorian_seconds(erlang:universaltime()),
            Deleted = lists:foldl(
                fun(Name, Count) ->
                    case is_media_temp_file(Name) of
                        true ->
                            FullPath = filename:join(Root, Name),
                            case file:read_link_info(FullPath, [{time, universal}]) of
                                {ok, #file_info{type = regular, mtime = Mtime}} ->
                                    FileSecs = calendar:datetime_to_gregorian_seconds(Mtime),
                                    Age = NowSecs - FileSecs,
                                    case Age >= MaxAgeSeconds of
                                        true ->
                                            case file:delete(FullPath) of
                                                ok -> Count + 1;
                                                _ -> Count
                                            end;
                                        false -> Count
                                    end;
                                _ -> Count
                            end;
                        false -> Count
                    end
                end,
                0,
                Filenames
            ),
            {ok, Deleted};
        {error, enoent} ->
            {ok, 0};
        {error, Reason} ->
            {error, atom_to_binary(Reason, utf8)}
    end;
limpar_midias_antigas(_) ->
    {error, <<"idade máxima inválida"/utf8>>}.

is_media_temp_file(Name) ->
    (lists:prefix("amelie_midia_", Name) orelse lists:prefix("amelie_local_", Name))
    andalso filename:basename(Name) =:= Name.

%% Métricas de memória e processos BEAM.
memoria_total_mb() ->
    erlang:memory(total) div (1024 * 1024).

memoria_processos_mb() ->
    erlang:memory(processes) div (1024 * 1024).

contagem_processos() ->
    erlang:system_info(process_count).

%% Faz upload multipart de arquivo para a Gemini File API.
%% Retorna {ok, ResponseBody} | {error, Reason}.
upload_file(ApiKey, FilePath, MimeType) ->
    inets:start(),
    ssl:start(),
    case file:read_file(FilePath) of
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)};
        {ok, FileData} ->
            Boundary = "gc0p4Jq0M2Yt08jU534c0p",
            BoundaryBin = list_to_binary(Boundary),
            MetaJson = iolist_to_binary([
                <<"{\"file\":{\"mimeType\":\"">>, MimeType, <<"\"}}">>
            ]),
            Body = iolist_to_binary([
                <<"--">>, BoundaryBin, <<"\r\n">>,
                <<"Content-Type: application/json; charset=utf-8\r\n\r\n">>,
                MetaJson, <<"\r\n">>,
                <<"--">>, BoundaryBin, <<"\r\n">>,
                <<"Content-Type: ">>, MimeType, <<"\r\n\r\n">>,
                FileData, <<"\r\n">>,
                <<"--">>, BoundaryBin, <<"--\r\n">>
            ]),
            URL = "https://generativelanguage.googleapis.com/upload/v1beta/files?key="
                  ++ binary_to_list(ApiKey),
            Headers = [{"x-goog-upload-protocol", "multipart"}],
            ContentType = "multipart/related; boundary=" ++ Boundary,
            Opts = [{timeout, 120000}, {connect_timeout, 10000},
                    {autoredirect, false},
                    {ssl, [{verify, verify_peer}, {cacerts, public_key:cacerts_get()},
                           {server_name_indication, "generativelanguage.googleapis.com"},
                           {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}],
            case httpc:request(post, {URL, Headers, ContentType, Body}, Opts, []) of
                {ok, {{_, 200, _}, _, RespBody}} ->
                    {ok, list_to_binary(RespBody)};
                {ok, {{_, Status, _}, _, RespBody}} ->
                    Msg = iolist_to_binary([
                        <<"upload status ">>, integer_to_list(Status),
                        <<": ">>, list_to_binary(RespBody)
                    ]),
                    {error, Msg};
                {error, Reason} ->
                    Msg = list_to_binary(io_lib:format("~p", [Reason])),
                    {error, Msg}
            end
    end.

%% Spawna função em processo isolado (sem link).
spawn_fn(F) ->
    erlang:spawn(F),
    nil.

%% Lê variável de ambiente.
%% Retorna {ok, Binary} | {error, nil} — Result(String, Nil) no Gleam.
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.

%% Remove timestamps MM:SS ou HH:MM:SS (com espaço opcional ao redor).
strip_timestamps(Text) ->
    {ok, Re} = re:compile(<<"\\s*\\d{1,2}:\\d{2}(?::\\d{2})?\\s*">>),
    re:replace(Text, Re, <<" ">>, [global, {return, binary}]).

%% Extratores externos podem abrir conexões que escapam da validação da URL
%% inicial. Só reativar num serviço com política de egress própria.
ytdlp_download(_Url) ->
    {error, <<"Downloads de links de vídeo estão desativados por segurança. Envie o arquivo de vídeo diretamente."/utf8>>}.

%% Debug: writes to stdout immediately (no buffering).
%% Retorna ok — Result(Nil, String) no Gleam.
debug_log(Msg) ->
    io:format(<<"DEBUG: ~s~n">>, [Msg]),
    ok.

%% Verifica se o arquivo de vídeo possui faixa/stream de áudio.
%% Retorna true | false.
video_tem_audio(Path) ->
    case os:find_executable("ffprobe") of
        false ->
            true;
        Ffprobe ->
            try open_port({spawn_executable, Ffprobe}, [
                {args, ["-v", "error", "-protocol_whitelist", "file",
                        "-select_streams", "a:0", "-show_entries", "stream=codec_type",
                        "-of", "default=nw=1:nk=1", "-i", binary_to_list(Path)]},
                binary, exit_status, use_stdio, stderr_to_stdout
            ]) of
                Port -> ffprobe_wait(Port, <<>>, erlang:monotonic_time(millisecond) + 10000)
            catch error:_ -> false
            end
    end.

ffprobe_wait(Port, Acc, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} when byte_size(Acc) + byte_size(Data) =< 4096 ->
            ffprobe_wait(Port, <<Acc/binary, Data/binary>>, Deadline);
        {Port, {data, _}} ->
            catch port_close(Port),
            false;
        {Port, {exit_status, 0}} -> string:trim(Acc) =:= <<"audio">>;
        {Port, {exit_status, _}} -> false
    after Remaining ->
        catch port_close(Port),
        false
    end.

