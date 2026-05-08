# Stage 1: Build do bridge Go (pure Go, sem CGO)
FROM golang:alpine AS go-builder

RUN apk add --no-cache gcc musl-dev

WORKDIR /bridge
COPY whatsmeow-bridge/go.mod whatsmeow-bridge/go.sum ./
RUN go mod download

COPY whatsmeow-bridge/ .
RUN CGO_ENABLED=0 GOOS=linux go build -o bridge .

# ---------------------------------------------------------------------------
# Stage 2: Build da aplicação Gleam
FROM ghcr.io/gleam-lang/gleam:v1.15.0-erlang-alpine AS gleam-builder

WORKDIR /app

RUN apk add --no-cache build-base sqlite-dev sqlite ccache

COPY gleam.toml manifest.toml ./
RUN gleam deps download

COPY src ./src
COPY config ./config
# ccache evita recompilar o NIF do esqlite3 (~48s) quando o fonte C não muda.
ENV CC="ccache gcc"
RUN --mount=type=cache,target=/root/.cache/ccache \
    gleam export erlang-shipment

# ---------------------------------------------------------------------------
# Stage 3: Imagem final — mesma base Erlang do builder (evita mismatch de OTP)
FROM ghcr.io/gleam-lang/gleam:v1.15.0-erlang-alpine

RUN apk add --no-cache sqlite-libs ca-certificates python3 py3-pip ffmpeg && \
    pip3 install --break-system-packages yt-dlp

WORKDIR /app

COPY --from=gleam-builder /app/build/erlang-shipment ./build/erlang-shipment
COPY --from=gleam-builder /app/config ./config
COPY --from=go-builder /bridge/bridge /usr/local/bin/amelie-bridge

RUN mkdir -p /data

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4000

CMD ["/entrypoint.sh"]
