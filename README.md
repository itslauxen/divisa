# Divisa

Um mouse e um teclado para o Mac e o Windows, e o tablet como segunda tela do Mac.

- **Mouse e teclado divididos:** os dois computadores ficam como duas telas lado a lado. Leve o cursor até a borda e ele passa para o outro, com o teclado e o texto copiado junto. Funciona nos dois sentidos: o mouse do Mac controla o Windows e o do Windows controla o Mac.
- **Tablet como segunda tela do Mac:** o Mac cria uma tela virtual do tamanho do tablet e a mostra no navegador dele. Funciona com qualquer tablet (Android ou iPad) na mesma rede, sem instalar nada no tablet.

## Instalar

**No Mac** (macOS 14 ou mais novo), no Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/itslauxen/divisa/main/instalar.sh | bash
```

**No Windows** (10 ou 11, 64 bits), no PowerShell:

```powershell
irm https://raw.githubusercontent.com/itslauxen/divisa/main/instalar.ps1 | iex
```

Os mesmos comandos atualizam para a versão mais nova. Os arquivos também estão na página de [versões](https://github.com/itslauxen/divisa/releases/latest).

### Primeiro uso

1. **Mac:** a Divisa fica na barra de menus (ícone de dois retângulos). Libere em **Ajustes do Sistema › Privacidade e Segurança**:
   - **Acessibilidade**, para dividir o mouse e o teclado;
   - **Gravação de Tela**, só se for usar o tablet.
2. **Windows:** a Divisa fica na bandeja, perto do relógio. Se o Firewall perguntar, libere em **redes privadas**.
3. Com os dois na mesma rede, eles se acham sozinhos em alguns segundos. Diga em cada um **de que lado o outro fica**: no Mac, pela janelinha da barra de menus; no Windows, com o botão direito no ícone › "O outro computador fica". As escolhas são opostas (ex.: no Mac "À esquerda", no Windows "À direita").
4. Não se acharam? Use **Conectar por IP** em um dos dois, com o IP do outro.

### Tablet como segunda tela

1. Na janelinha da Divisa no Mac, ligue **Tela no tablet**.
2. No tablet, aponte a câmera para o QR code que aparece ou abra o endereço mostrado (algo como `http://192.168.1.10:24802`) no navegador.
3. Toque em **Começar**. O Mac ganha uma tela nova do tamanho do tablet; arrume a posição dela em Ajustes do Sistema › Telas.

No tablet: tocar é clicar, arrastar é arrastar, dois dedos rolam e segurar o dedo é o clique direito. Para a tela do tablet não apagar, aumente o tempo de tela nos ajustes dele.

## Como funciona

- Os dois apps se acham por broadcast UDP (porta 24801) e conversam por TCP (porta 24800). O protocolo está em [PROTOCOLO.md](PROTOCOLO.md).
- Encostou o cursor na borda do lado escolhido: ele passa. Voltou para a borda oposta no outro computador: ele volta.
- Mexeu no mouse ou no teclado do computador que estava sendo controlado: ele toma o controle de volta.
- **Atalho de emergência:** `Ctrl+Option+Shift+Esc` no Mac ou `Ctrl+Alt+Shift+Esc` no Windows traz o cursor de volta na hora.
- **Trocar Ctrl e Cmd** (no Windows, ligado por padrão): `Cmd+C` no teclado do Mac vira `Ctrl+C` no Windows, e `Ctrl+C` no teclado do Windows vira `Cmd+C` no Mac.
- O tablet recebe a imagem por WebSocket (porta 24803) numa página servida pelo Mac (porta 24802). A tela virtual usa a mesma API interna do macOS que apps como o BetterDisplay.

## Limitações conhecidas

- O app do Mac não é notarizado pela Apple. O instalador tira a marca de quarentena para ele abrir; se baixar o `.zip` pelo navegador, abra com o botão direito › Abrir.
- Jogos com anticheat (como o Vanguard do LoL) podem ignorar a entrada que vem do Mac. Com o mouse físico ligado no Windows, o jogo funciona normalmente.
- No Windows, a tela de login, o UAC e o `Ctrl+Alt+Del` não aceitam entrada simulada.
- Redes de convidados e roteadores com "isolamento de clientes" impedem os computadores de se verem.

## Compilar

- **Mac:** `cd mac && ./build.sh && open Divisa.app` (precisa das ferramentas de linha de comando da Apple: `xcode-select --install`).
- **Windows:** `cd windows\Divisa && dotnet run -c Release` (precisa do [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)).
- **Pacotes da versão:** `scripts/empacotar.sh` (no Mac, com o .NET 8 SDK) gera `dist/Divisa-mac.zip` e `dist/Divisa-windows.exe`.
