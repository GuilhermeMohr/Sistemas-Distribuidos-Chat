# Brainiac Context — mensagens i18n (Português Brasil)
# Carregado pelos scripts de hook quando BRAINIAC_LANG=pt-BR.

# --- Comum ---
MSG_HEADER="[Brainiac Clean Code Gate]"

# --- Gate: Nomes de arquivo proibidos ---
MSG_BANNED_FILENAME="Padrão de nome de arquivo proibido (Regra No Limbo)."
MSG_BANNED_FILENAME_HINT="Renomeie o arquivo com nome significativo e específico do domínio. Prefixos proibidos: wip-, temp-, old-, unused-, legacy-."

# --- Gate: Tamanho de arquivo ---
MSG_FILE_TOO_LARGE="Arquivo excede 500 linhas em código de produto."
MSG_FILE_TOO_LARGE_HINT="Divida por responsabilidade, ou adicione marcador 'brainiac-allow-large reason=\"...\"' nas 10 primeiras linhas se dividir fragmenta o domínio."

# --- Gate: any sem justificativa ---
MSG_ANY_FORBIDDEN="Uso de \`: any\` sem justificativa inline."
MSG_ANY_FORBIDDEN_HINT="Substitua 'any' por tipo explícito. Se realmente necessário (ex: parsing de boundary), adicione comentário '// brainiac:any-ok reason=\"...\"' na mesma linha."

# --- Gate: SEC-1 token/secret leak ---
MSG_SEC1_TOKEN_LEAK="Padrão de token/secret detectado (SEC-1 do SECURITY_STANDARDS)."
MSG_SEC1_TOKEN_LEAK_HINT="Remova o token literal imediatamente. Três passos: (1) rotar no provider (revoke/regenerate), (2) substituir no código com referência a env var (ex: process.env.GITHUB_TOKEN), (3) auditar blast radius no provider. NÃO existe exemption para SEC-1 — marker '// security-allow' não vale aqui."

# --- Gate: Proteção de canonicals ---
MSG_CANONICAL_HEADER="[Brainiac Canonical Gate]"
MSG_CANONICAL_BLOCKED="Edição bloqueada: o alvo é um canonical do framework em context/agents/brainiac/."
MSG_CANONICAL_HINT_1="Caminho preferido: refatore a mudança como Project Extension em context/agents/project/ via /brainiac-context-agent."
MSG_CANONICAL_HINT_2="Caminho oficial: rode /brainiac-context-update pra evoluir canonicals."
MSG_CANONICAL_HINT_3="Bypass justificado: inclua o marker brainiac-canonical-edit reason=\"...\" dentro do payload do Edit/Write — reviewer auditará depois."

# --- Gate: Context Hygiene / PostCompact (Iron Law 7) ---
MSG_POST_COMPACT_HEADER="=== Brainiac post-compact reload (Iron Law 7) ==="
MSG_POST_COMPACT_LINE_TRIGGER="Compact concluído, trigger"
MSG_POST_COMPACT_LINE_FRAMEWORK="Framework spec foi re-injetado via @AGENTS.md -> @context/.brainiac-context-framework.md (import chain)."
MSG_POST_COMPACT_LINE_CRITICAL="Antes de trabalho crítico (Build / Learn / framework update / migração / refactor / bugfix complexo):"
MSG_POST_COMPACT_STEP1="Confirme acesso a Iron Laws 1-7 (framework spec carregado)."
MSG_POST_COMPACT_STEP2="Releia o intent ativo (feature-*.md / bug-*.md / refactor-*.md)."
MSG_POST_COMPACT_STEP3="Releia ADRs referenciados na seção Related do intent."
MSG_POST_COMPACT_STEP4="Verifique .brainiac/last-compact-state.json para o handoff."
MSG_POST_COMPACT_STEP5="Rode /context — se >=60%, continuar trabalho crítico sem novo /compact (continuação) ou /clear (troca real de escopo) é Brainiac violation (Iron Law 7.5). Os dois não são intercambiáveis: use /compact quando continuando o mesmo workflow; /clear apenas entre ciclos distintos."
MSG_POST_COMPACT_FOOTER="Se for continuação simples, o summary é suficiente."

