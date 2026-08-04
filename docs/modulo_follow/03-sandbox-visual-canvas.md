# Sandbox Visual (Canvas) — o coração do módulo

> Este é o documento mais importante do pacote: é a parte que se quer replicar quase 1:1 no ImobFlow.

Fontes: `src/components/flows/flow-canvas.tsx`, `flow-editor-state.tsx`, `flow-editor-shell.tsx`,
`shared.tsx`, `src/lib/flows/edges.ts`, `src/lib/flows/layout.ts`, `src/lib/flows/validate.ts` (wacrm).

## 1. Stack

| Peça | Biblioteca | Papel |
|---|---|---|
| Canvas de nós/arestas, pan/zoom, minimapa | `@xyflow/react` (React Flow v12) | renderização e interação do grafo |
| Auto-layout | `@dagrejs/dagre` | posiciona nós automaticamente quando ainda não têm posição |

```json
"@xyflow/react": "^12.11.2",
"@dagrejs/dagre": "^3.0.0"
```

Nenhuma outra dependência de canvas é necessária — o resto (formulários de configuração por nó, painel de
validação) é UI comum do projeto (shadcn/ui no caso do wacrm).

## 2. A decisão de arquitetura que organiza tudo: edges derivadas, não armazenadas

Já introduzida em `01-modelo-de-dados.md`, mas é aqui que ela se manifesta na prática. O canvas **não lê
uma lista de arestas do banco** — ele computa as arestas a cada render, a partir do `config` de cada nó.

```ts
// src/lib/flows/edges.ts (wacrm) — resumo do algoritmo
function deriveCanvasEdges(nodes: BuilderNode[]): CanvasEdge[] {
  const edges = [];
  for (const node of nodes) {
    switch (node.node_type) {
      // Nós de saída única: uma aresta a partir de config.next_node_key
      case "start": case "send_message": case "send_media":
      case "collect_input": case "set_tag": case "wait": // wait é NOVO, mesma regra
        if (node.config.next_node_key) {
          edges.push({ source: node.node_key, target: node.config.next_node_key, sourceHandle: "next" });
        }
        break;

      // condition: duas saídas nomeadas
      case "condition":
        if (node.config.true_next)  edges.push({ source: node.node_key, target: node.config.true_next,  sourceHandle: "true",  label: "true" });
        if (node.config.false_next) edges.push({ source: node.node_key, target: node.config.false_next, sourceHandle: "false", label: "false" });
        break;

      // send_buttons / send_list: uma saída por botão/linha
      case "send_buttons":
        for (const btn of node.config.buttons) {
          edges.push({ source: node.node_key, target: btn.next_node_key, sourceHandle: `button:${btn.reply_id}`, label: btn.title });
        }
        break;

      // handoff / end: sem saída (nó terminal)
    }
  }
  return edges;
}
```

O caminho inverso — o usuário arrasta uma conexão no canvas — escreve de volta dentro do `config` do nó de
origem:

```ts
function applyEdgeConnection(node, sourceHandle, targetKey) {
  // sourceHandle "next" → seta config.next_node_key
  // sourceHandle "true"/"false" → seta config.true_next/false_next
  // sourceHandle "button:<id>" → encontra o botão certo no array e seta seu next_node_key
  // retorna o PATCH a aplicar no config do nó — não uma tabela de edges
}
```

E ao deletar um nó, uma função de limpeza varre todos os outros nós e zera qualquer referência ao nó
deletado (`unlinkNodeReferences`) — assim nunca sobra uma seta "fantasma" apontando pro vazio.

**Por que replicar essa decisão no ImobFlow, em vez de uma tabela `flow_edges` mais "tradicional"**: o
motor de execução (que roda a cada mensagem/evento recebido, potencialmente sob carga) nunca precisa de
JOIN pra saber "pra onde vou daqui" — é um campo já carregado na mesma linha do nó. O custo fica todo do
lado do builder (que roda raramente, sob interação humana), não do lado do runtime.

## 3. Renderização: um card por nó

