FROM ghcr.io/gleam-lang/gleam:v1.5.1-erlang-alpine AS builder

WORKDIR /app
COPY gleam.toml manifest.toml ./
RUN gleam deps download

COPY src ./src
RUN gleam build

# ---------------------------------------------------------------------------
FROM erlang:27-alpine

RUN apk add --no-cache sqlite-libs

WORKDIR /app
COPY --from=builder /app/build/erlang-shipment ./build/erlang-shipment

RUN mkdir -p /data

EXPOSE 4000

CMD ["/app/build/erlang-shipment/entrypoint.sh", "run", "amelie_gleam"]
