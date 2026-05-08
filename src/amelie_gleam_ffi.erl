-module(amelie_gleam_ffi).
-export([read_file/1, int_to_string/1, get_env/1, now_ms/0,
         sha256_hex/1, memoria_total_mb/0, memoria_processos_mb/0,
         contagem_processos/0, spawn_fn/1, upload_file/3, debug_log/1,
         strip_timestamps/1, ytdlp_download/1]).

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
    binary:encode_hex(Hash, lowercase).

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
            Opts = [{timeout, 120000}, {connect_timeout, 10000}],
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

%% Baixa vídeo de URL usando yt-dlp para arquivo temporário.
%% Retorna {ok, CaminhoArquivo} | {error, MensagemErro}.
ytdlp_download(Url) ->
    Ts = integer_to_list(erlang:system_time(millisecond)),
    Dir = "/tmp/amelie_yt_" ++ Ts,
    file:make_dir(Dir),
    OutTemplate = Dir ++ "/video.%(ext)s",
    UrlStr = binary_to_list(Url),
    case os:find_executable("yt-dlp") of
        false ->
            {error, <<"yt-dlp não encontrado no PATH">>};
        YtdlpPath ->
            Port = open_port({spawn_executable, YtdlpPath}, [
                {args, [
                    "--no-playlist",
                    "--max-filesize", "50m",
                    "-f", "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720][ext=mp4]/best[height<=720]/best",
                    "--merge-output-format", "mp4",
                    "-o", OutTemplate,
                    UrlStr
                ]},
                exit_status,
                {line, 4096},
                stderr_to_stdout
            ]),
            ytdlp_wait(Port, Dir, [])
    end.

ytdlp_wait(Port, Dir, Acc) ->
    receive
        {Port, {data, {_, Line}}} ->
            ytdlp_wait(Port, Dir, [Line | Acc]);
        {Port, {exit_status, 0}} ->
            case filelib:wildcard(Dir ++ "/*") of
                [FilePath | _] -> {ok, list_to_binary(FilePath)};
                [] -> {error, <<"yt-dlp concluiu mas nenhum arquivo encontrado">>}
            end;
        {Port, {exit_status, _}} ->
            Output = iolist_to_binary(lists:join("\n", lists:reverse(Acc))),
            {error, <<"yt-dlp falhou: ", Output/binary>>}
    after 120000 ->
        port_close(Port),
        {error, <<"timeout ao baixar vídeo (120s)">>}
    end.

%% Debug: writes to stdout immediately (no buffering).
%% Retorna ok — Result(Nil, String) no Gleam.
debug_log(Msg) ->
    io:format(<<"DEBUG: ~s~n">>, [Msg]),
    ok.
