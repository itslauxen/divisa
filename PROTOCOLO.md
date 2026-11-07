# Protocolo da Divisa (versão 1)

Dois computadores na mesma rede (um Mac e um Windows) dividem um mouse e um teclado como se fossem duas telas lado a lado. **Os dois lados são iguais**: qualquer um pode mandar no outro, usando o mouse e o teclado que estiverem ligados nele. Este documento é o contrato entre o app do Mac (`mac/`) e o do Windows (`windows/`).

## Papéis

Cada app está sempre em um de três estados:

| Estado | O que acontece |
|---|---|
| **Local** | O cursor está nesta máquina. O app só observa o mouse físico. |
| **Mandando** | O cursor "passou" para o outro computador. Este app captura o mouse e o teclado físicos, **engole** os eventos (não chegam aos apps daqui) e manda tudo pela rede. O cursor daqui fica parado e escondido na borda. |
| **Obedecendo** | O outro computador está mandando. Este app recebe as mensagens e reproduz os movimentos, cliques e teclas como se fossem físicos. |

A passagem é sempre combinada: quem está **Local** e bate na borda manda `entrar` e vira **Mandando**; quem recebe vira **Obedecendo**. Quem está Obedecendo devolve com `sair` quando o cursor bate na borda de volta, ou toma o controle de volta com `liberar` quando o mouse físico dele se mexe.

## Configuração de cada lado

Cada app guarda **de que lado da tela o outro computador fica**: `esquerda`, `direita`, `acima` ou `abaixo`. O usuário escolhe nos dois apps, e as escolhas devem ser opostas (no Mac "direita", no Windows "esquerda"). A borda de passagem é a borda desse lado da **área total de todas as telas** do computador.

## Descoberta (UDP 24801)

A cada 2 s, cada app manda por broadcast (`255.255.255.255:24801`) um JSON UTF-8:

```json
{"t":"anuncio","v":1,"id":"7d1e…","nome":"MacBook do Gabriel","so":"mac","porta":24800}
```

- `id`: UUID gerado na primeira execução e guardado. Nunca muda.
- `so`: `"mac"` ou `"windows"`.
- Ignore anúncios com o próprio `id`.
- **Quem conecta**: o app com o `id` **menor** (comparação de texto simples) abre a conexão TCP para o IP de onde veio o anúncio, na `porta` anunciada. O outro só espera. Isso evita duas conexões ao mesmo tempo.
- Cada app aceita um parceiro só. Com uma conexão aberta, anúncios de outros são ignorados.

## Conexão (TCP 24800)

Os dois apps escutam na porta 24800. Cada mensagem é **um JSON numa linha**, em UTF-8, terminado por `\n`. Campos desconhecidos devem ser ignorados.

Logo ao conectar, os dois lados mandam:

```json
{"t":"ola","v":1,"id":"7d1e…","nome":"PC-GABRIEL","so":"windows"}
```

Depois, `{"t":"ping"}` a cada 2 s. Sem receber nada por 6 s, a conexão é dada como morta: feche, e se estava Mandando, volte para Local (mostre o cursor de novo); se estava Obedecendo, volte para Local.

## Mensagens

Posições: `y` (ou `x`) é uma **fração de 0 a 1** ao longo da borda, sobre a área total das telas de quem manda a mensagem.

