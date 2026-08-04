-- ============================================================
-- Módulo Follow-up — Schema de referência (Postgres / Supabase)
--
-- Baseado fielmente em supabase/migrations/010_flows.sql do wacrm,
-- adaptado para um schema genérico + a tabela NOVA `flow_pending_waits`
-- que sustenta o node_type "wait" (proposta de extensão — não existe
-- no wacrm original). Ver docs/modulo_follow/01-modelo-de-dados.md
-- para a explicação de cada decisão.
--
-- Ajustar antes de aplicar no projeto Supabase de destino (ImobFlow):
--   - `auth.users(id)` assume Supabase Auth — ajustar se o destino usa
--     outro provedor de identidade.
--   - `contacts` / `conversations` / `messages` são tabelas do domínio
--     do app de destino — os FKs abaixo assumem que já existem com
--     colunas `id uuid PRIMARY KEY`. Renomeie/ajuste conforme o schema
--     real do ImobFlow (ex. `leads` em vez de `contacts`).
--   - `account_id` assume um modelo multi-tenant; remova se o app for
--     single-tenant.
-- Idempotente — seguro rodar mais de uma vez.
-- ============================================================

-- ============================================================
-- 1. flows — envelope do fluxo
-- ============================================================
CREATE TABLE IF NOT EXISTS flows (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_id UUID NOT NULL,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft', 'active', 'archived')),
  trigger_type TEXT NOT NULL
    CHECK (trigger_type IN ('keyword', 'first_inbound_message', 'manual')),
  trigger_config JSONB NOT NULL DEFAULT '{}'::jsonb,
  -- Referencia flow_nodes.node_key (string), não o UUID da linha.
  -- NULL enquanto o flow está em draft; exigido antes de ativar
  -- (validado na aplicação, não aqui, para permitir salvar rascunhos
  -- incompletos).
  entry_node_id TEXT,
  fallback_policy JSONB NOT NULL DEFAULT
    '{"on_unknown_reply":"reprompt","max_reprompts":2,"on_timeout_hours":24,"on_exhaust":"handoff"}'::jsonb,
  execution_count INTEGER NOT NULL DEFAULT 0,
  last_executed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_flows_active_trigger
  ON flows(account_id, trigger_type)
  WHERE status = 'active';

ALTER TABLE flows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can manage own flows" ON flows;
CREATE POLICY "Users can manage own flows" ON flows FOR ALL
  USING (auth.uid() = user_id);

-- ============================================================
-- 2. flow_nodes — nós do grafo (edges vivem DENTRO do config JSONB
--    de cada nó — ver docs/modulo_follow/01-modelo-de-dados.md §3)
-- ============================================================
CREATE TABLE IF NOT EXISTS flow_nodes (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  flow_id UUID NOT NULL REFERENCES flows(id) ON DELETE CASCADE,
  node_key TEXT NOT NULL,
  node_type TEXT NOT NULL CHECK (node_type IN (
    'start',
    'send_message',
    'send_buttons',
    'send_list',
    'send_media',
    'collect_input',
    'condition',
    'set_tag',
    'wait',        -- NOVO: nó de espera/delay (proposta de extensão)
    'handoff',
    'end'
  )),
  config JSONB NOT NULL DEFAULT '{}'::jsonb,
  position_x INTEGER NOT NULL DEFAULT 0,
  position_y INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (flow_id, node_key)
);

CREATE INDEX IF NOT EXISTS idx_flow_nodes_flow
  ON flow_nodes(flow_id);

ALTER TABLE flow_nodes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users manage nodes on their flows" ON flow_nodes;
CREATE POLICY "Users manage nodes on their flows" ON flow_nodes FOR ALL
  USING (EXISTS (
    SELECT 1 FROM flows f
    WHERE f.id = flow_nodes.flow_id
      AND f.user_id = auth.uid()
  ));

-- ============================================================
-- 3. flow_runs — máquina de estado por contato
-- ============================================================
CREATE TABLE IF NOT EXISTS flow_runs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  flow_id UUID NOT NULL REFERENCES flows(id) ON DELETE CASCADE,
  account_id UUID NOT NULL,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  -- Ajustar `contacts` para a tabela de lead/contato real do app de
  -- destino. ON DELETE SET NULL preserva o histórico de auditoria.
  contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,
  conversation_id UUID REFERENCES conversations(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN (
    'active',           -- em andamento (aguardando input OU aguardando um wait)
    'completed',        -- chegou a um nó end naturalmente
    'handed_off',       -- encerrado via nó handoff
    'timed_out',        -- varrido pelo cron por inatividade (fallback_policy.on_timeout_hours)
    'paused_by_agent',  -- um agente humano assumiu manualmente
    'failed'            -- erro irrecuperável
  )),
  current_node_key TEXT,
  last_prompt_message_id UUID REFERENCES messages(id) ON DELETE SET NULL,
  vars JSONB NOT NULL DEFAULT '{}'::jsonb,
  reprompt_count INTEGER NOT NULL DEFAULT 0,
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_advanced_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at TIMESTAMPTZ,
  end_reason TEXT
);

