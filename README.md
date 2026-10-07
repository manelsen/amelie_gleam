# Amélie: Assistente Acessível de Inteligência Artificial para WhatsApp

A **Amélie** é uma assistente virtual de inteligência artificial que vive no WhatsApp, pensada desde o início para promover a autonomia, a inclusão e o acesso à informação de **pessoas com deficiência**.

Seja você uma pessoa cega, com baixa visão, surda, ensurdecida, neurodivergente ou com mobilidade reduzida, a Amélie transforma mídias visuais e auditivas em formatos acessíveis e fáceis de compreender diretamente no seu aplicativo de mensagens.

---

## O que a Amélie faz por você

A Amélie funciona como um contato comum na sua lista do WhatsApp. Você pode encaminhar mensagens, enviar fotos, áudios e vídeos, e ela responde em texto limpo e organizado.

### 1. Audiodescrição de fotos e imagens
Ao receber uma foto, print ou imagem da galeria, a Amélie analisa a cena e descreve:
- Quem ou o que está na foto (pessoas, animais, objetos e cenário).
- Cores, iluminação e disposição espacial dos elementos.
- Textos visíveis (como placas, cardápios, avisos e capturas de tela).
- Expressões faciais, roupas e ações em andamento.

### 2. Transcrição de mensagens de voz e áudios
Para quem não pode ou não consegue ouvir mensagens de áudio, a Amélie ouve o áudio enviado e responde com a transcrição completa do conteúdo em texto, removendo marcações desnecessárias para facilitar a leitura.

### 3. Audiodescrição de vídeos e redes sociais
Você pode enviar um arquivo de vídeo ou compartilhar links de plataformas como **YouTube**, **Instagram (Reels)** e **TikTok**. A Amélie assiste ao conteúdo e conta o que acontece visualmente, transcrevendo falas e explicando o contexto da cena.

### 4. Interpretação de figurinhas e memes (stickers)
Figurinhas do WhatsApp costumam ser inacessíveis para leitores de tela. A Amélie:
- Descreve figurinhas estáticas, identificando personagens e transcrevendo textos.
- Analisa figurinhas animadas quadro a quadro, explicando o movimento e a piada visual.
- Explica o sentido cultural ou o humor do meme.
- Caso a figurinha expire nos servidores, usa os dados declarados pelo WhatsApp para informar sobre o que se tratava.

### 5. Leitura e resumo de documentos
Encaminhe arquivos em formato PDF ou texto. A Amélie lê o material e envia um resumo estruturado em tópicos, facilitando o estudo e o trabalho no celular.

### 6. Conversa em texto e tira-dúvidas
A Amélie responde perguntas gerais, ajuda a redigir textos, tira dúvidas do dia a dia e dialoga em linguagem clara e amigável.

---

## Recursos pensados para a sua acessibilidade

- **Modo Audiodescrição Detalhada (`.cego`):** Configura a assistente com instruções estritas de audiodescrição para pessoas com deficiência visual, priorizando detalhes espaciais, descrições precisas de vestimentas, feições e elementos do ambiente.
- **Controle de tamanho de resposta (`.curto` e `.longo`):** Quem usa leitores de tela muitas vezes prefere respostas rápidas e concisas (`.curto`), ou descrições ricas e completas (`.longo`). Você escolhe o tamanho ideal.
- **Formatação amigável a sintetizadores de voz:** Respostas sem decorações excessivas de caracteres, sem repetição desnecessária de emojis e organizadas com pontuação natural, garantindo uma leitura confortável no **TalkBack**, **VoiceOver**, **NVDA** e **JAWS**.
- **Respostas citando a mensagem original:** Quando a Amélie responde, ela cita a mensagem correspondente para que você saiba com clareza a qual arquivo ou pergunta ela está se referindo.

---

## Como usar no WhatsApp

Para usar a Amélie, basta adicioná-la aos seus contatos e enviar mensagens. Ela compreende comandos de texto simples iniciados por ponto (`.`).

### Comandos de ajuda e configuração

- `.ajuda`: Envia uma mensagem com a lista de todos os comandos e suas funções.
- `.cego`: Ativa o modo de acessibilidade com audiodescrição minuciosa de imagens.
- `.curto`: Configura a assistente para enviar descrições diretas, objetivas e concisas.
- `.longo`: Configura a assistente para enviar descrições detalhadas e aprofundadas.
- `.reset`: Limpa o histórico da conversa e retorna as configurações para o padrão.

