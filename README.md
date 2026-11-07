
## !! > This program is currently under development. New features are actively being added, including a language switcher and extra functionalities, alongside ongoing bug fixes.


# 🔋 Universal Linux Battery Manager (`gerenciador-bateria`)

**Intelligent Charge Threshold & AC Auto-Discharge Manager for Linux Laptops**  
*Gerenciador Inteligente de Limites de Carga e Descarga Automática na Tomada para Notebooks Linux*

<br />

🌐 **Select Language / Escolha o Idioma:**  
[🇺🇸 **English Documentation**](#-english-documentation) &nbsp;|&nbsp; [🇧🇷 **Documentação em Português**](#-documentação-em-português)

</div>

---

# 🇺🇸 English Documentation

## 📖 Overview

**Universal Linux Battery Manager (`gerenciador-bateria`)** is a lightweight, zero-dependency, standalone Bash utility and `systemd` daemon designed to extend the lifespan of lithium-ion laptop batteries on Linux (**Arch Linux, Ubuntu, Debian, Fedora, openSUSE**, etc.).

Unlike standard battery threshold scripts that merely set static `/sys/class/power_supply` limits, this project introduces **Smart AC Auto-Discharge** and a **Zero-Latency Native Terminal UI (TUI)** built directly on `/dev/tty`.

### ✨ Key Features

- 🤖 **100% Automatic Hardware Detection**: Natively supports **Lenovo (ThinkPad / IdeaPad)**, **ASUS (ROG / ZenBook / TUF / VivoBook)**, **Dell / Alienware**, and generic Linux `sysfs` interfaces.
- ⚡ **Smart AC Auto-Discharge (`force-discharge`)**: Solves the "100% Stagnation Problem" when your laptop is charged while powered off.
- 🖥️ **Zero-Latency Native TUI**: Built in pure Bash with ANSI escape sequences reading directly from `/dev/tty`—supports Arrow keys (`↑`/`↓`), Vim keys (`j`/`k`), numeric shortcuts (`0-5`), and **instant single-press `ESC` exit** with zero external dependencies (`whiptail`/`dialog` not required!).
- 🛡️ **Sleep / Hibernation Persistence**: Automatically re-applies charge limits if the BIOS/EC resets them after suspend or hibernation.
- 🔒 **Hardened `systemd` Daemon**: Runs in the background with virtually **0% CPU usage**, strict filesystem protections, and safety cutoffs.

---

## 🚀 The Killer Feature: Smart AC Auto-Discharge

### The "100% Stagnation" Problem
When you plug in your laptop while it is turned **off**, the motherboard's Embedded Controller (EC) often ignores OS-level limits and charges the battery to **100%**. With ordinary threshold tools, when you boot into Linux with the AC adapter plugged in, the laptop switches to *AC Bypass* mode—leaving your battery **trapped at 100% charge under high voltage and thermal stress** for days or weeks.

### How `gerenciador-bateria` Solves It
```text
[Boot on AC at 100%] ──► Daemon detects Capacity (100%) > End Threshold (80%)
                     ──► Activates kernel 'force-discharge' while plugged in
                     ──► Safely drains battery on AC power down to Start Threshold (75%)
                     ──► Restores 'auto' mode ──► Recharges to 80% & enters AC Bypass rest!
```
1. **Detection**: When plugged into AC power with battery charge above your stop limit (e.g., `> 80%`), the daemon triggers `force-discharge`.
2. **Safe Drain on AC**: The laptop uses battery power even while plugged into the wall until it reaches your start threshold (**75%**).
3. **Rest & Bypass**: Once **75%** is reached, it switches back to `auto`, charges to **80%**, and rests peacefully on AC power.
4. **Safety Cutoff**: Includes a built-in hardware safety lock that aborts forced discharge if battery capacity ever drops $\le 20\%$ or if AC power is unplugged.

---

## 🖥️ Interactive Terminal UI (TUI)

Run `sudo gerenciador-bateria` (or `sudo gerenciador_bateria`) with no arguments to launch the interactive panel:

```text
┌──────────────── Gerenciador de Bateria Universal ────────────────┐
│ Bateria: 79% (Tomada Conectada 🔌) | Lenovo ThinkPad             │
│ Auto-Discharge: [ATIVADO ✅] | Limites: 75% - 80%                │
├──────────────────────────────────────────────────────────────────┤
│ Escolha uma opção (Setas ↑/↓, Números 0-5 ou ESC para sair):     │
│                                                                  │
│    1 📊 Ver Status Detalhado da Bateria                          │
│    2 ⚡ Desativar Descarga Inteligente                           │
│    3 🎯 Alterar Limites de Carga (75% - 80%)                     │
│    4 ⚡ Forçar Descarga Imediata na Tomada                       │
│    5 🔌 Restaurar Padrão de Fábrica (100%)                       │
│    0 🚪 Sair do Programa                                         │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│          [ENTER] Selecionar               [ESC / q] Sair         │
└──────────────────────────────────────────────────────────────────┘
```

### ⌨️ Keyboard Controls
- **Up / Down Arrows (`↑` / `↓`)** or **Vim Keys (`k` / `j`)**: Move selection highlight.
- **Numbers (`1` - `5`, `0`)**: Trigger menu actions directly.
- **`ENTER`**: Confirm selection.
- **`ESC` or `q`**: Instantaneously exit any screen, popup, or submenu.

---

## 🛠️ Hardware Compatibility Matrix

The script inspects `/sys/class/dmi/id/sys_vendor` and automatically selects the appropriate kernel interface:

| Manufacturer | Supported Lineups | Kernel Driver / Backend | Start Limit | Stop Limit | Auto-Discharge |
| :--- | :--- | :--- | :---: | :---: | :---: |
| **Lenovo** | ThinkPad, IdeaPad, Yoga | `thinkpad_acpi` (`sysfs`) | ✅ Yes | ✅ Yes | ✅ Yes (`charge_behaviour`) |
| **ASUS** | ROG, ZenBook, TUF, VivoBook | `asus_wmi` (`sysfs`) | ⚙️ Firmware (~75%) | ✅ Yes | ⚙️ Model dependent |
| **Dell / Alienware** | XPS, Latitude, Inspiron, Precision | `dell_wmi_sysman` / `libsmbios` / `cctk` | ✅ Yes | ✅ Yes | ⚙️ Model dependent |
| **Generic** | Huawei, Framework, System76, etc. | Standard Linux `power_supply` `sysfs` | ✅ If exposed | ✅ Yes | ⚙️ If exposed |

---

## 📦 Installation & Usage

### 1. Install (One-Liner)
Clone the repository and run the installer as `root`:

```bash
git clone https://github.com/AlanSchaffer/gerenciador-bateria.git
cd gerenciador-bateria
chmod +x gerenciador-bateria.sh
sudo ./gerenciador-bateria.sh install
```

**What the installer does:**
- Copies the binary to `/usr/local/bin/gerenciador-bateria` and creates a convenient symlink `/usr/local/bin/gerenciador_bateria`.
- Generates the configuration file at `/etc/gerenciador-bateria.conf` (default: `75%` start, `80%` stop, `AUTO_DISCHARGE=true`).
- Cleans up legacy battery services (`thinkpad-battery-charge-limit.service`, etc.).
- Installs, enables, and starts `gerenciador-bateria.service` in `systemd`.

### 2. Quick CLI Commands

| Command | Description |
| :--- | :--- |
| `sudo gerenciador-bateria` | Opens the interactive Terminal UI (TUI) |
| `sudo gerenciador-bateria on` | Enables Smart AC Auto-Discharge |
| `sudo gerenciador-bateria off` | Disables Smart AC Auto-Discharge (keeps static limits) |
| `sudo gerenciador-bateria set 75 80` | Sets custom Start (`75%`) and Stop (`80%`) thresholds |
| `gerenciador-bateria status` | Displays detailed battery health, energy (Wh/Ah), and service status |
| `sudo gerenciador-bateria discharge` | Manually triggers immediate discharge on AC down to Start threshold |
| `sudo gerenciador-bateria stop-discharge` | Cancels manual discharge and returns to `auto` mode |
| `sudo gerenciador-bateria restore` | Restores factory default charging (0% - 100%) |
| `gerenciador-bateria check` | Runs hardware compatibility diagnostics |
| `gerenciador-bateria test` | Runs automated 5-step integrity checks |
| `sudo gerenciador-bateria remove` | Completely uninstalls the script, config, and `systemd` service |

---

<br />

---

# 🇧🇷 Documentação em Português

## 📖 Visão Geral

O **Gerenciador de Bateria Universal (`gerenciador-bateria`)** é um utilitário *standalone* em Bash e daemon do `systemd`, sem dependências externas, projetado para maximizar a vida útil de baterias de íons de lítio em notebooks Linux (**Arch Linux, Ubuntu, Debian, Fedora, openSUSE**, etc.).

Diferente de scripts comuns que apenas gravam limites estáticos no `/sys/class/power_supply`, este projeto traz a **Descarga Inteligente na Tomada (Auto-Discharge)** e uma **Engine TUI Nativa de Baixa Latência** construída diretamente sobre `/dev/tty`.

### ✨ Principais Recursos

- 🤖 **Detecção 100% Automática de Hardware**: Compatível nativamente com **Lenovo (ThinkPad / IdeaPad)**, **ASUS (ROG / ZenBook / TUF / VivoBook)**, **Dell / Alienware** e interfaces genéricas `sysfs` do kernel Linux.
- ⚡ **Descarga Inteligente na Tomada (`force-discharge`)**: Resolve o "Problema do Congelamento em 100%" quando o notebook é carregado desligado.
- 🖥️ **Interface Visual TUI Nativa de Latência Zero**: Desenvolvida em Bash puro com códigos ANSI lendo direto de `/dev/tty` — suporta Setas (`↑`/`↓`), teclas estilo Vim (`j`/`k`), atalhos numéricos (`0-5`) e **saída instantânea com 1 único toque na tecla `ESC`**, sem depender de `whiptail` ou `dialog`.
- 🛡️ **Persistência Pós-Suspensão e Hibernação**: Monitora e reaplica automaticamente os limites caso a BIOS/EC resete os valores ao acordar da suspensão.
- 🔒 **Daemon `systemd` Blindado**: Roda em segundo plano consumindo virtualmente **0% de CPU**, com isolamento de segurança (`ProtectSystem=strict`) e travas de proteção.

---

## 🚀 O Grande Diferencial: Descarga Inteligente na Tomada (Auto-Discharge)

### O Problema do "Congelamento em 100%"
Se você conectar o carregador enquanto o notebook está **desligado**, o controlador embarcado (EC) da placa-mãe ignora o sistema operacional e carrega a bateria até **100%**. Em ferramentas comuns, ao ligar o notebook na tomada, ele entra em modo *AC Bypass* (usando energia direto da fonte) e deixa a bateria **estagnada em 100% sob alta tensão elétrica e estresse térmico** por dias.

### Como o `gerenciador-bateria` Resolve Isso
```text
[Liga na Tomada em 100%] ──► Daemon detecta Carga (100%) > Limite de Parada (80%)
                         ──► Ativa 'force-discharge' no kernel mesmo plugado na tomada
                         ──► Drena a bateria com segurança até o Limite de Início (75%)
                         ──► Restaura modo 'auto' ──► Recarrega até 80% e entra em repouso AC!
```
1. **Detecção**: Ao ligar o notebook na tomada com carga acima do limite de parada (ex: `> 80%`), o serviço ativa temporariamente o modo `force-discharge`.
2. **Drenagem Segura na Tomada**: O notebook consome energia da bateria mesmo conectado à tomada, descendo suavemente até o patamar de início (**75%**).
3. **Carga e Repouso**: Ao atingir **75%**, o sistema restaura o modo `auto`, recarrega até **80%** e passa a alimentar o notebook exclusivamente pela tomada (*AC Bypass*).
4. **Trava de Segurança**: Possui proteção automática que cancela a descarga caso a bateria caia para $\le 20\%$ ou caso o carregador seja desconectado da tomada.

---

## 🖥️ Painel Visual Interativo (Terminal TUI)

Ao executar `sudo gerenciador-bateria` (ou `sudo gerenciador_bateria`) sem argumentos, o painel interativo é aberto instantaneamente:

```text
┌──────────────── Gerenciador de Bateria Universal ────────────────┐
│ Bateria: 79% (Tomada Conectada 🔌) | Lenovo ThinkPad             │
│ Auto-Discharge: [ATIVADO ✅] | Limites: 75% - 80%                │
├──────────────────────────────────────────────────────────────────┤
│ Escolha uma opção (Setas ↑/↓, Números 0-5 ou ESC para sair):     │
│                                                                  │
│    1 📊 Ver Status Detalhado da Bateria                          │
│    2 ⚡ Desativar Descarga Inteligente                           │
│    3 🎯 Alterar Limites de Carga (75% - 80%)                     │
│    4 ⚡ Forçar Descarga Imediata na Tomada                       │
│    5 🔌 Restaurar Padrão de Fábrica (100%)                       │
│    0 🚪 Sair do Programa                                         │
│                                                                  │
├──────────────────────────────────────────────────────────────────┤
│          [ENTER] Selecionar               [ESC / q] Sair         │
└──────────────────────────────────────────────────────────────────┘
```

### ⌨️ Controles pelo Teclado
- **Setas (`↑` / `↓`)** ou **Teclas Vim (`k` / `j`)**: Navega entre as opções do menu.
- **Números (`1` - `5`, `0`)**: Aciona a opção correspondente imediatamente.
- **`ENTER`**: Confirma a opção selecionada.
- **`ESC` ou `q`**: Fecha o programa ou cancela caixas de diálogo **instantaneamente no primeiro toque**.

---

## 🛠️ Matriz de Compatibilidade de Hardware

O script lê `/sys/class/dmi/id/sys_vendor` e seleciona automaticamente o melhor backend disponível no sistema:

| Fabricante | Linhas Compatíveis | Driver do Kernel / Backend | Limite Inicial | Limite Final | Auto-Discharge |
| :--- | :--- | :--- | :---: | :---: | :---: |
| **Lenovo** | ThinkPad, IdeaPad, Yoga | `thinkpad_acpi` (`sysfs`) | ✅ Sim | ✅ Sim | ✅ Sim (`charge_behaviour`) |
| **ASUS** | ROG, ZenBook, TUF, VivoBook | `asus_wmi` (`sysfs`) | ⚙️ Firmware (~75%) | ✅ Sim | ⚙️ Depende do modelo |
| **Dell / Alienware** | XPS, Latitude, Inspiron, Precision | `dell_wmi_sysman` / `libsmbios` / `cctk` | ✅ Sim | ✅ Sim | ⚙️ Depende do modelo |
| **Genérico** | Huawei, Framework, System76, etc. | Interface padrão `power_supply` (`sysfs`) | ✅ Se exposto | ✅ Sim | ⚙️ Se exposto |

---

## 📦 Instalação e Comandos

### 1. Instalação Rápida
Clone o repositório e execute o instalador com `sudo`:

```bash
git clone https://github.com/AlanSchaffer/gerenciador-bateria.git
cd gerenciador-bateria
chmod +x gerenciador-bateria.sh
sudo ./gerenciador-bateria.sh install
```

**O que o instalador faz:**
- Instala o binário em `/usr/local/bin/gerenciador-bateria` e cria um atalho automático em `/usr/local/bin/gerenciador_bateria` (funciona com hífen ou *underline*).
- Cria o arquivo de configuração `/etc/gerenciador-bateria.conf` (padrão: início em `75%`, parada em `80%`, `AUTO_DISCHARGE=true`).
- Remove serviços antigos conflitantes (`thinkpad-battery-charge-limit.service`, etc.).
- Cria, habilita no boot e inicia o serviço `gerenciador-bateria.service` no `systemd`.

### 2. Referência de Comandos Rápidos

| Comando | Descrição |
| :--- | :--- |
| `sudo gerenciador-bateria` | Abre o Menu Visual Interativo (TUI) |
| `sudo gerenciador-bateria on` | Ativa a Descarga Inteligente na tomada |
| `sudo gerenciador-bateria off` | Desativa a Descarga Inteligente (mantém apenas os limites estáticos) |
| `sudo gerenciador-bateria set 75 80` | Define novos limites de Início (`75%`) e Parada (`80%`) |
| `gerenciador-bateria status` | Exibe relatório completo da bateria (Wh/Ah, ciclos, tomada e serviço) |
| `sudo gerenciador-bateria discharge` | Força a descarga imediata na tomada até o limite de início |
| `sudo gerenciador-bateria stop-discharge` | Cancela a descarga forçada e retorna ao modo `auto` |
| `sudo gerenciador-bateria restore` | Restaura os limites para o padrão de fábrica (100%) |
| `gerenciador-bateria check` | Executa diagnóstico completo de compatibilidade do hardware |
| `gerenciador-bateria test` | Executa bateria de 5 testes de integridade do sistema |
| `sudo gerenciador-bateria disable` | Desabilita temporariamente o serviço e restaura 100% |
| `sudo gerenciador-bateria enable` | Reabilita o serviço no `systemd` |
| `sudo gerenciador-bateria remove` | Desinstala completamente o script, configurações e serviço |

---

## 📂 Estrutura de Arquivos no Sistema

| Caminho | Função |
| :--- | :--- |
| `/usr/local/bin/gerenciador-bateria` | Binário principal instalado |
| `/usr/local/bin/gerenciador_bateria` | Link simbólico (alias com *underline*) |
| `/etc/gerenciador-bateria.conf` | Arquivo de configuração persistente |
| `/etc/systemd/system/gerenciador-bateria.service` | Unidade de serviço do `systemd` |

---

## 📄 Why this?

 Criei este projeto justamente para resolver o problema de quem usa Linux no laptop. Minha ideia foi criar, com a ajuda de inteligências artificiais, um projeto que ajudasse a preservar a vida útil da bateria. Acredito que existam outras pessoas enfrentando essa mesma dificuldade e espero poder ajudar. Todos os projetos aqui são open source; sinta-se à vontade para modificar o código como desejar, criar versões melhores, enfim. Também quero deixar meus créditos ao Gemini pela ajuda.

 I created this project specifically to solve a common issue for Linux laptop users. My idea was to build a project, with the assistance of artificial intelligence, to help preserve laptop battery life. I believe others might be facing this same issue, and I hope this helps you out. All projects here are open-source, so feel free to modify the code however you like, build better versions, or adapt it. I’d also like to give credit to Gemini for the assistance.

