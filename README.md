# Mini-Claude — Clawd Pet 🦀

Um mascote de desktop para Windows: o **Clawd**, o caranguejo do Claude, vive na sua tela, sempre por cima das outras janelas. Ele anda, dorme, dança, segue o cursor com os olhos e, se você quiser, reage em tempo real ao que o **Claude Code** (ou o **Codex**) está fazendo no seu terminal.

Feito inteiramente com o que já vem no Windows: PowerShell 5.1, WinForms e o compilador C# do .NET Framework 4. Não precisa instalar nada.

## O que ele faz

| Situação | Reação |
|---|---|
| Cursor por perto | Para de andar e fica olhando; ao encostar → corações e bochechas coradas |
| Você digitando | Balão de `?` e uma tremidinha confusa |
| Clique esquerdo | Acena, pula, rebola ou dança (aleatório) |
| Arrastar com o mouse | Fica pendurado na garra, balança e entra em **pânico** (olhos arregalados, suor) |
| Soltar | Cai, amassa e pula de alegria |
| Sozinho | Dança, pausa pro café, pensa, se espreguiça, espirra, tira cochilos (Zz…) |
| Claude/Codex trabalhando | Pensando → nuvem de pensamento; lendo → lupa; editando/rodando → trabalhando/cozinhando; terminou → confete 🎉 |
| Clique direito | Menu com todas as animações e opção de sair |
| Ícone na bandeja | Stand-by / acordar, animações, cor, tamanho, som, iniciar com o Windows |

Ele também anda por cima das janelas abertas (`windowPlatforms`), escala as bordas (`climbing`) e reage ao sistema (`systemAwareness`). Cada recurso pode ser ligado ou desligado no `clawd.json`.

## Requisitos

- Windows 10 ou 11
- Windows PowerShell 5.1 (já vem no Windows)
- .NET Framework 4.x (já vem no Windows; só é usado para gerar o `.exe`)

## Como usar

### Opção 1 — Rodar direto pelo script

Dê dois cliques em **`start-clawd.vbs`**. Ele abre o Clawd sem mostrar nenhuma janela do PowerShell.

Na primeira execução, os sprites que estiverem faltando são baixados de `claude.ai` (leva alguns segundos; um aviso aparece e some sozinho).

Para fechar: **`stop-clawd.vbs`**, ou clique direito no Clawd → Quit.