Cada nó vira um card React customizado (`FlowNodeCard`), com:
- **Ícone + cor por `node_type`** (`NODE_META`, `nodeColors()` em `shared.tsx`) — cada tipo de nó tem uma
  cor OKLCH própria (`NODE_HUE`), derivando tons "soft" (fundo do chip), "ring" (borda em hover) e "text"
  (label, com contraste garantido em claro e escuro via `color-mix`).
- **Handle de entrada** à esquerda (todo nó exceto `start` aceita entrada).
- **Handle(s) de saída** à direita — nós de saída única ganham um handle; nós multi-saída (`condition`,
  `send_buttons`, `send_list`) renderizam uma linha por slot, cada uma com seu próprio handle, para que o
  usuário arraste a conexão certa a partir do botão/linha/branch certo.
- **Resumo de uma linha** (`summarizeNode()`) — texto truncado mostrando o conteúdo relevante sem abrir o
  card (ex. `send_message` mostra o início do texto; `condition` mostra `var.nome == "valor"`).
- **Badge "Entry"** no nó de entrada do fluxo.
- **Flash de destaque** (borda âmbar por ~1.6s) quando o usuário clica num item da lista de erros de
  validação — o canvas dá pan até o nó e pisca a borda, pra "aqui está o problema".

Sugestão de card visual para o nó `wait` (novo): ícone de relógio/ampulheta, cor própria na paleta (ex. um
tom âmbar/laranja distinto do `condition`), resumo tipo `"Espera 1 dia"` / `"Espera 30 minutos"`.

## 4. Auto-layout (dagre)

Problema: um flow novo, ou um flow migrado de uma versão anterior sem canvas, tem todos os nós na posição
`(0,0)` — o que renderizaria uma pilha sobreposta ilegível.

```ts
function shouldAutoLayout(nodes): boolean {
  // true SÓ SE todo nó estiver em (0,0) — um flow parcialmente
  // posicionado é considerado "em edição", não mexe nas posições que
  // o usuário já escolheu manualmente.
  return nodes.length > 0 && nodes.every(n => (n.position_x ?? 0) === 0 && (n.position_y ?? 0) === 0);
}

function autoLayout(nodes, edges, { direction: "TB" }) {
  // dagre calcula rank (nível vertical) + order (posição horizontal
  // dentro do nível), lidando bem com cruzamento de arestas em
  // grafos com ramificação (condition, send_buttons).
}
```

O layout automático roda **uma vez** ao montar o canvas (não a cada render) e, quando dispara, as posições
calculadas são persistidas de volta no estado do editor — senão o próximo drag de um único nó "esqueceria"
a posição calculada dos outros e eles voltariam pra `(0,0)`.

## 5. Estado do editor — uma fonte única para duas visões

O wacrm oferece **duas visões da mesma estrutura**: uma lista vertical (formulário por nó, sem canvas) e o
canvas. Ambas leem e escrevem o **mesmo contexto React** (`useFlowEditor()`), então alternar de visão nunca
perde edições não salvas.

```ts
interface BuilderState {
  name: string;
  description: string;
  trigger_type: "keyword" | "first_inbound_message" | "manual";
  trigger_config: Record<string, unknown>;
  entry_node_id: string | null;
  status: "draft" | "active" | "archived";
  nodes: BuilderNode[];
}

interface FlowEditorContextValue {
  state: BuilderState;
  dirty: boolean; saving: boolean; activating: boolean;
  issues: ValidationIssue[]; canActivate: boolean;

  addNode: (type: NodeType) => string;          // retorna a node_key gerada
  updateNodeConfig: (key: string, patch: Record<string, unknown>) => void;
  updateNodePosition: (key: string, x: number, y: number) => void;
  removeNode: (key: string) => void;             // já limpa referências pendentes

  save: () => Promise<void>;                     // PUT /api/flows/[id]
  setStatus: (status) => Promise<void>;           // POST /api/flows/[id]/activate
  deleteFlow: () => Promise<void>;

  flashKey: string | null;                        // sinal "olhe aqui" cross-view
  requestFlash: (key: string) => void;
}
```

Detalhes que valem a pena copiar:
- **`addNode` retorna a `node_key` gerada** (slugify do label + sufixo numérico se colidir) para o chamador
  poder abrir o painel de edição do nó recém-criado imediatamente.
