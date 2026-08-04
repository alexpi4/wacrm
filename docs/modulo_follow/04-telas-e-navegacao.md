# Telas e Navegação

Fontes: `src/app/(dashboard)/flows/page.tsx`, `flows/[id]/page.tsx`, `flows/[id]/runs/page.tsx` (wacrm).

## 1. Inventário de telas

| Rota | Arquivo (wacrm) | Papel |
|---|---|---|
| `/flows` | `flows/page.tsx` | Lista de fluxos do usuário/conta, criar novo (em branco ou a partir de template) |
| `/flows/[id]` | `flows/[id]/page.tsx` → `FlowEditorShell` | Editor do fluxo — alterna entre visão de lista e visão de canvas |
| `/flows/[id]/runs` | `flows/[id]/runs/page.tsx` | Histórico de execuções daquele fluxo, com timeline de eventos por execução |

## 2. `/flows` — Lista

**O que mostra:**
- Header com título + badge "Beta" (sinalização de feature nova — opcional replicar) + botão "Novo fluxo".
- Grid de cards, um por fluxo: nome, badge de status colorido (`draft` cinza / `active` verde com ícone de
  play / `archived` cinza claro com ícone de arquivo), resumo do gatilho (ex. "Palavra-chave: oi, olá") ou
  a descrição se houver, contador de execuções, botões "Editar" e "Excluir".
- Estado vazio dedicado (ícone + texto + CTA) quando não há nenhum fluxo ainda.

**Criar um fluxo** abre um modal com duas opções lado a lado:
1. **A partir de um template** — grid de cards de template (ícone, nome, descrição, contagem de nós),
   clicar clona o template inteiro (`POST /api/flows` com `template_slug`) e já navega pro editor.
2. **Em branco** — campo de nome + botão "Criar" (`POST /api/flows` com `trigger_type: "keyword"` vazio
   por padrão), navega pro editor do fluxo recém-criado.

**Ação de excluir** pede confirmação nativa (`window.confirm`) antes de chamar `DELETE /api/flows/[id]`.

> Sugestão para o ImobFlow: o card de template do tipo "Follow-up" (equivalente ao `follow_up_reminder` do
> wacrm) deveria vir pré-populado com `start → wait(1 dia) → condition(respondeu?) → send_message / end` —
> ver `06-plano-de-implementacao.md`.

## 3. `/flows/[id]` — Editor

Carrega `{ flow, nodes }` via `GET /api/flows/[id]` e entrega para `<FlowEditorShell>`, que:
- Mostra um cabeçalho com nome do fluxo (editável), status atual, botões Salvar / Ativar-Pausar / Arquivar
  / Excluir.
- Alterna entre **duas visões da mesma estrutura de dados** (ver `03-sandbox-visual-canvas.md` §5):
  - **Lista** — formulário vertical, um bloco expansível por nó, mais fácil de usar em telas estreitas ou
    para edição rápida de texto.
  - **Canvas** — o sandbox visual arrastável (React Flow), melhor para entender/desenhar a topologia do
    fluxo.
- Painel de validação (fixo ou colapsável) lista erros/avisos; clicar em um item dá "pan" até o nó
  problemático em qualquer uma das duas visões.
- Estados de carregamento e "fluxo não encontrado" (404 por RLS — o usuário tentou abrir um fluxo de
  outra conta) tratados na própria página, antes de montar o shell.

Fluxo de uso típico: usuário cria → edita nós no canvas (ou lista) → painel de validação vai zerando →
botão "Ativar" habilita quando não há mais erros → salva automaticamente antes de ativar.

## 4. `/flows/[id]/runs` — Histórico de execuções

Lista as até 50 execuções mais recentes daquele fluxo (mais recente primeiro), vindas de
`GET /api/flows/[id]/runs`.

**Cada linha (colapsada)** mostra: nome/telefone do contato, badge de status
(`active`/`completed`/`handed_off`/`timed_out`/`paused_by_agent`/`failed` — cada um com cor e ícone
próprios), o nó atual (se `active`), quando começou, quantos reprompts, e quanto tempo durou (se já
terminou).

**Expandida**, cada linha mostra:
- Um bloco colapsável com as `vars` capturadas durante a execução (JSON bruto), só se houver alguma.
- A timeline completa de `flow_run_events` daquela execução: horário, tipo do evento (colorido — verde pra
  `started`/`completed`, azul pra `message_sent`, âmbar pra `fallback_fired`/`handoff`, vermelho pra
  `error`), nó envolvido, e um resumo do payload (prioriza mostrar `reply_id`, `captured_key`, `reason`,
  `advancing_to` — as chaves mais úteis pra depurar "por que meu fluxo não avançou").

> Para o nó `wait` novo, os eventos `wait_scheduled` (âmbar, mostra `run_at`) e `wait_resumed` (verde) se
> encaixam nesse mesmo padrão de timeline sem precisar de UI nova — só adicionar as duas entradas ao mapa
> de cores de evento.

## 5. Fluxo de navegação de ponta a ponta

```mermaid
flowchart LR
    A["/flows<br/>lista"] -->|Novo fluxo| B{Template ou em branco?}
    B -->|template| C["/flows/[id]<br/>editor (pré-populado)"]
    B -->|em branco| C
    C -->|toggle| C
    C -->|Salvar| C
    C -->|Ativar<br/>(bloqueado até canActivate)| C
    C -->|"Ver execuções"| D["/flows/[id]/runs<br/>histórico"]
    D -->|voltar| C
    A -->|Editar em um card| C
    A -->|Excluir em um card| A
```