| Mensagem | Quem manda | Significado |
|---|---|---|
| `{"t":"entrar","y":0.42}` | Local → outro | O cursor bateu na borda. Para os lados `esquerda`/`direita` vem `y`; para `acima`/`abaixo` vem `x`. Quem recebe vira **Obedecendo** e põe o cursor **na borda dele que fica do lado de quem mandou**, na mesma fração. |
| `{"t":"mov","dx":3,"dy":-1}` | Mandando → Obedecendo | Movimento relativo do mouse físico, em pixels de quem manda (inteiros; `dy` positivo é para baixo). Quem obedece soma à posição do cursor e limita à área das telas. |
| `{"t":"botao","b":"esq","d":true}` | Mandando → Obedecendo | Botão `esq`, `dir` ou `meio`; `d` é `true` ao apertar e `false` ao soltar. Quem obedece calcula o clique duplo sozinho (mesmo botão em menos de 0,4 s). Com botão apertado, os `mov` viram arrasto. |
| `{"t":"rolar","dx":0,"dy":1.0}` | Mandando → Obedecendo | Rolagem. `1.0` = um "dente" da roda (no Windows, 120 de `WHEEL_DELTA`). `dy` positivo rola para cima (conteúdo desce), `dx` positivo para a direita. Pode vir fracionário (trackpad). |
| `{"t":"tecla","hid":4,"d":true}` | Mandando → Obedecendo | Tecla física pelo código **HID** (USB HID Usage Tables, página 0x07 "Keyboard/Keypad"). Ex.: `A`=0x04, `Enter`=0x28, `Esc`=0x29, setas 0x4F–0x52, Ctrl esq. 0xE0, Shift esq. 0xE1, Alt/Option esq. 0xE2, Win/Cmd esq. 0xE3, e os direitos 0xE4–0xE7. Modificadores vão como teclas normais (apertar e soltar). |
| `{"t":"sair","y":0.6}` | Obedecendo → Mandando | O cursor de quem obedece bateu na borda do lado de quem manda, empurrando para fora. Quem obedece volta para **Local** (e deixa o cursor ali, escondido atrás da borda é opcional). Quem mandava volta para **Local**, mostra o cursor e o põe na sua borda, 2 px para dentro, na fração recebida. Antes de mandar `sair`, solte (localmente) qualquer tecla ou botão que ainda esteja apertado. |
| `{"t":"liberar"}` | Obedecendo → Mandando | O mouse ou teclado **físico** de quem obedece foi usado. Quem obedece volta para Local na hora; quem mandava volta para Local e mostra o cursor onde ele estava parado. |
| `{"t":"area","texto":"…"}` | Qualquer um | Texto da área de transferência. Mandado por quem vai virar Mandando, **junto** com o `entrar`, se o texto mudou desde o último envio. Quem recebe põe na própria área de transferência. |
| `{"t":"ping"}` | Qualquer um | Mantém a conexão viva. |

## Detalhes que evitam bugs

- **Eventos que o próprio app injetou não podem disparar `liberar`**. No Mac os eventos injetados levam um valor marcado em `eventSourceUserData`; no Windows, use `dwExtraInfo` no `SendInput` e confira no gancho (`LLMHF_INJECTED` também ajuda).
- **Só passa de tela com nenhum botão apertado.** Arrastar uma janela até a borda não deve trocar de computador.
- **Ao virar Mandando**: prenda o cursor onde ele está (no Mac, `CGAssociateMouseAndMouseCursorPosition(false)`; no Windows, `ClipCursor` num retângulo de 1 px) e esconda. O movimento continua chegando como delta.
- **Teclas presas**: ao sair de Mandando ou de Obedecendo por qualquer motivo (inclusive queda da conexão), solte tudo o que estava apertado.
- **Atalho de emergência**: em qualquer lado, `Ctrl+Alt+Shift+Esc` (no Mac, `Ctrl+Option+Shift+Esc`) volta para Local na hora, manda `liberar` e mostra o cursor.

## Tabela HID ↔ teclas

Referência: USB HID Usage Tables, seção 10 (Keyboard/Keypad Page 0x07). No Windows, o jeito mais simples é partir do **scan code** do `KBDLLHOOKSTRUCT` (conjunto 1, com o bit `LLKHF_EXTENDED`) e converter para HID com uma tabela fixa; o caminho inverso usa `SendInput` com `KEYEVENTF_SCANCODE`. A tabela do Mac está em `mac/Sources/Divisa/Teclas.swift` e serve de conferência.
