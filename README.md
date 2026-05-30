# Copa 2026 API

[![GitHub](https://img.shields.io/badge/GitHub-copa--2026--api-181717?logo=github)](https://github.com/allanbarcelos/copa-2026-api)
[![Frontend Repo](https://img.shields.io/badge/GitHub-copa--2026-181717?logo=github)](https://github.com/allanbarcelos/copa-2026)

API em tempo real para acompanhamento da Copa do Mundo 2026. Agrega dados de partidas e previsões de duas fontes externas e os distribui via WebSocket (Socket.IO) para clientes conectados.

## Visão geral

```
football-data.org  ──► poller (6s)   ──┐
                                        ├──► Socket.IO ──► clientes
api-football.com   ──► poller (1h)   ──┘
```

Não há banco de dados. O estado é mantido em memória e recarregado automaticamente a partir das APIs externas após cada reinício.

## Requisitos

- Node.js 22+
- Chave de API do [football-data.org](https://www.football-data.org/client/register) (**obrigatória**)
- Chave de API do [api-football](https://rapidapi.com/api-sports/api/api-football) (opcional — habilita previsões)

## Variáveis de ambiente

| Variável | Obrigatória | Padrão | Descrição |
|---|---|---|---|
| `FOOTBALL_DATA_API_KEY` | sim | — | Chave da API football-data.org |
| `API_FOOTBALL_KEY` | não | — | Chave da API api-football (previsões) |
| `ALLOWED_ORIGIN` | não | `http://localhost:5174` | Origem CORS permitida para o Socket.IO |
| `PORT` | não | `3001` | Porta do servidor HTTP |

Copie o arquivo de exemplo e preencha os valores:

```bash
cp .env.example .env
```

## Desenvolvimento

```bash
npm install
npm run dev   # node --watch (hot reload)
```

## Produção (Docker)

```bash
docker compose up -d
```

## Produção (Docker Swarm)

Use o instalador interativo. Ele configura o Swarm, cria os secrets e faz o deploy:

```bash
curl -fsSL https://gist.github.com/allanbarcelos/copa-2026-api-install.sh | sudo bash
```

O instalador pergunta as chaves das APIs e as salva como **Docker Swarm secrets** (encriptados no Raft), nunca em arquivos de texto.

## Endpoints HTTP

| Rota | Descrição |
|---|---|
| `GET /health` | Status da API e número de clientes conectados |
| `GET /snapshot` | Snapshot atual das partidas (cache) |
| `GET /predictions` | Previsões em cache para os próximos 7 dias |

## WebSocket (Socket.IO)

Conecte ao servidor Socket.IO na raiz (`/`).

**Eventos recebidos pelo cliente:**

| Evento | Payload | Descrição |
|---|---|---|
| `matches` | objeto de partidas | Emitido quando os dados de partidas mudam |
| `predictions` | objeto de previsões | Emitido quando as previsões são atualizadas |
| `error` | `{ message }` | Falha ao buscar dados das APIs externas |
| `pong` | — | Resposta ao evento `ping` |

**Eventos enviados pelo cliente:**

| Evento | Descrição |
|---|---|
| `ping` | Keepalive / heartbeat |

Ao conectar, o cliente recebe imediatamente o snapshot atual de partidas e previsões.

### Exemplo de conexão

```js
import { io } from "socket.io-client";

const socket = io("http://localhost:3001");

socket.on("matches", (data) => {
  console.log("partidas:", data);
});

socket.on("predictions", (data) => {
  console.log("previsões:", data);
});
```

## Estrutura do projeto

```
src/
├── index.js               # Servidor Express + Socket.IO
├── store.js               # Cache in-memory
├── poller.js              # Polling football-data.org (6s)
└── predictionsPoller.js   # Polling api-football (1h)
```

## Publicação da imagem Docker

A imagem é publicada automaticamente no GitHub Container Registry a cada push na branch `main` ou tag `v*`:

```
ghcr.io/allanbarcelos/copa-2026-api:main
ghcr.io/allanbarcelos/copa-2026-api:1.2.3
ghcr.io/allanbarcelos/copa-2026-api:1.2
ghcr.io/allanbarcelos/copa-2026-api:sha-abc1234
```

Para publicar uma versão:

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Secrets necessários no repositório

| Secret / Variável | Tipo | Descrição |
|---|---|---|
| `GIST_TOKEN` | Secret | PAT com escopo `gist` para atualizar o instalador |
| `GIST_ID` | Variable | ID do Gist do `install.sh` |

## Licença

MIT

---

Projeto open source — contribuições e feedbacks são bem-vindos.

Aceito apoio para novos projetos ☕ [Buy me a coffee](https://www.buymeacoffee.com/allanbarcelos)