# --- Gate: Context Hygiene / PreCompact (Iron Law 7) ---
MSG_PRE_COMPACT_HEADER="[Brainiac pre-compact]"
MSG_PRE_COMPACT_BODY="Compact iniciando. Iron Law 7: handoff salvo em .brainiac/last-compact-state.json. post-compact.sh injetará o checklist de reload. Se este compact é resposta a scope-switch, considere /clear ao invés (Iron Law 7.4)."
MSG_PRE_COMPACT_BLOCKED_REASON="Auto-compact bloqueado por BRAINIAC_BLOCK_AUTOCOMPACT=1 (opt-in). Rode /compact manualmente pra confirmar, ou unset a env var pra liberar."

# --- Gate: Minimum Context Gate ---
MSG_GATE_BLOCK_HEADER="[Brainiac Minimum Context Gate]"
MSG_GATE_VERSIONED_FATAL="Bypass via .claude/settings.json (versionada) é proibido. Isso é anti-pattern estrutural: bypass=true versionado vira bypass permanente silencioso commitado. Use shell env (export BRAINIAC_CONTEXT_GATE_BYPASS=true) ou .claude/settings.local.json (não versionado)."
MSG_GATE_BYPASS_NO_REASON="Bypass requer BRAINIAC_CONTEXT_GATE_BYPASS_REASON com ao menos 12 caracteres visíveis. Exemplo: export BRAINIAC_CONTEXT_GATE_BYPASS_REASON='hotfix pipeline prod quebrado'"
MSG_GATE_BYPASS_NOTICE="Brainiac Minimum Context Gate bypass registrado em"
MSG_GATE_MISSING_INTENT="Intent ativo da task ausente — leia context/intent/feature-*.md, bug-*.md ou refactor-*.md antes de editar código de produto."
MSG_GATE_MISSING_STANDARDS="Standards (code/security) não carregados — leia context/code-standards.md e context/security-standards.md."
MSG_GATE_MISSING_SENSORS="context/sensors/sensors.md existe no projeto mas não foi carregado nesta sessão. Leia antes de editar código de produto."
MSG_GATE_UNLOCK="Pra destravar: Read em project-intent.md + intent ativo + code-standards.md + security-standards.md (+ sensors.md se presente). Depois refaça a edição."

# --- Gate: Context Research Subagent ---
MSG_RESEARCH_GATE_BLOCK_HEADER="[Brainiac Context Research Gate]"
MSG_RESEARCH_GATE_VERSIONED_FATAL="Bypass via .claude/settings.json (versionada) é proibido. Anti-pattern estrutural. Use shell env (export BRAINIAC_RESEARCH_GATE_BYPASS=true) ou .claude/settings.local.json."
MSG_RESEARCH_GATE_BYPASS_NO_REASON="Bypass requer BRAINIAC_RESEARCH_GATE_BYPASS_REASON com no mínimo 12 caracteres visíveis. Exemplo: export BRAINIAC_RESEARCH_GATE_BYPASS_REASON='spike exploratório antes do research formal'"
MSG_RESEARCH_GATE_BYPASS_NOTICE="Bypass do Brainiac Context Research Gate registrado em"
MSG_RESEARCH_GATE_MISSING="Research report ausente para o intent ativo. Rode /brainiac-context-research para gerar context/research/<intent-slug>.md mapeando ADRs/knowledge referenciados transitivamente."
MSG_RESEARCH_GATE_STALE="Research report está stale (intent modificado, dependência atualizada, TTL expirado, ou refs incompletas). Rode /brainiac-context-research para regenerar."
MSG_RESEARCH_GATE_UNLOCK="Para destravar: rode /brainiac-context-research (auto-invocado ou manual) para (re)gerar context/research/<intent-slug>.md. Hook enforça existência + freshness + completude — agente principal ainda DEVE reler artefatos críticos diretamente. Discovery evidence != execution clearance."

