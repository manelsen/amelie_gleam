# Stage 1: Build do bridge Go (pure Go, sem CGO)
FROM golang:alpine AS go-builder

WORKDIR /bridge
COPY whatsmeow-bridge/go.mod whatsmeow-bridge/go.sum ./
RUN go mod download

COPY whatsmeow-bridge/ .
RUN CGO_ENABLED=0 GOOS=linux go build -o bridge .

# ---------------------------------------------------------------------------
# Stage 2: Build da aplicação Gleam
FROM ghcr.io/gleam-lang/gleam:v1.14.0-erlang-alpine AS gleam-builder

WORKDIR /app
COPY gleam.toml ./
RUN gleam deps download

COPY src ./src
COPY config ./config
RUN apk add --no-cache build-base sqlite-dev sqlite && \
    gleam build --target erlang && \
    gleam export erlang-shipment

# ---------------------------------------------------------------------------
# Stage 3: Imagem final — mesma base Erlang do builder (evita mismatch de OTP)
FROM ghcr.io/gleam-lang/gleam:v1.14.0-erlang-alpine

RUN apk add --no-cache sqlite-libs ca-certificates

WORKDIR /app

COPY --from=gleam-builder /app/build/erlang-shipment ./build/erlang-shipment
COPY --from=gleam-builder /app/config ./config
COPY --from=go-builder /bridge/bridge /usr/local/bin/amelie-bridge

RUN mkdir -p /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4000

CMD ["/entrypoint.sh"]
