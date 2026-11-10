# Divisa

Um mouse e um teclado para o Mac e o Windows (estilo Synergy/Barrier, nos dois
sentidos, com área de transferência), e qualquer tablet como segunda tela do Mac
pelo navegador. Feito para uso próprio do Gabriel; distribuído por GitHub Releases.
Visão do usuário no `README.md`; contrato entre os apps no `PROTOCOLO.md`.

## Stack
- Mac: Swift 5.9 (SwiftPM), AppKit, app de barra de menus, macOS 14+. `Network`, `ScreenCaptureKit`, Carbon (layout de teclado) e API **privada** de tela virtual do CoreGraphics (`CGVirtualDisplay`, via target Obj-C `CGVirtual`).
- Windows: C# .NET 8 WinForms (`net8.0-windows`), app de bandeja, P/Invoke em `Nativo.cs`.
- Tablet: página HTML (`mac/web/index.html`) servida pelo Mac, imagem por WebSocket.

## Estrutura
- `PROTOCOLO.md` — protocolo v1 (estados Local/Mandando/Obedecendo, descoberta UDP, mensagens JSON por linha em TCP). Mudou o protocolo? Atualize os dois lados e o documento.
- `mac/Sources/Divisa/` — `DivisaApp` (UI/menu), `Coordenador` (máquina de estados), `Rede`, `Teclas` (kVK ↔ HID), `Layout`, `Portal` (animação na borda), `Tablet` (tela virtual + captura + toques), `Diario` (log).
- `mac/Sources/CGVirtual/` — cabeçalho/stub da API privada de tela virtual.
- `mac/build.sh`, `Info.plist`, `AppIcon.icns`, `icone/`, `web/`.
- `windows/Divisa/` — `Program` (bandeja/UI), `Coordenador`, `Rede`, `Teclas`, `Nativo`, `Portal`, `Config`.
- `scripts/empacotar.sh` — gera os pacotes da versão em `dist/`.
- `instalar.sh` / `instalar.ps1` — instaladores de um comando (baixam do Release `latest`).

## Comandos
- Mac (dev): `cd mac && ./build.sh && open Divisa.app` (assina com "Apple Development" se houver, senão ad hoc).
- Windows (dev): `cd windows\Divisa && dotnet run -c Release` (compila no Mac graças a `EnableWindowsTargeting`, mas só roda no Windows).
- Pacotes: `scripts/empacotar.sh` (no Mac, com .NET 8 SDK) → `dist/Divisa-mac.zip` (universal arm64+x86_64, ad hoc) e `dist/Divisa-windows.exe` (self-contained, arquivo único).
- Testar instaladores sem mexer no app instalado: `DIVISA_URL`/`DIVISA_DESTINO` (`instalar.sh`), `DIVISA_EXE` (`instalar.ps1`).
- Sem testes automatizados.

## Deploy e onde roda
- Repo `github.com/itslauxen/divisa`. Publicar = rodar `scripts/empacotar.sh` e subir `Divisa-mac.zip` e `Divisa-windows.exe` num GitHub Release (última: `v0.1.0`). Os instaladores apontam para `releases/latest/download/...`, então os nomes dos arquivos não podem mudar. Comando exato de upload (gh release) não está em script (verificar).
- Roda localmente nos dois computadores, mesma rede: TCP 24800 (conexão), UDP 24801 (descoberta por broadcast), HTTP 24802 (página do tablet), WebSocket 24803 (imagem do tablet).

## Convenções
- Tudo em pt-BR: nomes de tipos, arquivos, variáveis, mensagens do protocolo (`entrar`, `sair`, `liberar`, `ola`, `anuncio`) e comentários.
- Commits prefixados pela plataforma: `Mac: …`, `Windows: …`, `Tablet: …`, `Protocolo: …`. Features costumam ser feitas em par (uma no Windows, depois "igual ao do Windows" no Mac).
- `dist/`, `bin/`, `obj/`, `.build/`, `*.app/` não são versionados.

## Armadilhas e decisões
- **Permissões do macOS**: Acessibilidade (mouse/teclado) e Gravação de Tela (tablet). Assinar com identidade fixa no `build.sh` evita que o macOS peça de novo a cada build.
- App do Mac **não notarizado**: o instalador remove a quarentena (`xattr -dr com.apple.quarantine`).
- Firewall do Windows bloqueando entrada: o lado de `id` maior também conecta após 6 s sem conexão.
- **Não gravar teclas no log do Windows**: escrever em disco dentro do gancho atrasava a entrada.
- Mouse suave: no Mac a leitura do mouse roda numa thread própria; no Windows o movimento é agregado a cada 4 ms.
- Layout de teclado: quem obedece troca para o layout do outro lado (campo `teclado` no `ola`/`entrar`) e devolve ao fechar — inclusive na abertura seguinte se fechou no meio.
- Windows restaura os cursores do sistema ao abrir e no instalador (o app troca/esconde o cursor enquanto manda).
- Tablet: tamanho físico fixo (não recriar a tela virtual), uma captura por vez, tela virtual a 30 Hz, qualidade padrão 70% da resolução.
- Tablet, latência: o Mac só manda o próximo quadro depois do `ok` do tablet (sem isso a fila no Wi-Fi somava segundos); cada quadro é só o pedaço que mudou (cabeçalho de 8 bytes: W, H, x, y), então a página não pode descartar quadros; o cursor não vai na imagem: o Mac manda `cursor`/`forma` em texto pelo mesmo WebSocket e a página desenha a seta.
- Lado: cada computador tem o seu ("Windows em cima" no Mac exige "Mac embaixo" no Windows); lados trocados fazem o cursor voltar na hora e parece que o teclado não passa.
- Atalho de emergência: `Ctrl+Option+Shift+Esc` (Mac) / `Ctrl+Alt+Shift+Esc` (Windows).
- Limitações aceitas: anticheat (Vanguard) ignora entrada simulada; tela de login/UAC/`Ctrl+Alt+Del` no Windows; redes com isolamento de clientes.
- Logs: Mac em `~/Library/Logs/Divisa.log`; Windows em `%LOCALAPPDATA%\Divisa\Divisa.log`.