### Comandos para alternar tipos de mídia

Se você preferir ligar ou desligar o processamento de certos arquivos na conversa, basta enviar o comando (ele funciona como um interruptor liga/desliga):

- `.audio`: Alterna o processamento e a transcrição de mensagens de voz.
- `.imagem`: Alterna a audiodescrição de fotos e imagens.
- `.video`: Alterna a audiodescrição e análise de vídeos.
- `.doc`: Alterna a leitura e resumo de documentos.
- `.legenda`: Alterna o modo de vídeo entre resumo visual e transcrição de falas.

### Comandos avançados de inteligência artificial

- `.modelo`: Informa qual motor de inteligência artificial e modelo estão ativos na sua conversa.
- `.modelo provedor/modelo`: Troca o modelo utilizado (por exemplo: `.modelo gemini/gemini-2.5-pro` ou `.modelo gemini/gemini-3.8-flash`).

---

## Dicas para usuários de leitores de tela

1. **Fotos de documentos:** Ao enviar fotos de contas, cartas ou embalagens, tire a foto com boa iluminação e envie. A Amélie lerá todos os textos visíveis, na ordem em que aparecem.
2. **Identificação de objetos:** Se você tiver dúvida sobre uma roupa, cor ou objeto na sua casa, tire uma foto e pergunte: "Qual é a cor desta blusa?" ou "O que está escrito neste remédio?".
3. **Áudios longos:** Se receber um áudio longo que não puder ouvir no momento, encaminhe para a Amélie para receber o texto pronto para leitura.
4. **Grupos:** Se a Amélie for adicionada a um grupo, ela responderá apenas quando for mencionada com `@Amélie`, evitando poluir a conversa dos participantes.

---

## Para desenvolvedores e mantenedores técnicos

A Amélie é um software livre e de código aberto, projetado para operar com alta disponibilidade, baixo consumo de recursos e estrita separação arquitetural.

### Arquitetura do Sistema
- **Linguagem e Runtime:** Construído em [Gleam](https://gleam.run/) sobre a máquina virtual **Erlang/OTP (BEAM)**, garantindo tolerância a falhas nativa, concorrência por atores e tratamento funcional puro de erros.
- **Padrão Arquitetural:** Arquitetura Hexagonal rigorosa (*Ports & Adapters*) com *Functional Core* puro (camadas `dominio/`, `core/`, `portas/`, `adaptadores/` e `shell/`).
- **Conectividade WhatsApp:** Microserviço em Go integrado via biblioteca [whatsmeow](https://github.com/tulir/whatsmeow), com banco SQLite local, fila persistente de entrega e repasse de mídias pesadas via arquivos temporários.
- **Provedores de IA:** Integração primária com a API do **Google Gemini** (usando Gemini File API para upload e processamento de vídeos pesados) e suporte alternativo via **OpenRouter**.
- **Ferramentas de Mídia:** `ffmpeg`, Python PIL (para decomposição de WebP animado), `libwebp-tools` (`webpmux`/`dwebp`) e `yt-dlp`.

### Como rodar em ambiente próprio

Consulte a documentação técnica especializada nos seguintes arquivos:

- [DEPLOYMENT.md](DEPLOYMENT.md): Guia passo a passo de deploy com Docker Compose, configuração de variáveis de ambiente (`.env`), volumes persistentes, pareamento e backup.
- [ROADMAP.md](ROADMAP.md): Estado atual de validação do projeto, histórico de testes automatizados e prioridades de engenharia.
- [GEMINI.md](GEMINI.md): Especificação técnica detalhada das portas, adaptadores, filas de mídia e convenções de código.
- [CLAUDE.md](CLAUDE.md): Instruções de desenvolvimento e regras de trabalho com o compilador Gleam.
- [AGENTS.md](AGENTS.md): Diretrizes para agentes de inteligência artificial e mantenedores de código.
- [TODO.md](TODO.md): Matriz de paridade histórica em relação ao projeto legado Node.js.

---

## Licença e Agradecimentos

Este projeto é dedicado à promoção da tecnologia assistiva inclusiva e acessível em língua portuguesa.