- **`dirty` só é marcado por edição do usuário**, não pela hidratação do auto-layout inicial — senão o
  botão "Salvar" e o guard de `beforeunload` disparariam ao simplesmente abrir um flow legado.
- **`save()` sempre roda antes de `setStatus("active")`** — o usuário nunca precisa lembrar de salvar
  antes de ativar; a validação de ativação já vê o estado mais recente.
- Um `beforeunload` handler avisa o usuário se ele tentar fechar a aba com edições não salvas.

## 6. Validação em tempo real

`validateFlowForActivation(flow, nodes)` roda a cada mudança de estado (via `useMemo`) e devolve uma lista
de `{ severity: "error"|"warning", scope: "flow"|"trigger"|"node", node_key?, field?, message }`. O painel
de validação lista os problemas; clicar em um problema chama `requestFlash(node_key)`, que o canvas usa
para dar pan até o nó e piscar a borda.

`canActivate` é simplesmente `issues.every(i => i.severity !== "error")` — o botão "Ativar" fica desabilitado
enquanto houver erro (warnings não bloqueiam).

## 7. Painel de edição por nó

Ao clicar num nó do canvas, abre um painel lateral (`Sheet`) com um formulário específico do `node_type`
(`NodeConfigForm`, despachado por tipo). O mesmo formulário é reaproveitado pela visão de lista — um único
componente de formulário por tipo de nó, usado nas duas visões.

Para o nó `wait` novo, o formulário seria simples: um input numérico (`amount`), um seletor de unidade
(`minutes`/`hours`/`days`), e o seletor de próximo nó (`next_node_key`) — mesmo padrão dos outros nós de
saída única.

## 8. Menu de adicionar nó

Botão flutuante (canto do canvas) com dropdown agrupado por categoria (`groupNodeTypesByCategory`):

| Categoria | Nós |
|---|---|
| Mensageria | `send_message`, `send_buttons`, `send_list`, `send_media` |
| Lógica e dados | `collect_input`, `condition`, `set_tag`, **`wait` (novo)** |
| Controle de fluxo | `start`, `handoff`, `end` |

`wait` se encaixa naturalmente em "Lógica e dados" — não é uma mensagem, é uma pausa controlada na
execução.

## 9. Interações do canvas — checklist para replicar

- [x] Arrastar nó → persiste posição só no `dragStop` (não a cada frame do drag), barato.
- [x] Arrastar de um handle de saída até outro nó → conecta (`onConnect` → `applyEdgeConnection`).
- [x] Self-loop (nó apontando pra si mesmo) → rejeitado silenciosamente (evita reprompt infinito acidental).
- [x] Delete/Backspace num nó selecionado → remove o nó E limpa toda referência a ele nos outros nós.
- [x] Delete numa aresta selecionada → limpa só aquele slot específico (não remove o nó).
- [x] Clique num nó → abre painel de edição lateral.
- [x] "Marcar como entrada" / "Excluir" no rodapé do painel de edição.
- [x] Minimapa colorido por tipo de nó, controles de zoom (min 0.2x, max 1.5x — os cards já truncam o
      resumo, não precisa zoom além de 1.5x).
- [x] Grade de pontos de fundo, tema-aware (usa tokens CSS do design system, não cor fixa).

## 10. Recomendação de implementação no ImobFlow

1. Portar `shared.tsx` (tipos, `NODE_META`, `nodeColors`) primeiro — é puro TS/React, zero dependência de
   canvas, fácil de testar isoladamente.
2. Portar `edges.ts` (deriveCanvasEdges, applyEdgeConnection, unlinkNodeReferences) — também puro, sem
   React Flow — inclua o `wait` na lista de nós de saída única desde o início.
3. Portar `layout.ts` (wrapper de dagre) — puro.
4. Só depois montar o componente de canvas em si (`flow-canvas.tsx`), consumindo as três peças acima.
5. `flow-editor-state.tsx` (o contexto) pode ser construído em paralelo ao canvas — é a "cola" que faltará
   por último.
