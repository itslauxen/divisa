# Divisa

Um mouse e um teclado para o Mac e o Windows. Os dois computadores ficam como duas telas lado a lado: leve o cursor até a borda e ele passa para o outro, com teclado e área de transferência junto. Funciona nos dois sentidos — o mouse do Mac controla o Windows e o do Windows controla o Mac.

> Em construção: o monitor virtual para usar um tablet Android como segunda tela do Mac (pelo navegador) vem na próxima etapa.

## Como funciona

- Os dois apps se acham sozinhos na rede local (broadcast UDP na porta 24801) e conversam por TCP na porta 24800. O protocolo está em [PROTOCOLO.md](PROTOCOLO.md).
- Em cada computador você diz **de que lado o outro fica** (no Mac "à esquerda", no Windows "à direita", por exemplo).
- Encostou o cursor na borda daquele lado: ele passa. Voltou para a borda oposta no outro computador: ele volta.
- Mexeu no mouse ou no teclado do computador que estava sendo controlado: ele toma o controle de volta.
- Texto copiado vai junto quando o cursor passa.
- **Atalho de emergência:** `Ctrl+Option+Shift+Esc` no Mac ou `Ctrl+Alt+Shift+Esc` no Windows traz o cursor de volta na hora.

## Mac (`mac/`)

Precisa de macOS 14 ou mais novo e das ferramentas de linha de comando da Apple (`xcode-select --install`).

```bash
cd mac
./build.sh
open Divisa.app
```

Na primeira vez, libere a Divisa em **Ajustes do Sistema › Privacidade e Segurança › Acessibilidade** (para ler e mandar o mouse e o teclado) e aceite o acesso à **rede local**. O app fica na barra de menus.

## Windows (`windows/`)

Precisa do [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
cd windows\Divisa
dotnet run -c Release
```

Para gerar um `.exe` único que roda sem o .NET instalado:

```powershell
dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true
```

Na primeira vez, o Firewall do Windows pergunta se a Divisa pode usar a rede: libere em **redes privadas**. O app fica na bandeja (perto do relógio); clique com o botão direito para os ajustes.

- **Trocar Ctrl e Cmd** (ligado por padrão): `Cmd+C` no teclado do Mac vira `Ctrl+C` no Windows, e `Ctrl+C` no teclado do Windows vira `Cmd+C` no Mac.
- **Conectar por IP**: para redes que bloqueiam o broadcast (algumas redes de convidados e roteadores com "isolamento de clientes").

## Limitações conhecidas

- Jogos com anticheat (como o Vanguard do LoL) podem ignorar a entrada que vem do Mac. Com o mouse físico ligado no Windows, o jogo funciona normalmente.
- No Windows, a tela de login, o UAC e o `Ctrl+Alt+Del` não aceitam entrada simulada.
