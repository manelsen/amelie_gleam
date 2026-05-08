FROM golang:alpine AS builder

RUN apk add --no-cache gcc musl-dev libc-dev

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 GOOS=linux go build -o bridge .

# ---------------------------------------------------------------------------
FROM alpine:3.19

RUN apk add --no-cache sqlite-libs ca-certificates ffmpeg

WORKDIR /app
COPY --from=builder /app/bridge .

RUN mkdir -p /app/db

EXPOSE 8080

CMD ["/app/bridge"]
