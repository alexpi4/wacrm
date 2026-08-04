# Contrato de API

Fontes: `src/app/api/flows/**` (wacrm). Endpoints marcados **NOVO** são propostas de extensão para o nó
`wait`, não existem no wacrm original.

## 1. `GET /api/flows`
Lista os fluxos do usuário/conta autenticado (RLS filtra automaticamente).
```
200 { flows: FlowRow[] }
```

## 2. `POST /api/flows`
Cria um fluxo novo — em branco ou clonado de um template.
```
Body (em branco):
{ name: string, trigger_type: "keyword"|"first_inbound_message"|"manual", trigger_config: object }

Body (a partir de template):
{ template_slug: string }

201 { flow: FlowRow }
```

## 3. `GET /api/flows/templates`
Lista templates disponíveis para o modal de criação.
```
200 { templates: Array<{ slug, name, description, icon, trigger_type, node_count }> }
```

## 4. `GET /api/flows/[id]`
Busca um fluxo com todos os seus nós.
```
200 { flow: FlowRow, nodes: FlowNodeRow[] }
404 { error: "Not found" }   // não existe OU pertence a outra conta (RLS)
```

## 5. `PUT /api/flows/[id]`
Salva o fluxo inteiro: metadados do envelope + (opcionalmente) o grafo completo de nós.

```
Body (todos os campos opcionais — envia só o que mudou):
{
  name?: string,
  description?: string | null,
  trigger_type?: "keyword" | "first_inbound_message" | "manual",
  trigger_config?: object,
  entry_node_id?: string | null,
  fallback_policy?: object,
  nodes?: Array<{
    node_key: string,
    node_type: string,       // inclui "wait" na lista de tipos válidos
    config: object,
    position_x?: number,
    position_y?: number,
  }>,
}

200 { flow: FlowRow, nodes: FlowNodeRow[] }   // estado após salvar
400 { error: "name cannot be empty" }
401 / 403 / 404
```

**Padrão de escrita dos nós: delete-then-insert.** Quando `nodes` está presente no body, o backend apaga
todas as linhas de `flow_nodes` daquele fluxo e insere as novas de uma vez — não é transacional (duas
operações separadas), mas o motor de execução tolera uma leitura no meio de uma edição concorrente: um nó
que "sumiu" resulta em `node_not_found`, que encerra a run daquele contato com uma falha registrada, sem
travar o sistema. Requer papel mínimo `agent` (ou equivalente no ImobFlow) — verificado no servidor mesmo
que a escrita real use uma credencial de serviço que ignora RLS.

## 6. `DELETE /api/flows/[id]`
Apaga o fluxo. `CASCADE` no banco cuida de `flow_nodes`, `flow_runs`, `flow_run_events` (e, com a extensão,
`flow_pending_waits`). Execuções ativas terminam abruptamente — é uma ação deliberadamente destrutiva, sem
modo de "drenar graciosamente" na v1.
```
200 { ok: true }
```

## 7. `POST /api/flows/[id]/activate`
Muda o status do fluxo (`draft` ↔ `active` ↔ `archived`). Ativar exige que a validação
(`validateFlowForActivation`) não tenha nenhum erro.
```
Body: { status: "draft" | "active" | "archived" }
200 { ok: true, status: string }
400 { error: "..." }   // validação falhou
```

## 8. `GET /api/flows/[id]/runs`
Histórico de execuções de um fluxo, com os eventos já resolvidos (para a tela de runs não precisar de N+1
requisições).
```
200 {
  flow: { id, name },
  runs: FlowRunRow[],        // até 50, mais recente primeiro
  events: FlowRunEventRow[], // eventos de todas as runs retornadas, filtráveis no client por flow_run_id
}
```

## 9. `GET /api/flows/cron` — varredura de timeout
Cron existente no wacrm, roda periodicamente (Vercel Cron / pinger externo). Varre `flow_runs` ativas cujo
`last_advanced_at` excede `fallback_policy.on_timeout_hours` daquele fluxo, marca como `timed_out`.
```
Header: x-cron-secret: <FLOWS_CRON_SECRET>
200 { swept: number }
401 { error: "Unauthorized" }   // secret ausente/errado
503 { error: "cron not configured" }   // env var não setada
```

## 10. `GET /api/flows/cron-wait` — **NOVO**, drena esperas vencidas

Espelha `GET /api/automations/cron` do wacrm (`src/app/api/automations/cron/route.ts`), adaptado para
`flow_pending_waits`.

```
Header: x-cron-secret: <FLOWS_CRON_SECRET>   // mesmo secret do cron de timeout, ou um dedicado

200 { processed: number }
401 { error: "Unauthorized" }
503 { error: "cron not configured" }
```

Lógica do handler:
```ts
export async function GET(request: Request) {
  // 1. valida x-cron-secret com timingSafeEqual (nunca comparação direta de string)
  // 2. SELECT * FROM flow_pending_waits WHERE status='pending' AND run_at <= now() ORDER BY run_at LIMIT 50
  // 3. para cada linha:
  //    a. UPDATE flow_pending_waits SET status='running' WHERE id=X AND status='pending' (claim otimista)
  //    b. se o claim não afetou nenhuma linha, pula (outra invocação já pegou)
  //    c. carrega a flow_run + os nós do flow
  //    d. chama advanceFromNodeKey(db, run, resume_node_key, nodes) — mesma função do motor síncrono
  //    e. UPDATE flow_pending_waits SET status='done' WHERE id=X
  // 4. retorna { processed: contagem }
}
```

`limit(50)` por invocação, igual ao cron de `automations` — evita uma invocação de cron monopolizar tempo
de execução; se houver mais de 50 esperas vencidas, a próxima invocação pega o resto.

## 11. Convenções gerais

- Toda rota exige usuário autenticado (Supabase Auth); RLS escopa automaticamente por dono/conta nas
  leituras. Escritas passam pela service-role key no servidor, com o papel do usuário checado
  explicitamente antes (porque a service-role ignora RLS).
- Rotas de cron usam um **shared secret** via header, comparado com `timingSafeEqual` (não `===`) para
  evitar timing attack — nunca proteger cron só por "estar em produção" ou por obscuridade da URL.
- Erros seguem o formato `{ error: string }` com o HTTP status apropriado (400 validação, 401 sem sessão,
  403 sem permissão, 404 não encontrado/não pertence ao usuário, 500 erro inesperado, 503 dependência não
  configurada).
