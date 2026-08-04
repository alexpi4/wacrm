# Plano de Implementação no ImobFlow

Roadmap fatiado em etapas independentemente testáveis, na ordem recomendada. Cada etapa referencia os
documentos anteriores para detalhe.

## 0. Dependências

```bash
npm install @xyflow/react @dagrejs/dagre
```

Nenhuma outra dependência de canvas é necessária. O resto reaproveita o que o ImobFlow já tiver de
UI kit (formulários, modais, toasts).

## 1. Migration SQL
- Adaptar e rodar `01-schema.sql` no projeto Supabase do ImobFlow.
- Antes de rodar, revisar os pontos marcados no topo do arquivo: nome real das tabelas de contato/lead
  (`contacts` → talvez `leads`), se o app é multi-tenant (`account_id`) ou não, se `auth.users` é o
  provedor de identidade certo.
- Decidir os campos de `contact_field` permitidos no nó `condition` para o domínio imobiliário (ex.
  `stage`, `lead_source`, `budget_range` em vez de `name`/`email`/`phone`/`company`).

## 2. Tipos + motor puro (sem UI)
- Portar `src/lib/flows/types.ts` → definir a union discriminada incluindo `wait` (ver
  `02-tipos-e-logica-do-motor.md` §1).
- Portar `src/lib/flows/validate.ts` → adaptar limites de mensageria para o(s) canal(is) de envio do
  ImobFlow (e-mail, SMS, WhatsApp — o que for aplicável) e adicionar a validação do nó `wait`.
- Escrever `src/lib/flows/engine.ts` equivalente:
  - Reaproveitar a estrutura de `advanceFromNodeKey` (loop síncrono, trava de segurança, log de eventos).
  - Implementar o `case "wait"` novo: calcula `run_at`, insere em `flow_pending_waits`, loga
    `wait_scheduled`, retorna sem terminar a run.
  - Trocar as chamadas `engineSend*` (específicas de WhatsApp/Meta) por uma interface de envio agnóstica —
    ver seção 6 abaixo.
- **Esta camada é 100% testável sem banco real** (funções puras como `evaluateConditionPredicate`,
  `matchesKeywordTrigger`, `deriveCanvasEdges`, `applyEdgeConnection` não tocam I/O) — escrever testes
  unitários aqui primeiro, antes de qualquer UI.

## 3. Canvas visual
Ordem interna recomendada (já detalhada em `03-sandbox-visual-canvas.md` §10):
1. `shared.tsx` (NODE_META, nodeColors, tipos) — incluir `wait` desde o início na paleta e nas categorias.
2. `edges.ts` (deriveCanvasEdges, applyEdgeConnection, unlinkNodeReferences).
3. `layout.ts` (wrapper de dagre).
4. `flow-canvas.tsx` (o componente React Flow em si).
5. `flow-editor-state.tsx` (contexto compartilhado, mutators, save/activate/delete).
6. Formulários de configuração por nó (`NodeConfigForm`), incluindo o formulário do `wait`
   (amount + unit + next_node_key).

A visão de lista (`flow-builder.tsx` no wacrm) é opcional — o pedido original é especificamente o canvas;
pode ficar de fora do MVP e ser adicionada depois se o time achar útil ter uma alternativa sem drag-and-drop.

## 4. Telas
- `/flows` — lista + criação (ver `04-telas-e-navegacao.md` §2). Comece sem templates prontos; adicione o
  template "Follow-up" (abaixo) quando o motor de `wait` estiver testado.
- `/flows/[id]` — editor (canvas).
- `/flows/[id]/runs` — histórico. Pode vir depois do MVP do canvas — é observabilidade, não bloqueia o
  fluxo de criar/ativar um flow.

## 5. API routes
Portar o contrato de `05-api-endpoints.md` — mais simples que o resto porque é CRUD direto sobre as
tabelas + os dois handlers de cron.

