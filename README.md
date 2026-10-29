# AI Quota · Noctalia

Plugin nativo do **Noctalia 5.3 / API 24** para acompanhar na barra o percentual
**restante** das cotas da **OpenAI**, **Anthropic** e **OpenCode Go**.

## O que mostra

- Barra compacta: logo/ícone + percentual restante de cada provedor.
  `--` significa quota indisponível, nunca 0%.
- OpenAI e Anthropic: janela de **5h**. OpenCode Go: janela **mensal**.
- Cores por faixa de quota restante:
  - **vermelho** para `<= 10%`;
  - **âmbar** para `<= 25%`;
  - **verde discreto** acima de `25%`.
- Dados desatualizados preservam o último número, recebem `*`, cor neutra e um
  ícone de alerta. O tooltip informa que o valor é o último conhecido.
- Tooltip com janela (`5h`, `semana`, `mês`), renovação relativa e absoluta,
  horário da última verificação e aviso de dados antigos.
- Clique abre o painel de detalhes com todas as janelas informadas pelo backend
  (por exemplo, 5h e semana), barras de progresso, horários de reset e erros.
- O tooltip é atualizado periodicamente, mesmo sem um novo snapshot, para manter
  a contagem regressiva de reset legível.

OpenAI usa `brand-openai` da fonte Tabler. Anthropic usa o símbolo terracota do
Claude fornecido pelo Dashboard Icons; OpenCode Go usa o logotipo oficial da
página de marca do OpenCode. Os SVGs ficam em `ai-quota/icons/`, com as fontes
documentadas em `ai-quota/icons/README.md`, sem downloads durante a exibição.
As cores dos logotipos são preservadas; a cor do percentual indica a quota.

## Dependência e privacidade

O backend do plugin depende do serviço local do pacote
**`@slkiser/opencode-quota`** instalado no ambiente do OpenCode. Ele consulta o
RPC local autenticado já configurado pelo usuário; **não copia, lê nem armazena
credenciais, tokens ou prompts**.

O endpoint/rota externa desse serviço **não é assumido**. O backend usa o RPC
local do OpenCode (`opencode api rpc.call`, id `slkiser.opencode-quota`) e não
inventa uma URL pública. Se o serviço expuser um endpoint, ele não é necessário
para este plugin.

O snapshot publicado contém apenas id/nome do provedor, janela, percentual
restante, horários de reset/verificação, estado `stale` e mensagens de erro
sanitizadas. As mensagens de erro do CLI não são repassadas para a interface.

## Backend

O contrato usado pela interface é:

```text
python3 -u <pluginDir>/backend.py serve --interval 60
```

- Emite uma linha JSON por snapshot, aproximadamente a cada 15 segundos
  (uma consulta lenta pode atrasar esse heartbeat em até 90 s).
- Consulta o RPC a cada 60 s por padrão, com `refresh` e motivo `poll`.
  As APIs dos provedores respeitam o cache, backoff e intervalo do próprio
  `opencode-quota` (padrão: 5 minutos; uso pelo OpenCode pode atualizar antes).
- A idade exibida vem da última leitura bem-sucedida do provedor, não do polling.
  Janelas encerradas ou leituras com mais de 15 minutos são marcadas como antigas
  mesmo entre consultas. Múltiplas contas usam o menor percentual por janela.
- `snapshot` é um comando único de diagnóstico:

```sh
python3 ai-quota/backend.py snapshot
```

Exemplo fictício do formato:

```json
{
  "ok": true,
  "updated_at": 1767225600,
  "error": null,
  "providers": [
    {
      "id": "openai",
      "name": "OpenAI",
      "window": "five_hour",
      "remaining": 34,
      "resets_at": "2026-01-01T05:00:00Z",
      "checked_at": 1767225600,
      "stale": false,
      "error": null,
      "windows": [
        { "window": "five_hour", "remaining": 34, "resets_at": "2026-01-01T05:00:00Z" }
      ]
    }
  ]
}
```

`remaining` é sempre o percentual que **resta**. `remaining: null` é
indisponibilidade, não zero. `ok` falso indica que pelo menos uma cota está
desatualizada ou indisponível.

O serviço do Noctalia:

- inicia o backend com `runStream`;
- valida cada linha e ignora snapshots incompletos/inválidos, preservando o
  último snapshot completo;
- tenta iniciar novamente a cada 30 s se o `runStream` falhar;
- usa um watchdog de **150 s**. Sem quadros nesse período, mantém os últimos
  valores, marca todos os provedores como `stale` e expõe
  `stale_transport = true`;
- se recupera automaticamente ao receber um novo quadro completo.

### Limitação da API 24

Na API 24, `noctalia.runStream()` retorna um booleano e não oferece um handle
para encerrar o processo. Por isso, um backend pendurado (mas ainda vivo) não é
morto e reiniciado automaticamente, para não criar dois pollers concorrentes.
O watchdog sinaliza os dados como desatualizados e a recuperação acontece
quando o processo volta a emitir ou quando o plugin é recarregado. Se uma versão
futura da API devolver um handle com `stop()`, o serviço já o utiliza para
parar e reiniciar com segurança.

## Configuração

- **Intervalo de consulta (segundos):** 60 s por padrão, mínimo 60, máximo 600.
  O backend também publica o último snapshot a cada 15 s.
- Configurações ficam em **Configurações de plugins** no Noctalia, ou pela
  engrenagem do painel.

## Instalação

Requisitos: Noctalia com suporte à API 24, Python 3.11+, OpenCode V2 e
`@slkiser/opencode-quota` v6 instalado no serviço local, com os provedores
autenticados. O OpenCode deve estar no `PATH`, em `~/.opencode/bin/opencode`
ou em `~/.local/bin/opencode`.

```sh
mkdir -p "$HOME/Projetos"
git clone https://github.com/ggmorais/noctalia-ai-quota.git "$HOME/Projetos/noctalia-ai-quota"
noctalia msg plugins source add ai-quota-local path "$HOME/Projetos/noctalia-ai-quota"
noctalia msg plugins enable local/ai-quota
```

Adicione o widget à lista da barra (preservando os demais itens), por exemplo em
`~/.config/noctalia/config.toml`:

```toml
[widget.ai_quota]
type = "local/ai-quota:bar"
capsule = true
```

Depois:

```sh
noctalia msg config-reload
# Abrir o painel sem clicar na barra:
noctalia msg panel-open local/ai-quota:details
```

Se a barra foi personalizada pela interface, a lista em
`~/.local/state/noctalia/settings.toml` tem precedência; inclua o widget também
lá ou use o editor de barra do Noctalia.

## Diagnóstico e testes

```sh
python3 ai-quota/backend.py snapshot
python3 -m unittest discover -s tests -v
lua tests/test_ui.lua
lua tests/test_service.lua
noctalia plugins lint ai-quota
```

Os testes de UI usam um host Lua mínimo e verificam renderização, limites
10/25, `--`, `stale`, tooltip, painel, janelas extras e o watchdog de 150 s.

## Limitações conhecidas

- A interface não lê credenciais nem implementa autenticação própria: depende do
  serviço local do `@slkiser/opencode-quota` e do CLI do OpenCode.
- O logotipo do OpenCode usa a variante oficial para fundos escuros, adequada
  ao tema atual da barra.
- O backend é quem define os erros e a política de `stale` de cada provedor.
  A UI apenas preserva e sinaliza o que recebe.
- Para desativar: `noctalia msg plugins disable local/ai-quota` e remova
  `ai_quota` da lista da barra. O Noctalia gerencia o coletor; não há unidade
  systemd adicional nem processo de monitoramento independente para encerrar.
