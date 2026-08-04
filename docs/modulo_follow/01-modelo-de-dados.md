# Modelo de Dados

Fonte principal: `supabase/migrations/010_flows.sql` (wacrm). SQL pronto para adaptar está em
[`01-schema.sql`](./01-schema.sql).

## 1. As 4 tabelas centrais (existentes no wacrm)

### `flows` — o envelope do fluxo

Uma linha por fluxo autorado. Guarda metadados, não o grafo.

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | uuid PK | |
| `account_id` / `user_id` | uuid | tenancy + autor |
| `name`, `description` | text | |
| `status` | text | `draft` \| `active` \| `archived` |
| `trigger_type` | text | `keyword` \| `first_inbound_message` \| `manual` |
| `trigger_config` | jsonb | depende do `trigger_type` (ex. lista de keywords) |
| `entry_node_id` | text | **referencia `flow_nodes.node_key`, não o UUID da linha** — pode ficar `NULL` enquanto o draft é editado |
| `fallback_policy` | jsonb | o que fazer quando o cliente responde algo que não bate com nenhuma opção (ver `02-tipos-e-logica-do-motor.md`) |
| `execution_count`, `last_executed_at` | | contadores de uso, exibidos na listagem |

### `flow_nodes` — os nós do grafo

Uma linha por nó. **Não existe tabela de edges** — ver seção 3.

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | uuid PK | |
| `flow_id` | uuid FK → `flows` | `ON DELETE CASCADE` |
| `node_key` | text | identificador estável escolhido pelo builder (ex. `"menu_principal"`), **não é o UUID** |
| `node_type` | text (CHECK) | ver enum na seção 2 |
| `config` | jsonb | forma depende de `node_type` — union discriminada, ver `02-tipos-e-logica-do-motor.md` |
| `position_x`, `position_y` | integer | coordenadas do canvas; `0,0` em nós ainda não posicionados |

`UNIQUE (flow_id, node_key)` garante que a busca "dado o nó atual, para onde ir" seja sempre determinística.

### `flow_runs` — a máquina de estado por contato

Uma linha por **execução em andamento (ou finalizada) de um flow para um contato específico**.

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | uuid PK | |
| `flow_id`, `account_id`, `user_id` | uuid | |
| `contact_id`, `conversation_id` | uuid, nullable `SET NULL` | histórico sobrevive à exclusão do contato |
| `status` | text (CHECK) | `active` \| `completed` \| `handed_off` \| `timed_out` \| `paused_by_agent` \| `failed` |
| `current_node_key` | text | onde a execução está parada agora |
| `last_prompt_message_id` | uuid FK → `messages` | último prompt enviado (pra UI poder "citar" a pergunta que o cliente está respondendo) |
| `vars` | jsonb | valores capturados durante a execução (ex. resposta de um `collect_input`) |
| `reprompt_count` | integer | quantas vezes já repetiu a pergunta por resposta não reconhecida |
| `started_at`, `last_advanced_at`, `ended_at`, `end_reason` | timestamptz/text | |

**Índice crítico**: `UNIQUE (account_id, contact_id) WHERE status = 'active'` — garante, por construção,
no máximo **uma execução ativa por contato**. Duas requisições concorrentes tentando iniciar um run para o
mesmo contato colidem no INSERT (erro `23505`); a segunda simplesmente desiste. Não precisa de lock
explícito.

### `flow_run_events` — log de auditoria append-only

Uma linha por evento relevante dentro de uma execução — usada tanto para **idempotência** (não reprocessar
a mesma mensagem do WhatsApp duas vezes) quanto para o **histórico visível na tela de runs**.

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | uuid PK | |
| `flow_run_id` | uuid FK → `flow_runs` | `ON DELETE CASCADE` |
| `event_type` | text (CHECK) | `started`, `node_entered`, `message_sent`, `reply_received`, `fallback_fired`, `handoff`, `timeout`, `error`, `completed` |
| `node_key` | text nullable | qual nó gerou o evento |
| `payload` | jsonb | detalhes livres por tipo de evento |
| `created_at` | timestamptz | |

## 2. Tabela nova proposta: `flow_pending_waits`

> **Isto não existe no wacrm.** É a peça que falta para o nó `wait` funcionar — o mesmo padrão que
> `automation_pending_executions` já resolve no motor de `automations` (ver
> `src/lib/automations/engine.ts:277-303` e `supabase/migrations/006_automations.sql` no wacrm).

Quando a execução chega em um nó `wait`, em vez de continuar imediatamente (como todo outro nó
auto-advance), ela grava uma linha nesta tabela e **fica parada** até um cron processar a linha vencida.

| Coluna | Tipo | Notas |
|---|---|---|
| `id` | uuid PK | |
| `flow_run_id` | uuid FK → `flow_runs` | qual execução está esperando |
| `account_id` | uuid | tenancy, para o cron poder escopar |
| `resume_node_key` | text | o `next_node_key` do nó `wait` — para onde retomar quando o tempo passar |
| `run_at` | timestamptz | `now() + amount(unit)`, calculado no momento em que o nó `wait` é executado |
| `status` | text (CHECK) | `pending` \| `running` \| `done` \| `failed` — `running` funciona como lock otimista (claim) |
| `created_at` | timestamptz | |

Índices:
- `(status, run_at)` — para o cron buscar rápido "o que já venceu e ainda não foi processado".
- `(flow_run_id)` — para achar a espera pendente de uma run específica (ex. se a run for cancelada, cancelar a espera também).

## 3. Por que não existe uma tabela `flow_edges`

Decisão deliberada do wacrm (comentário original em `010_flows.sql:6-29`), reproduzida aqui porque é a
base de tudo que o canvas faz:

> - O motor só precisa perguntar "dado o nó atual X, pra onde vai a resposta Y?" — isso é uma leitura de
>   uma linha só, com o JSON já carregado. Separar edges forçaria um JOIN por mensagem recebida.
> - A unidade natural de edição do builder é o nó ("mudar o rótulo e o destino deste botão"), não a
>   aresta — uma tabela separada forçaria inserts/deletes coordenados a cada save.
> - Integridade entre nós (referências quebradas, nós órfãos) é garantida em tempo de salvamento por um
>   validador (ver `02-tipos-e-logica-do-motor.md` e `03-sandbox-visual-canvas.md`), não por FK do banco —
>   porque durante a edição (draft) é normal ter referências temporariamente incompletas.

Consequência prática: `next_node_key` (e equivalentes) são **strings livres**, sem FK no banco — a
integridade é responsabilidade da camada de aplicação, não do Postgres.

## 4. Row Level Security (RLS)

Todas as tabelas usam RLS por dono:
- `flows`, `flow_nodes`: policy `FOR ALL USING (auth.uid() = user_id)` (nós, indiretamente, via join com `flows`).
- `flow_runs`, `flow_run_events`: policy `FOR SELECT` apenas — todo **write** passa pelo motor usando a
  service-role key (o usuário final nunca escreve run/evento diretamente do client).
- `flow_pending_waits` (nova): mesmo padrão de `flow_runs` — só SELECT via RLS, write via service-role no
  cron e no motor.

## 5. Realtime

No wacrm, `flow_runs` está na publicação `supabase_realtime` para a caixa de entrada mostrar ao vivo "este
contato está no fluxo X, no nó Y". Recomenda-se replicar isso no ImobFlow se a UI quiser mostrar em tempo
real o progresso de leads/contatos dentro de um fluxo de follow-up.
