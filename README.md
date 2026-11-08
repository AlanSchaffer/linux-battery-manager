    > [!NOTE]
    > This program is currently under active development. New features are actively being added, including multi-init daemon support, an integrated
    language switcher, and continuous stability improvements alongside bug fixes.

    # 🔋 Universal Linux Battery Manager (`linux-battery-manager`)

    **Intelligent Charge Threshold & AC Auto-Discharge Manager for Linux Laptops**
    *Gerenciador Inteligente de Limites de Carga e Descarga Automática na Tomada para Notebooks Linux*

    <br />

    🌐 **Select Language / Escolha o Idioma:**
    [🇺🇸 **English Documentation**](#-english-documentation) &nbsp;|&nbsp; [🇧🇷 **Documentação em Português**](#-documentação-em-português)

    ---

    # 🇺🇸 English Documentation

    ## 📖 Overview

    **Universal Linux Battery Manager (`linux-battery-manager`)** is a lightweight, zero-dependency, standalone Bash utility and background daemon designed
    to extend the lifespan of lithium-ion laptop batteries on Linux (**Arch Linux, Ubuntu, Debian, Fedora, openSUSE, Gentoo, Alpine, Void Linux, Artix,
    Devuan**, etc.).

    Unlike standard battery threshold scripts that merely set static `/sys/class/power_supply` limits, this project introduces **Smart AC Auto-Discharge**,
    **Native Multi-Init Support** (`systemd`, `OpenRC`, `Runit`, `dinit`, `SysVinit`), and a **Centered, Zero-Latency Native Terminal UI (TUI)** built
    directly on `/dev/tty` without emojis to guarantee universal compatibility.

    ### ✨ Key Features

    - 🤖 **100% Automatic Hardware Detection**: Natively supports **Lenovo (ThinkPad / IdeaPad / Yoga)**, **ASUS (ROG / ZenBook / TUF / VivoBook)**, **Dell
    / Alienware**, and generic Linux `sysfs` interfaces.
    - 🔌 **Universal AC Power Detection**: Accurately recognizes standard wall chargers (`Mains`, `Brick`), USB-C Power Delivery (`USB_PD`, `USB_C`),
    Thunderbolt docks, and wireless charging pads.
    - ⚡ **Smart AC Auto-Discharge (`force-discharge`)**: Solves the "100% Stagnation Problem" when your laptop is charged while powered off, with
    instantaneous `SIGUSR1` signal handling.
    - ⚙️ **Universal Multi-Init Support**: Automatically detects and configures services for **systemd**, **OpenRC**, **Runit** (Void Linux native),
    **dinit**, and **SysVinit**.
    - 🖥️ **Zero-Latency Centered TUI**: Built in pure Bash with ANSI escape sequences and exact UTF-8 character width calculation—supports Arrow keys
    (`↑`/`↓`), Vim keys (`j`/`k`), numeric shortcuts (`0-6`), and **instant single-press `ESC` exit** with zero external dependencies (`whiptail`/`dialog`
    not required!).
    - 🌐 **Built-in Language Switcher**: Toggle instantly between English and Portuguese directly from the TUI or CLI (`lang en` / `lang pt`), persisted in
    `/etc/linux-battery-manager.conf`.
    - 🛡️ **Sleep / Hibernation Persistence**: Multi-backend hooks (`systemd-sleep`, `elogind`, `pm-utils`) automatically re-apply thresholds after suspend
    or hibernation.
    - 🔒 **Hardened & Reliable Daemon**: Zero orphaned background `sleep` processes, strict PID validation preventing false positives against kernel PID
    recycling, and full support for non-root status queries.

    ---

    ## 🚀 The Killer Feature: Smart AC Auto-Discharge

    ### The "100% Stagnation" Problem
    When you plug in your laptop while it is turned **off**, the motherboard's Embedded Controller (EC) often ignores OS-level limits and charges the
    battery to **100%**. With ordinary threshold tools, when you boot into Linux with the AC adapter plugged in, the laptop switches to *AC Bypass*
    mode—leaving your battery **trapped at 100% charge under high voltage and thermal stress** for days or weeks.

    ### How `linux-battery-manager` Solves It
    ```text
    [Boot on AC at 100%] ──► Daemon detects Capacity (100%) > End Threshold (80%)
    			 ──► Activates kernel 'force-discharge' while plugged in
    			 ──► Safely drains battery on AC power down to Start Threshold (75%)
    			 ──► Restores 'auto' mode ──► Recharges to 80% & enters AC Bypass rest!
  1. Detection: When plugged into AC power with battery charge above your stop limit (e.g., > 80%), the daemon triggers force-discharge.
  2. Safe Drain on AC: The laptop uses battery power even while plugged into the wall until it reaches your start threshold (75%).
  3. Rest & Bypass: Once 75% is reached, it switches back to auto, charges to 80%, and rests peacefully on AC power.
  4. Instant IPC Reaction: Toggling auto-discharge (on/off or stop-discharge) immediately awakens the daemon via SIGUSR1, resetting hardware states without
  polling delays.
  5. Safety Cutoff: Includes a built-in hardware safety lock that aborts forced discharge if battery capacity ever drops ≤ 20% or if AC power is unplugged.
  ──────
  ## 🖥 Interactive Terminal UI (TUI)

  Run linux-battery-manager (or sudo linux_battery_manager) with no arguments or menu to launch the centered interactive panel:

    ┌──────────────── Universal Linux Battery Manager ────────────────┐
    │ Battery: 79% (AC Connected [AC]) | Lenovo ThinkPad              │
    │ Auto-Discharge: [ENABLED [ON]] | Limits: 75% - 80%              │
    ├─────────────────────────────────────────────────────────────────┤
    │ Select an option (Arrows Up/Down, 0-6, or ESC to exit):         │
    │                                                                 │
    │ 	1 [i] View Detailed Battery Status                            │
	│   2 [*] Disable Smart Auto-Discharge                            │
	│   3 [#] Change Charge Limits (75% - 80%)                        │
	│   4 [!] Force Immediate Discharge on AC                         │
	│   5 [~] Restore Factory Defaults (100%)                         │
	│   6 [L] Language / Idioma: [English -> Portugues]               │
	│   0 [X] Exit Program                                            │
	│                                                                 │
    ├─────────────────────────────────────────────────────────────────┤
    │   [ENTER] Select                         [ESC / q] Exit         │
    └─────────────────────────────────────────────────────────────────┘
  ### ⌨ Keyboard Controls
  • Up / Down Arrows (↑ / ↓) or Vim Keys (k / j): Move selection highlight.
  • Numbers (0 - 6): Trigger menu actions directly.
	• ENTER: Confirm selection.
  • ESC or q: Instantaneously exit any screen, popup, or submenu.
  ──────
  ## 🛠 Hardware Compatibility Matrix
  The script inspects /sys/class/dmi/id/sys_vendor and automatically selects the appropriate kernel interface:
   Manufacturer     │ Supported Lineups			 │ Kernel Driver / Backend            │    Start Limit    │ Stop Limit │      Auto-Discharge
  ──────────────────┼────────────────────────────────────┼────────────────────────────────────┼───────────────────┼────────────┼───────────────────────────
   Lenovo           │ ThinkPad, IdeaPad, Yoga            │ thinkpad_acpi (sysfs)              │      ✅ Yes       │   ✅ Yes   │ ✅ Yes (charge_behaviour)
   ASUS             │ ROG, ZenBook, TUF, VivoBook        │ asus_wmi (sysfs)                   │ ⚙ Firmware (~75%) │   ✅ Yes   │     ⚙ Model dependent
   Dell / Alienware │ XPS, Latitude, Inspiron, Precision │ dell_wmi_sysman / libsmbios / cctk │      ✅ Yes       │   ✅ Yes   │     ⚙ Model dependent
   Generic          │ Huawei, Framework, System76, etc.  │ Standard Linux power_supply sysfs  │   ✅ If exposed   │   ✅ Yes   │       ⚙ If exposed
  │ Warning
  │ HP laptops utilize proprietary ACPI methods that are not exposed through standard Linux kernel interfaces and are currently not officially supported.
  ──────
  ## 📦 Installation & Usage
  ### 1. Install (One-Liner)
  Clone the repository and run the installer as root:
    git clone https://github.com/AlanSchaffer/linux-battery-manager.git
    cd linux-battery-manager
    chmod +x linux-battery-manager.sh
    sudo ./linux-battery-manager.sh install
  What the installer does:

  • Detects the running init system (systemd, OpenRC, Runit, dinit, or SysVinit).
  • Copies the binary to /usr/local/bin/linux-battery-manager and creates a convenient alias symlink at /usr/local/bin/linux_battery_manager.
  • Generates the configuration file at /etc/linux-battery-manager.conf (default: 75% start, 80% stop, AUTO_DISCHARGE=true, UI_LANG=pt).
  • Migrates any legacy services and binaries (gerenciador-bateria.service, thinkpad-battery-charge-limit.service, etc.).
  • Installs sleep/resume hooks into /usr/lib/systemd/system-sleep, /lib/elogind/system-sleep, and /etc/pm/sleep.d.
  • Creates, enables, and starts the background service in your native init system.
  ### 2. Quick CLI Commands
   Command                                                  │ Description
  ──────────────────────────────────────────────────────────┼──────────────────────────────────────────────────────────────────────────────────────────────
   linux-battery-manager                                    │ Opens the interactive Terminal UI (TUI)
	linux-battery-manager status                             │ Displays battery health, energy (Wh/Ah), power source, and service status (No sudo required)
   sudo linux-battery-manager on                            │ Enables Smart AC Auto-Discharge
   sudo linux-battery-manager off                           │ Disables Smart AC Auto-Discharge (maintains static charge limits)
   sudo linux-battery-manager set 75 80                     │ Sets custom Start (75%) and Stop (80%) thresholds
   linux-battery-manager lang en                            │ Changes interface language (en or pt)
   sudo linux-battery-manager discharge                     │ Manually triggers immediate discharge on AC down to Start threshold
   sudo linux-battery-manager stop-discharge                │ Cancels manual discharge and returns to auto mode
   sudo linux-battery-manager restore                       │ Restores factory default charging (100%)
   linux-battery-manager check                              │ Runs hardware compatibility diagnostics
   linux-battery-manager test                               │ Runs automated 5-step system integrity checks
   sudo linux-battery-manager enable                        │ Enables and starts the background service in your init system
   sudo linux-battery-manager disable                       │ Disables the service and temporarily resets limits to 100%
   sudo linux-battery-manager stop                          │ Stops the running service/daemon
   sudo linux-battery-manager remove                        │ Completely uninstalls the script, config, hooks, and init service
  ──────
  ## 📂 System File Hierarchy
   Path                                                                       │ Purpose
  ────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────
   /usr/local/bin/linux-battery-manager                                       │ Primary installed executable
   /usr/local/bin/linux_battery_manager                                       │ Symlink alias for fast execution
   /etc/linux-battery-manager.conf                                            │ Persistent configuration file (thresholds, auto-discharge, language)
   /etc/linux-battery-manager/sleep-hook                                      │ Sleep/resume hook script for suspend persistence
   /run/linux-battery-manager.pid                                             │ Process ID tracking file for the background daemon
   /etc/systemd/system/linux-battery-manager.service                          │ systemd service unit (when running under systemd)
	/etc/init.d/linux-battery-manager                                          │ OpenRC / SysVinit service script (when running under OpenRC or SysVinit)
	/etc/sv/linux-battery-manager                                              │ Runit service directory (when running under Runit / Void Linux)
	/etc/dinit.d/linux-battery-manager                                         │ dinit service definition (when running under dinit / Artix)
  ────────────
   🇧🇷 Documentação em Português

  ## 📖 Visão Geral

  O Gerenciador de Bateria Universal (linux-battery-manager) é um utilitário standalone em Bash e daemon em segundo plano, sem dependências externas,
  projetado para maximizar a vida útil de baterias de íons de lítio em notebooks Linux (Arch Linux, Ubuntu, Debian, Fedora, openSUSE, Gentoo, Alpine, Void
  Linux, Artix, Devuan, etc.).
  Diferente de scripts comuns que apenas gravam limites estáticos no /sys/class/power_supply, este projeto traz a Descarga Inteligente na Tomada (Auto-
  Discharge), Suporte Multi-Init Nativo (systemd, OpenRC, Runit, dinit, SysVinit) e uma Engine TUI Nativa Centralizada construída diretamente sobre
  /dev/tty, sem emojis para evitar desformatações no terminal.

  ### ✨ Principais Recursos
  • 🤖 Detecção 100% Automática de Hardware: Compatível nativamente com Lenovo (ThinkPad / IdeaPad / Yoga), ASUS (ROG / ZenBook / TUF / VivoBook), Dell /
  Alienware e interfaces genéricas sysfs do kernel Linux.
  • 🔌 Detecção Ampla de Carregadores (AC Online): Reconhece fontes de tomada convencionais (Mains, Brick), carregadores USB-C Power Delivery (USB_PD,
  USB_C), docks Thunderbolt e bases sem fio.
  • ⚡ Descarga Inteligente na Tomada (force-discharge): Resolve o "Problema do Congelamento em 100%" quando o notebook é carregado desligado, com resposta
  imediata via sinal SIGUSR1.
  • ⚙ Compatibilidade com Múltiplos Inits: Reconhece e configura serviços nativos para systemd, OpenRC, Runit (Void Linux nativo), dinit e SysVinit.
  • 🖥 Interface Visual TUI Nativa Centralizada: Desenvolvida em Bash puro com códigos ANSI e cálculo milimétrico de largura Unicode UTF-8 — suporta Setas
  (↑/↓), teclas estilo Vim (j/k), atalhos numéricos (0-6) e saída instantânea com 1 único toque na tecla ESC, sem depender de whiptail ou dialog.
  • 🌐 Seletor de Idioma Integrado: Alterne instantaneamente entre Português e Inglês pelo menu da TUI ou pelo terminal (lang pt / lang en), salvo em
  /etc/linux-battery-manager.conf.
  • 🛡 Persistência Pós-Suspensão e Hibernação: Hooks automáticos em systemd-sleep, elogind e pm-utils reaplicam os limites imediatamente caso a BIOS/EC
  resete os valores ao acordar.
  • 🔒 Daemon Blindado e Resiliente: Zero processos órfãos (sleep), validação estrita anti-reciclagem de PID via /proc/$PID/cmdline e consulta de status
  segura para usuários sem privilégios de root.
  ──────
  ## 🚀 O Grande Diferencial: Descarga Inteligente na Tomada (Auto-Discharge)
  ### O Problema do "Congelamento em 100%"
  Se você conectar o carregador enquanto o notebook está desligado, o controlador embarcado (EC) da placa-mãe ignora o sistema operacional e carrega a
  bateria até 100%. Em ferramentas comuns, ao ligar o notebook na tomada, ele entra em modo AC Bypass (usando energia direto da fonte) e deixa a bateria
  estagnada em 100% sob alta tensão elétrica e estresse térmico por dias.
  ### Como o linux-battery-manager Resolve Isso
    [Liga na Tomada em 100%] ──► Daemon detecta Carga (100%) > Limite de Parada (80%)
                             ──► Ativa 'force-discharge' no kernel mesmo plugado na tomada
                             ──► Drena a bateria com segurança até o Limite de Início (75%)
                             ──► Restaura modo 'auto' ──► Recarrega até 80% e entra em repouso AC!
  1. Detecção: Ao ligar o notebook na tomada com carga acima do limite de parada (ex: > 80%), o serviço ativa temporariamente o modo force-discharge.
  2. Drenagem Segura na Tomada: O notebook consome energia da bateria mesmo conectado à tomada, descendo suavemente até o patamar de início (75%).
  3. Carga e Repouso: Ao atingir 75%, o sistema restaura o modo auto, recarrega até 80% e passa a alimentar o notebook exclusivamente pela tomada (AC
  Bypass).
  4. Sincronização Imediata (IPC): Ao ligar/desligar a rotina (on/off ou stop-discharge), um sinal SIGUSR1 acorda o daemon na hora e redefine os estados
  sem esperar pelo ciclo do loop.
  5. Trava de Segurança: Possui proteção automática que cancela a descarga caso a bateria caia para ≤ 20% ou caso o carregador seja desconectado da tomada.
  ──────
  ## 🖥 Painel Visual Interativo (Terminal TUI)

  Ao executar linux-battery-manager (ou sudo linux_battery_manager) sem argumentos ou com menu, o painel interativo centralizado é aberto instantaneamente:

    ┌──────────────── Universal Linux Battery Manager ────────────────┐
    │ Bateria: 79% (Tomada Conectada [AC]) | Lenovo ThinkPad         │
    │ Auto-Discharge: [ATIVADO [ON]] | Limites: 75% - 80%             │
    ├─────────────────────────────────────────────────────────────────┤
    │ Escolha uma opcao (Setas Cima/Baixo, 0-6 ou ESC para sair):     │
    │                                                                 │
    │ 	1 [i] Ver Status Detalhado da Bateria                         │
	│ 	2 [*] Desativar Descarga Inteligente                          │
	│ 	3 [#] Alterar Limites de Carga (75% - 80%)                    │
	│   4 [!] Forcar Descarga Imediata na Tomada                      │
	│   5 [~] Restaurar Padrao de Fabrica (100%)                      │
	│   6 [L] Idioma / Language: [Portugues -> English]               │
	│   0 [X] Sair do Programa                                        │
	│                                                                 │
    ├─────────────────────────────────────────────────────────────────┤
  	│   [ENTER] Selecionar                     [ESC / q] Sair         │
  	└─────────────────────────────────────────────────────────────────┘
  ### ⌨ Controles pelo Teclado
  • Setas (↑ / ↓) ou Teclas Vim (k / j): Navega entre as opções do menu.
  • Números (0 - 6): Aciona a opção correspondente imediatamente.
  • ENTER: Confirma a opção selecionada.
  • ESC ou q: Fecha o programa ou cancela caixas de diálogo instantaneamente no primeiro toque.
  ──────
  ## 🛠 Matriz de Compatibilidade de Hardware
  O script lê /sys/class/dmi/id/sys_vendor e seleciona automaticamente o melhor backend disponível no sistema:
   Fabricante       │ Linhas Compatíveis		 │ Driver do Kernel / Backend		 │  Limite Inicial   │ Limite Final │      Auto-Discharge
  ──────────────────┼────────────────────────────────────┼───────────────────────────────────────┼───────────────────┼──────────────┼──────────────────────
   Lenovo           │ ThinkPad, IdeaPad, Yoga            │ thinkpad_acpi (sysfs)                 │      ✅ Sim       │    ✅ Sim    │ ✅ Sim (charge_behavi
   ASUS             │ ROG, ZenBook, TUF, VivoBook        │ asus_wmi (sysfs)                      │ ⚙ Firmware (~75%) │    ✅ Sim    │    ⚙ Depende do model
   Dell / Alienware │ XPS, Latitude, Inspiron, Precision │ dell_wmi_sysman / libsmbios / cctk    │      ✅ Sim       │    ✅ Sim    │    ⚙ Depende do model
   Genérico         │ Huawei, Framework, System76, etc.  │ Interface padrão power_supply (sysfs) │   ✅ Se exposto   │    ✅ Sim    │       ⚙ Se exposto
  │ Warning
  │ Notebooks da marca HP utilizam métodos ACPI proprietários não expostos nas interfaces convencionais do kernel Linux, não sendo oficialmente homologados.
  ──────
  ## 📦 Instalação e Comandos

  ### 1. Instalação Rápida

  Clone o repositório e execute o instalador com sudo:

    git clone https://github.com/AlanSchaffer/linux-battery-manager.git
    cd linux-battery-manager
    chmod +x linux-battery-manager.sh
    sudo ./linux-battery-manager.sh install

  O que o instalador faz:

  • Identifica o sistema de init ativo (systemd, OpenRC, Runit, dinit ou SysVinit).
  • Instala o binário em /usr/local/bin/linux-battery-manager e cria o alias em /usr/local/bin/linux_battery_manager.
  • Cria o arquivo de configuração persistente /etc/linux-battery-manager.conf (padrão: 75% início, 80% parada, AUTO_DISCHARGE=true, UI_LANG=pt).
  • Remove serviços legados conflitantes (gerenciador-bateria.service, thinkpad-battery-charge-limit.service, etc.).
  • Instala os ganchos de suspensão e hibernação em /usr/lib/systemd/system-sleep, /lib/elogind/system-sleep e /etc/pm/sleep.d.
  • Registra, habilita na inicialização e inicia o serviço no init correspondente.

  ### 2. Referência de Comandos Rápidos

   Comando                                                       │ Descrição
  ───────────────────────────────────────────────────────────────┼─────────────────────────────────────────────────────────────────────────────────────────
   linux-battery-manager                                         │ Abre o Menu Visual Interativo (TUI)
   linux-battery-manager status                                  │ Exibe relatório completo da bateria (Wh/Ah, ciclos, tomada e serviço - Não requer sudo)
   sudo linux-battery-manager on                                 │ Ativa a Descarga Inteligente na tomada
   sudo linux-battery-manager off                                │ Desativa a Descarga Inteligente (mantém limites estáticos)
   sudo linux-battery-manager set 75 80                          │ Define novos limites de Início (75%) e Parada (80%)
   linux-battery-manager lang pt                                 │ Altera o idioma da interface (pt ou en)
   sudo linux-battery-manager discharge                          │ Força a descarga imediata na tomada até o limite de início
   sudo linux-battery-manager stop-discharge			 │ Cancela a descarga forçada e retorna ao modo auto
   sudo linux-battery-manager restore                            │ Restaura os limites para o padrão de fábrica (100%)
   linux-battery-manager check                                   │ Executa diagnóstico completo de compatibilidade do hardware
   linux-battery-manager test                                    │ Executa bateria de 5 testes de integridade do sistema
   sudo linux-battery-manager enable                             │ Reabilita e inicia o serviço no sistema de inicialização
   sudo linux-battery-manager disable                            │ Desabilita temporariamente o serviço e restaura 100%
   sudo linux-battery-manager stop                               │ Encerra o serviço/daemon em execução
   sudo linux-battery-manager remove                             │ Desinstala completamente o script, configurações, ganchos e serviço
  ──────
  ## 📂 Estrutura de Arquivos no Sistema

   Caminho                                                                    │ Função
  ────────────────────────────────────────────────────────────────────────────┼────────────────────────────────────────────────────────────────────────────
   /usr/local/bin/linux-battery-manager                                       │ Binário principal instalado
   /usr/local/bin/linux_battery_manager                                       │ Link simbólico (alias com underline)
   /etc/linux-battery-manager.conf                                            │ Arquivo de configuração persistente
   /etc/linux-battery-manager/sleep-hook                                      │ Script hook de recuperação pós-suspensão/hibernação
   /run/linux-battery-manager.pid                                             │ Arquivo contendo o PID do daemon em execução
   /etc/systemd/system/linux-battery-manager.service                          │ Unidade de serviço do systemd (caso use systemd)
   /etc/init.d/linux-battery-manager                                          │ Script de inicialização do OpenRC / SysVinit (caso use OpenRC ou SysVinit)
   /etc/sv/linux-battery-manager                                              │ Diretório de serviço do Runit (caso use Runit / Void Linux)
   /etc/dinit.d/linux-battery-manager  

## 📄 Why this?

 Criei este projeto justamente para resolver o problema de quem usa Linux no laptop. Minha ideia foi criar, com a ajuda de inteligências artificiais, um projeto que ajudasse a preservar a vida útil da bateria. Acredito que existam outras pessoas enfrentando essa mesma dificuldade e espero poder ajudar. Todos os projetos aqui são open source; sinta-se à vontade para modificar o código como desejar, criar versões melhores, enfim. Também quero deixar meus créditos ao Gemini pela ajuda.

 I created this project specifically to solve a common issue for Linux laptop users. My idea was to build a project, with the assistance of artificial intelligence, to help preserve laptop battery life. I believe others might be facing this same issue, and I hope this helps you out. All projects here are open-source, so feel free to modify the code however you like, build better versions, or adapt it. I’d also like to give credit to Gemini for the assistance.

