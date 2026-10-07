// shell/telegram_poller.gleam
// Poller assíncrono de updates do Telegram (long polling via OTP / BEAM).
// Permite recepção de mensagens sem depender de webhook ou IP público.

import adaptadores/telegram_webhook
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import logging
import shell/handler_mensagem.{type Portas}

const base_url = "https://api.telegram.org"

pub fn iniciar(bot_token: String, portas: Portas) -> Nil {
  case string.trim(bot_token) {
    "" -> Nil
    token -> {
      logging.log(logging.Info, "Iniciando Telegram poller (long polling)...")
      spawn_poller(token, 0, portas)
    }
  }
}

@external(erlang, "amelie_gleam_ffi", "spawn_fn")
fn spawn_fn(f: fn() -> a) -> Nil

fn spawn_poller(bot_token: String, offset: Int, portas: Portas) -> Nil {
  spawn_fn(fn() { loop(bot_token, offset, portas) })
}

fn loop(bot_token: String, offset: Int, portas: Portas) -> Nil {
  let url =
    base_url
    <> "/bot"
    <> bot_token
    <> "/getUpdates?timeout=25&offset="
    <> int.to_string(offset)

  case request.to(url) {
    Error(_) -> {
      process.sleep(2000)
      loop(bot_token, offset, portas)
    }
    Ok(req) -> {
      let req =
        req
        |> request.set_method(http.Get)
      case httpc.send(req) {
        Ok(resp) if resp.status == 200 -> {
          case telegram_webhook.extrair_updates(resp.body) {
            Ok(updates) -> {
              let proximo_offset = processar_updates(updates, offset, portas)
              loop(bot_token, proximo_offset, portas)
            }
            Error(_) -> {
              logging.log(
                logging.Warning,
                "Telegram poller: falha ao extrair updates",
              )
              process.sleep(1000)
              loop(bot_token, offset, portas)
            }
          }
        }
        Ok(resp) if resp.status == 409 -> {
          case string.contains(resp.body, "webhook is active") {
            True -> {
              logging.log(
                logging.Info,
                "Telegram poller: webhook ativo, polling desativado.",
              )
              Nil
            }
            False -> {
              logging.log(
                logging.Warning,
                "Telegram poller: conflito 409 (outra instância ativa). Aguardando 5s...",
              )
              process.sleep(5000)
              loop(bot_token, offset, portas)
            }
          }
        }
        Ok(resp) -> {
          logging.log(
            logging.Warning,
            "Telegram poller: status inesperado " <> int.to_string(resp.status),
          )
          process.sleep(2000)
          loop(bot_token, offset, portas)
        }
        Error(_) -> {
          // Erro de rede ou timeout de conexão — normal em conexões long-polling
          process.sleep(1000)
          loop(bot_token, offset, portas)
        }
      }
    }
  }
}

pub fn processar_updates(
  updates: List(telegram_webhook.UpdateItem),
  offset_atual: Int,
  portas: Portas,
) -> Int {
  list.fold(updates, offset_atual, fn(maior_offset, item) {
    case item.mensagem {
      Some(msg) -> {
        spawn_fn(fn() {
          let _ = handler_mensagem.handle(msg, portas)
          Nil
        })
      }
      None -> Nil
    }
    int.max(maior_offset, item.update_id + 1)
  })
}