## 6. Cron de wait (o que viabiliza follow-up de verdade)
- `GET /api/flows/cron-wait` (ver `05-api-endpoints.md` §10).
- Agendar no scheduler do ImobFlow (Vercel Cron via `vercel.ts`/`vercel.json`, ou outro mecanismo) com
  frequência compatível com a granularidade mínima de espera que o produto quer oferecer — ex. rodar a
  cada 5 minutos cobre bem esperas em `hours`/`days`; para esperas em `minutes` com precisão fina,
  considerar um intervalo menor.
- Reaproveitar o cron de timeout (`GET /api/flows/cron`) tal como está — não depende do nó `wait`.

## 7. Template "Follow-up" pronto
Depois que o nó `wait` estiver funcionando ponta a ponta, adicionar um template clonável equivalente ao
`follow_up_reminder` do wacrm, mas usando o canvas (o wacrm original não tinha canvas pra isso — esta é a
peça nova que o usuário pediu):

```
start
  → send_message ("Olá! Vi que você demonstrou interesse no imóvel X...")
    → wait (1 dia)
      → condition (subject: contact_field, subject_key: "last_reply_at", operator: "absent")
          true  → send_message ("Ainda por aí? Posso te ajudar a agendar uma visita.")
                    → end
          false → end   // já respondeu, não precisa do nudge
```

Isso é exatamente o padrão "espera X, verifica se respondeu, manda nudge se não" que o usuário descreveu
como o objetivo do sandbox.

## 8. O que NÃO portar do wacrm (ou portar atrás de uma interface)

O wacrm é um CRM de WhatsApp — várias peças do motor são específicas desse canal:
- `meta-send.ts` (chamadas à API do Meta/WhatsApp Cloud) — **isolar atrás de uma interface de "canal de
  envio"** (`sendText`, `sendMedia`, `sendInteractiveButtons`, etc.) cuja implementação real no ImobFlow
  depende de quais canais o produto vai usar (e-mail? WhatsApp via outro provedor? SMS?). O motor
  (`engine.ts`) só deve depender da interface, nunca da implementação concreta — isso é o que permite o
  mesmo motor de flow servir follow-up por e-mail e por WhatsApp sem duplicar a lógica de grafo.
- `send_buttons` / `send_list` (nós interativos do WhatsApp) — só fazem sentido se o canal de destino
  suportar botões/listas nativos (WhatsApp Business API suporta; e-mail e SMS não). Avaliar se vale manter
  esses tipos de nó ou simplificar para um conjunto menor no MVP do ImobFlow.
- Limites de caracteres/quantidade em `validate.ts` (`INTERACTIVE_LIMITS`) — são limites do WhatsApp Cloud
  API especificamente; trocar pelos limites do(s) canal(is) real(is) do ImobFlow.
- Lógica de webhook de entrada (`dispatchInboundToFlows` sendo chamado a partir de um webhook do Meta) —
  só é necessária se o ImobFlow também processa mensagens recebidas em tempo real; para um MVP focado só
  em follow-up por tempo (`wait`), o gatilho `manual` (ou um gatilho por evento do CRM, ex. "lead criado",
  "estágio do funil mudou") já cobre o caso de uso sem precisar de webhook nenhum.

## 9. Ordem de entrega sugerida (MVP mínimo viável)

1. Migration (etapa 1).
2. Tipos + motor puro com `start`, `send_message`, `wait`, `condition`, `end` apenas (subconjunto mínimo
   de node_types — dá pra expressar o template de follow-up inteiro só com esses cinco).
3. Cron de wait (etapa 6) — sem ele, `wait` nunca retoma, então é bloqueante para qualquer teste ponta a
   ponta real.
4. Canvas com esse subconjunto de 5 tipos de nó.
5. Telas de lista + editor.
6. Validar ponta a ponta: criar um flow no canvas, ativar, disparar manualmente, ver a espera em
   `flow_pending_waits`, rodar o cron manualmente, confirmar que a run avançou.
7. Só então expandir para os demais tipos de nó (`send_buttons`, `send_list`, `collect_input`, `set_tag`,
   `handoff`, `send_media`) e para a tela de histórico de runs.