-- Garante, por construção, no máximo uma execução ativa por contato.
CREATE UNIQUE INDEX IF NOT EXISTS idx_one_active_run_per_contact
  ON flow_runs(account_id, contact_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_flow_runs_active_advanced
  ON flow_runs(last_advanced_at)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_flow_runs_flow_started
  ON flow_runs(flow_id, started_at DESC);

ALTER TABLE flow_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users see own flow runs" ON flow_runs;
CREATE POLICY "Users see own flow runs" ON flow_runs FOR SELECT
  USING (auth.uid() = user_id);
-- Writes acontecem via service-role (motor/cron), fora de RLS.

-- ============================================================
-- 4. flow_run_events — log append-only por execução
-- ============================================================
CREATE TABLE IF NOT EXISTS flow_run_events (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  flow_run_id UUID NOT NULL REFERENCES flow_runs(id) ON DELETE CASCADE,
  event_type TEXT NOT NULL CHECK (event_type IN (
    'started',
    'node_entered',
    'message_sent',
    'reply_received',
    'wait_scheduled',   -- NOVO: nó wait agendou uma retomada futura
    'wait_resumed',     -- NOVO: cron retomou a execução após o wait
    'fallback_fired',
    'handoff',
    'timeout',
    'error',
    'completed'
  )),
  node_key TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_flow_run_events_run_type
  ON flow_run_events(flow_run_id, event_type);

CREATE INDEX IF NOT EXISTS idx_flow_run_events_run_time
  ON flow_run_events(flow_run_id, created_at DESC);

ALTER TABLE flow_run_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users see events on their runs" ON flow_run_events;
CREATE POLICY "Users see events on their runs" ON flow_run_events FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM flow_runs r
    WHERE r.id = flow_run_events.flow_run_id
      AND r.user_id = auth.uid()
  ));

-- ============================================================
-- 5. flow_pending_waits — NOVO. Fila de retomada para o nó `wait`.
--    Espelha automation_pending_executions do wacrm (migration 006),
--    mas simplificado: aqui só existe UM tipo de suspensão (tempo),
--    então não precisa de parent_step_id/branch/context genérico.
-- ============================================================
CREATE TABLE IF NOT EXISTS flow_pending_waits (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  flow_run_id UUID NOT NULL REFERENCES flow_runs(id) ON DELETE CASCADE,
  account_id UUID NOT NULL,
  -- next_node_key do nó `wait` — para onde retomar quando `run_at` vencer.
  resume_node_key TEXT NOT NULL,
  run_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'running', 'done', 'failed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Consulta do cron: "o que já venceu e ainda está pendente".
CREATE INDEX IF NOT EXISTS idx_flow_pending_waits_due
  ON flow_pending_waits(status, run_at);

-- Consulta "esta run tem uma espera pendente?" (ex. ao cancelar/deletar
-- a run, cancelar a espera junto).
CREATE INDEX IF NOT EXISTS idx_flow_pending_waits_run
  ON flow_pending_waits(flow_run_id);

ALTER TABLE flow_pending_waits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users see pending waits on their runs" ON flow_pending_waits;
CREATE POLICY "Users see pending waits on their runs" ON flow_pending_waits FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM flow_runs r
    WHERE r.id = flow_pending_waits.flow_run_id
      AND r.user_id = auth.uid()
  ));
-- Writes acontecem via service-role (motor grava ao entrar no nó wait;
-- cron grava ao reivindicar/concluir a linha).

-- ============================================================
-- 6. updated_at trigger em flows
--    Assume a função update_updated_at_column() já existente no
--    projeto (padrão comum em apps Supabase). Criar se não existir:
--
--    CREATE OR REPLACE FUNCTION update_updated_at_column()
--    RETURNS TRIGGER AS $$
--    BEGIN
--      NEW.updated_at = NOW();
--      RETURN NEW;
--    END;
--    $$ LANGUAGE plpgsql;
-- ============================================================
DROP TRIGGER IF EXISTS set_updated_at ON flows;
CREATE TRIGGER set_updated_at BEFORE UPDATE ON flows
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ============================================================
-- 7. Contador atômico de execuções (evita race condition em
--    read-modify-write quando dois webhooks disparam o mesmo flow
--    ao mesmo tempo para contatos diferentes).
-- ============================================================
CREATE OR REPLACE FUNCTION increment_flow_execution_count(p_flow_id UUID)
RETURNS VOID AS $$
BEGIN
  UPDATE flows
  SET execution_count = execution_count + 1,
      last_executed_at = NOW()
  WHERE id = p_flow_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- 8. (Opcional) Realtime — expõe flow_runs para a UI acompanhar ao
--    vivo em que nó cada contato está.
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'flow_runs'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE flow_runs;
  END IF;
END $$;