### Opção 2 — Gerar um executável único

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
```

Isso gera **`dist\Clawd.exe`**, um arquivo único com o script, as ferramentas, os assets e os helpers nativos já compilados. Na primeira execução ele se descompacta em `%LOCALAPPDATA%\ClawdPet`; o `clawd.json` que fica lá guarda as suas configurações e nunca é sobrescrito por atualizações.

```text
Clawd.exe [standby] [-PerfLog <arquivo.json>] [-TestBlink]
```

- `standby` — inicia dormindo (só o ícone na bandeja)
- `-PerfLog` — a cada 5 s grava a taxa de quadros e o custo por quadro de cada pose
- `-TestBlink` — testa só a geração de sprites, sem abrir janela

### Iniciar com o Windows

```powershell
.\autostart-on.ps1    # cria um atalho na pasta Inicializar
.\autostart-off.ps1   # remove o atalho
```

Também dá para ativar pelo menu da bandeja, com a opção de já iniciar em stand-by.

## Integração com agentes de IA

### Claude Watch (Claude Code)

```powershell
.\tools\claude-watch-on.ps1    # instala os hooks
.\tools\claude-watch-off.ps1   # remove os hooks
```

Adiciona hooks ao `~/.claude/settings.json` (os seus outros hooks não são mexidos). A cada evento, o hook chama `tools\clawd-emit.cmd`, que grava a atividade atual (`think`, `bash`, `edit`, `read`, `web`, `task`, `notify`, `done`) em `%TEMP%\clawd-status.txt`. O Clawd lê esse arquivo e encena o que o Claude está fazendo. Pode rodar o script várias vezes sem problema.

### Codex Watch

```powershell
.\tools\codex-watch-on.ps1     # ativa
.\tools\codex-watch-off.ps1    # desativa
```

Mesma ideia, para o Codex CLI (respeita `CODEX_HOME` se estiver definido).

## Configuração — `clawd.json`

```jsonc
{
  "standbyOnStartup": true,       // inicia dormindo
  "monitor": "\\\\.\\DISPLAY2",   // em qual monitor ele vive
  "color": "Coral",               // cor da carapaça
  "size": 44,                     // tamanho
  "walkSpeed": 1.0,
  "gravity": 1.0,
  "idleSecondsMin": 5,            // intervalo entre ações espontâneas
  "idleSecondsMax": 10,
  "blinkSecondsMin": 2.5,         // intervalo entre piscadas
  "blinkSecondsMax": 5.5,
  "features": {
    "eyeTracking": true,          // olhos seguem o cursor
    "windowPlatforms": true,      // anda por cima das janelas
    "typingReaction": true,       // reage quando você digita
    "edgeLurking": false,         // fica espiando da borda da tela
    "systemAwareness": true,      // reage ao estado do sistema
    "climbing": true,             // escala bordas
    "mischief": true,             // travessuras
    "claudeWatch": true,          // integração com Claude Code
    "codexWatch": true            // integração com Codex
  }
}
```

Cor, tamanho e som também podem ser trocados pelo menu da bandeja.

## Estrutura do projeto

```text
Mini-Claude/
├── clawd-pet.ps1          # o programa principal (janela, animações, física, menus, bandeja)
├── clawd.json             # configurações
├── start-clawd.vbs        # inicia sem janela do console
├── stop-clawd.vbs         # encerra o Clawd (script ou .exe)
├── autostart-on.ps1       # liga a inicialização com o Windows
├── autostart-off.ps1      # desliga a inicialização com o Windows
├── download-assets.ps1    # baixa os sprites que estiverem faltando
├── build.ps1              # gera dist\Clawd.exe
├── src/
│   ├── ClawdHost.cs       # host do .exe: roda o clawd-pet.ps1 dentro do próprio processo
│   └── ClawdNative.cs     # helpers nativos: cache de quadros, janelas em camadas, relógio, Win32
├── assets/                # sprites e animações (GIF/PNG)
└── tools/
    ├── claude-watch-on/off.ps1   # integração com Claude Code
    ├── codex-watch*.ps1          # integração com Codex
    ├── clawd-emit.cmd            # chamado pelos hooks para gravar o status
    ├── agent-state.ps1           # helpers de estado compartilhados
    ├── make-animations.ps1       # gera as animações extras (café, lupa, confete, amor…)
    ├── asset-validation.ps1      # valida os arquivos de imagem
    ├── preview-bubble.ps1        # gera PNG de prévia dos balões de status
    ├── preview-menu.ps1          # gera PNG de prévia do menu
    └── test-*.ps1                # testes (assets, layout das animações, watch dos agentes)
```

## Desenvolvimento

Depois de mudar qualquer arquivo, rode `build.ps1` de novo para atualizar o `.exe`. Para recriar as animações extras depois de editar alguma:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\make-animations.ps1
```

Testes (Windows PowerShell 5.1, usam arquivos temporários isolados):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-assets.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-agent-watch.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tools\test-animation-layout.ps1
```

## Créditos

- **Autor:** [Guilherme Luis](https://github.com/Guilherme-Luis)
- O personagem **Clawd** e a arte original pertencem à **Anthropic**. Os sprites oficiais vêm de `claude.ai`; quando algum não está disponível, `download-assets.ps1` usa como alternativa o repositório [Zlaxrr/clawd-pet](https://github.com/Zlaxrr/clawd-pet).
- Este é um projeto de fã, sem afiliação com a Anthropic.