# --- Gates workflow-aware: subagent de Dynamic Workflow nativo ---
MSG_WORKFLOW_CONTEXT_REQUIRED="BRAINIAC_WORKFLOW_CONTEXT_REQUIRED — este edit está rodando dentro de um subagent de Dynamic Workflow nativo, que herda o transcript da sessão-mãe. O active intent NÃO pode ser confiado a partir do transcript, e nenhum binding de workflow válido foi encontrado. Um write de código de produto exige um binding explícito e validado (.brainiac/workflow-bindings/index.json) ancorado a um approval envelope aprovado (ENVELOPE_APPROVAL por hash). Gere o workflow via /brainiac-context-orchestrate-workflow-export para que cada subagent carregue seu binding. Para permitir writes exploratórios sem binding, defina BRAINIAC_WORKFLOW_UNBOUND=advisory (o block de write degrada para warning)."
MSG_WORKFLOW_UNBOUND_ADVISORY="Brainiac workflow gate: write de subagent de workflow sem binding permitido em modo advisory (BRAINIAC_WORKFLOW_UNBOUND=advisory). O active intent NÃO foi herdado da sessão-mãe; nenhum contexto de intent está sendo enforçado neste write."
# Gate Bash: subagent de workflow sem binding só pode rodar o registrar (Step-0).
MSG_WORKFLOW_BASH_HEADER="[Brainiac Workflow Bash Gate]"

# --- Gate: Scope-switch (Iron Law 7.4) ---
MSG_SCOPE_SWITCH_HEADER="[Brainiac context-hygiene]"
MSG_SCOPE_SWITCH_BODY="Scope switch detectado. Iron Law 7.4: nunca inicie novo escopo em ou acima de 40%.

Ações:
- Rode /context pra ver uso atual.
- Se >=40%, /clear é obrigatório antes de prosseguir (não use /compact pra scope switch).
- /compact só preserva mesma tarefa; perde history detalhada.
- Após /clear, framework spec é re-injetado via @import chain (CLAUDE.md -> @AGENTS.md -> @context/.brainiac-context-framework.md)."

# --- Gate: Secret-Read ---
MSG_SECRET_GATE_HEADER="[Brainiac Secret-Read Gate]"
MSG_SECRET_GATE_BLOCKED="Leitura bloqueada: alvo está na classe de secret files (.env*, secrets/, *.key, *.pem, credentials.json, service-account*.json, *-secret.yaml). CLAUDE.md global (Segurança e escopo): \"Não ler nem pedir segredos\"."
MSG_SECRET_GATE_HINT="Pra saber QUAIS env vars existem, leia código que faz process.env.X / Deno.env.get(). Pra saber VALORES, pergunte ao usuário. Permission denied não é convite pra trocar de arquivo ou tool. Se isto era um filtro jq acessando uma chave chamada env (ex.: jq '.env.FOO'), use bracket notation .[\"env\"] — não é secret file."
MSG_SECRET_GATE_RETRY_HEADER="[Brainiac Secret-Read Gate — RETRY DETECTADO]"
MSG_SECRET_GATE_RETRY_BODY="Esta é sua tentativa N de acessar secret nesta sessão. PARE. Você está em pattern de bypass-via-retry. Reconheça abertamente ao usuário que a evidência que você quer não está disponível sem autorização explícita."
MSG_SECRET_GATE_EXAMPLE_NOTICE="Leitura permitida em .env.example (arquivo de template/exemplo). LEMBRETE: este arquivo NÃO deve conter valores reais. Se você notar secret/credential real durante a leitura, alerte o usuário imediatamente."
MSG_SECRET_GATE_ENV_BLOCKED="Comando bloqueado: ele exporia valores de variáveis de ambiente ou faria parsing runtime de secret file (.env/process.env/env/printenv)."
MSG_SECRET_GATE_ENV_HINT="Alternativas seguras: busque no código pelos NOMES das variáveis (ex.: rg 'process.env.NAME') ou peça os VALORES ao usuário. Não imprima process.env, dumps de env, printenv de variável secreta nem parseie .env em scripts runtime."
MSG_SECRET_GATE_COPY_NOTICE="Cópia opaca same-class permitida: origem e destino são ambos secret-class, então nenhum valor é exposto ao modelo (arquivo → arquivo, jamais stdout). O secret continua etiquetado no destino — leituras futuras sobre ele seguem bloqueadas. Registrado (reason=copy_safe)."
MSG_SECRET_GATE_COPY_LAUNDER_BLOCKED="Cópia bloqueada (vetor de laundering): o destino NÃO é secret-class (arquivo comum, /dev/stdout ou device). Copiar um secret para destino não-secret removeria sua proteção e deixaria uma leitura posterior expor o valor."
MSG_SECRET_GATE_COPY_LAUNDER_HINT="Para copiar um secret para uma worktree, o destino também precisa ser secret-class (ex.: cp .env.local <worktree>/.env.local). Para inspecionar VALORES, peça ao usuário. Nunca copie um secret para /dev/stdout, '-', ou arquivo comum não-secret."
MSG_SECRET_GATE_SHELLVAR_BLOCKED="Comando bloqueado: um comando de output imprimiria o VALOR de uma variável de ambiente sensível via expansão de parâmetro do shell."
MSG_SECRET_GATE_SHELLVAR_HINT="ATENÇÃO: \${VAR:-default} IMPRIME O VALOR sempre que a variável ESTÁ definida — não é o inverso de \${VAR:+palavra}. Para testar EXISTÊNCIA sem revelar: [ -n \"\$VAR\" ] && echo SIM || echo NAO, ou \${VAR:+SIM}. Só o tamanho: \${#VAR}. Para entregar credencial a um processo filho, atribua inline (VAR=\"\$SECRET\" cmd) — isso nunca chega ao stdout. Para saber o VALOR, pergunte ao usuário."

