# Correções de segurança

Base analisada: `bcdb5dfd632a6c7a01929f8c0ab43a3a93c72693`.

## Vetores tratados

| Problema | Correção | Evidência de regressão |
|---|---|---|
| Webhooks permitiam forjar mensagens e eventos sem credenciais | Segredo obrigatório entre bridge e Gleam; webhook Telegram fechado quando não configurado; POST obrigatório | Testes HTTP reais: 401 sem credenciais, 405 para método indevido, 200/202 para envelopes legítimos |
| Endpoints do bridge permitiam enviar mensagens, parear e resetar a sessão sem autenticação | Autenticação em todas as rotas; escuta local por padrão; pareamento somente por POST; limites de corpo e tempo | Testes Go de todas as rotas, envio autenticado e rejeição de redirecionamento que poderia expor o segredo |
| `caminho_temp` permitia ler e apagar arquivos arbitrários | Diretório privado, nomes restritos, arquivos regulares sem links, limite de 50 MiB, validação antes de aceitar e antes de ler | Testes de caminho externo, `..`, symlink e hard link; arquivo externo permanece intacto |
| Nome de arquivo chegava ao shell em `video_tem_audio` | `ffprobe` executado diretamente com vetor de argumentos, protocolo de arquivo, limite de saída e de espera | A mesma reprodução local executa um comando no código original e deixa de executá-lo no corrigido |
| URLs de mensagens podiam alcançar serviços internos | Busca pelo bridge com validação de IP na conexão, sem segunda resolução DNS, verificação a cada redirecionamento, portas padrão, TLS, limite de 1 MiB e 15 segundos | Testes IPv4/IPv6, loopback, rede privada, metadados de nuvem, DNS misto, redirecionamento e resposta grande |
| Extratores de vídeos podiam abrir conexões fora dessa validação | Download por `yt-dlp` desativado e removido da imagem; resposta orienta envio do arquivo | Teste confirma rejeição sem iniciar o extrator |
| Cache podia reutilizar resposta baseada em histórico privado diferente | Chave estrutural inclui prompt, histórico completo com papéis e modelo | Teste com duas conversas e mesmo prompt recebe a resposta correspondente a cada histórico |
| Temporários internos usavam timestamp/ID externo no nome | Nomes aleatórios, criação exclusiva, diretório 0700 e arquivo 0600 | Teste verifica nomes distintos, conteúdo separado e permissões |
| Administrador padrão embutido e autorização por chat **ou** remetente | Sem administrador implícito; exige ID configurado, remetente e chat correspondentes, em conversa privada | Testes de remetente divergente, chat divergente, grupo e ausência de configuração |

Também foram explicitadas a verificação TLS e a proibição de redirecionamento no
upload Erlang para Gemini. O `manifest.toml` foi incluído para fixar as dependências
da aplicação e permitir o `COPY` já exigido pelo Dockerfile. O laço do entrypoint
agora reinicia o bridge mesmo quando ele sai com código diferente de zero.

## Antes de atualizar

1. Gere `BRIDGE_TOKEN` com `openssl rand -hex 32` e configure o mesmo valor no
   bridge e no Gleam. No Compose, ambos recebem o `.env` do mesmo serviço.
2. Configure seu `TELEGRAM_ADMIN_CHAT_ID` se desejar administração remota.
   Sem ele, os comandos administrativos ficam desabilitados.
3. Para Telegram por webhook, registre um `secret_token` junto ao Telegram e use
   o mesmo valor em `TELEGRAM_SECRET_TOKEN`. Sem segredo, apenas o recebimento por
   webhook fica fechado; polling continua disponível.
4. Revise a exposição HTTP: o Compose agora publica apenas em `127.0.0.1:4001`.
   Um proxy público deve expor somente `/webhook/telegram`, com HTTPS.
5. Mídias pendentes no caminho antigo `/tmp/amelie_midia_*` precisarão ser
   reenviadas. O novo diretório é `/tmp/amelie-media`, configurável por
   `MEDIA_TEMP_DIR`, e deve ser compartilhado pelos dois processos.

Vídeos enviados diretamente continuam sendo processados. Downloads por links de
redes sociais ficam desativados até existir um serviço isolado que controle todas
as conexões dos extratores. A leitura de páginas depende do bridge, inclusive no
canal Telegram. As instruções completas estão em [DEPLOYMENT.md](DEPLOYMENT.md).

## Verificação

Ambiente: Gleam 1.15.0, Erlang/OTP 27.3.4.18 e Go 1.26.0.

```sh
gleam format --check src test
gleam test
python3 test/security_http_test.py
gleam export erlang-shipment
(cd whatsmeow-bridge && go test -race -count=1 ./...)
(cd whatsmeow-bridge && CGO_ENABLED=0 go build .)
sh -n entrypoint.sh
git diff --check
```

Resultados locais: 189 testes Gleam/Erlang sem falhas, cinco testes HTTP sem
falhas, suíte Go aprovada com detector de corridas e os dois builds concluídos.
O teste HTTP usa banco e ambiente temporários e não carrega o `.env` do usuário.

O NIF do `esqlite` foi compilado localmente a partir do C original e das opções de
compilação do pacote, pois o download do plugin de compilação do Rebar foi
interrompido pelo ambiente. Essa adaptação ficou apenas no cache de build e não
integra este patch.

Não foram executados deploy, build da imagem Docker ou testes com contas reais
de WhatsApp, Telegram e provedores de IA. Essas verificações locais demonstram
os comportamentos listados; não constituem garantia de ausência de outras falhas.
