FROM ghcr.io/gleam-lang/gleam:v1.14.0-erlang AS builder

WORKDIR /app
COPY gleam.toml ./
RUN gleam deps download

COPY src ./src
COPY config ./config
RUN apt-get update && \
    apt-get install -y --no-install-recommends build-essential libsqlite3-dev sqlite3 ca-certificates && \
    gleam build --target erlang && \
    gleam export erlang-shipment && \
    rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
FROM erlang:27

RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-0 sqlite3 ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app/build/prod/erlang ./build/prod/erlang
COPY --from=builder /app/config ./config

RUN mkdir -p /data

EXPOSE 4000

CMD ["sh", "-lc", "exec erl -pa /app/build/prod/erlang/*/ebin -eval \"'amelie_gleam@@main':run(amelie_gleam).\" -noshell"]