# --- Gate: Knowledge Consultation ---
MSG_KNOWLEDGE_GATE_HEADER="[Brainiac Knowledge Gate]"
MSG_KNOWLEDGE_GATE_BLOCKED="Consulte o knowledge exigido antes deste Write/Edit (policy declarada em context/knowledge/INDEX.md)."
MSG_KNOWLEDGE_GATE_UNLOCK="Pra destravar: Read (ou @ref) o arquivo de knowledge citado acima, aplique o checklist dele, e refaça a edição. Discovery != clearance."
MSG_KNOWLEDGE_GATE_BAD_JSON="Policy inválida: uma linha não-vazia no bloco BRAINIAC:KNOWLEDGE-GATE-RULES não é um objeto JSON. Corrija context/knowledge/INDEX.md (fail-closed: policy quebrada não é bypass silencioso)."
MSG_KNOWLEDGE_GATE_INVALID_RULE="Regra inválida: knowledge_path deve apontar para context/knowledge/{patterns,anti-patterns}/*.md (sem secrets, sem path traversal)."
MSG_KNOWLEDGE_GATE_MISSING_KNOWLEDGE="Regra inválida: o knowledge_path declarado pela regra que casou não existe no disco."
MSG_KNOWLEDGE_GATE_BAD_MODE="Regra inválida: mode deve ser 'block' ou 'advisory'."
MSG_KNOWLEDGE_GATE_BAD_REGEX="Regra inválida: path_regex ausente ou não é uma regex válida. Corrija context/knowledge/INDEX.md (fail-closed: predicado de match inavaliável não vira bypass silencioso)."
MSG_KNOWLEDGE_GATE_BYPASS_NO_REASON="Bypass requer BRAINIAC_KNOWLEDGE_GATE_BYPASS_REASON com no mínimo 12 caracteres visíveis. Exemplo: export BRAINIAC_KNOWLEDGE_GATE_BYPASS_REASON='hotfix, knowledge já internalizado'"
MSG_KNOWLEDGE_GATE_SETTINGS_GUARD="Bypass via .claude/settings.json (versionada) é proibido. Anti-pattern estrutural: bypass=true versionado vira bypass permanente silencioso. Use shell env (export BRAINIAC_KNOWLEDGE_GATE_BYPASS=true) ou .claude/settings.local.json (não versionada)."

# --- Gate: No Auto-Merge ---
MSG_NOMERGE_HEADER="[Brainiac No Auto-Merge Gate]"
MSG_NOMERGE_FORCE="Bloqueado: force-push destrutivo para main."
MSG_NOMERGE_ACTIVE="Bloqueado: merge durante uma run de orquestração ATIVA (risco de false-green — deixe o closeout do integrate atestar primeiro)."
MSG_NOMERGE_STALE="Aviso: existe uma run de orquestração aberta mas stale (sem atividade recente) — merge permitido; considere fechar a run."
MSG_NOMERGE_HINT="Merge só por humano depois que o closeout do integrate atestar a run. Permitido durante a run: git merge --abort/--continue/--quit, git merge-base. Feche/limpe runs stale em .brainiac/runs/."
