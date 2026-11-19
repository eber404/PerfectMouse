# PerfectMouse

> Dois consertos de mouse num app só, na barra de menus do macOS. Sem driver, sem kernel extension, sem reiniciar.

[![macOS](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](#requisitos)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](#compilar)
[![Licença](https://img.shields.io/badge/licen%C3%A7a-MIT-3DA639)](#licença)
[![Sem telemetria](https://img.shields.io/badge/telemetria-nenhuma-4B5563)](#privacidade)

---

## O que ele faz

| | Recurso | Para quem |
|---|---|---|
| 🖱️ | **Rolagem natural independente** — mouse e trackpad com direções diferentes | Quem usa mouse de roda e trackpad no mesmo Mac |
| ⌨️ | **Correção do Ctrl travado** — impede o clique esquerdo de virar clique direito | Donos de Attack Shark X6 (e outros mouses com o mesmo defeito) |

Os dois recursos são opcionais e ligáveis no menu do ícone.

---

## O problema do Ctrl travado

O **Attack Shark X6** (receptor Beken `0x1D57:0xFA60`) expõe, além do mouse, uma **interface de teclado HID**. Um defeito de firmware faz essa interface "latchar" **Ctrl** (às vezes Ctrl + AltGr) como se estivesse pressionado — mesmo sem você tocar no teclado.

No macOS, `Ctrl + clique` **é** clique direito. Resultado:

- clique esquerdo abre menu de contexto;
- arrastar vira seleção em vez de mover;
- scroll com Ctrl dá zoom sem querer;
- desligar e ligar o mouse "resolve" (porque o HID é reiniciado), até acontecer de novo.

Não é mapa de botões invertido, não é o receptor, não é configuração do macOS. É o modificador.

### Como o PerfectMouse resolve

Ele abre um **event tap** de sessão e fica vigiando o estado real dos modificadores. Se o Ctrl ficar preso por **mais de 2,5 s sem nenhuma tecla ser tocada**:

1. considera que é latch de firmware;
2. remove `Ctrl` dos cliques e do scroll;
3. injeta um `key-up` de Ctrl para limpar o estado no sistema.

Ctrl de verdade (o seu dedo) nunca é afetado, porque qualquer tecla zera o contador.

**Workaround manual, sem o app:** aperte e solte Ctrl duas vezes.

---

## Instalação

### Requisitos

- macOS 13 (Ventura) ou superior
- Xcode Command Line Tools — `xcode-select --install`

### Instalar

```bash
git clone git@github.com:eber404/PerfectMouse.git
cd PerfectMouse
./install.sh
```

O script compila, instala em `~/Applications/PerfectMouse.app`, registra o início automático no login e abre o app.

### Autorizar

Na primeira execução o macOS pede permissão. Se não aparecer o pedido:

1. abra o ícone do PerfectMouse na barra de menus;
2. clique em **Abrir Ajustes**;
3. ligue o **PerfectMouse** em **Privacidade e Segurança → Acessibilidade**.

O ícone muda para ✓ quando o event tap está ativo.

---

## Usando

Clique no ícone da barra de menus:

```
┌─────────────────────────────────────┐
│ PerfectMouse              ● Ativo    │
│                                     │
│ ROLAGEM                             │
│   Mouse          Rolagem natural  ◯ │
│   Trackpad       Rolagem natural  ● │
│                                     │
│ ─────────────────────────────────── │
│ CORREÇÃO DO CTRL TRAVADO            │
│   Ativo          Correções: 3     ● │
│                                     │
│ Abrir log                     Sair  │
└─────────────────────────────────────┘
```

| Controle | Efeito |
|---|---|
| **Mouse → Rolagem natural** | Inverte só a roda do mouse |
| **Trackpad → Rolagem natural** | Inverte só o trackpad |
| **Correção do Ctrl travado → Ativo** | Liga/desliga o limpador de latch |
| **Correções** | Quantas vezes o Ctrl falso já foi limpo |
| **Abrir log** | Abre `~/Library/Logs/PerfectMouse.log` |

A rolagem é calculada em relação à opção global **Rolagem natural** do macOS. Se o sistema está natural e você quer o mouse clássico, o app inverte só o mouse — e vice-versa.

---

## Verificando se funcionou

Depois que o bug acontecer, veja o log:

```bash
tail -5 ~/Library/Logs/PerfectMouse.log
```

```
2026-11-19 18:02:11.044 CTRL LATCH DETECTED after 2.6s — cleaning
2026-11-19 18:02:11.449 latch cleared
```

Se o clique voltar ao normal **sem** essas linhas, a causa não é o Ctrl — abra uma issue com o log.

---

## Compilar sem instalar

```bash
./build.sh          # gera PerfectMouse.app na pasta
open PerfectMouse.app
```

O app é **assinado ad-hoc**. Cada build novo muda a assinatura e o macOS pede a permissão de Acessibilidade de novo.

---

## Desinstalar

```bash
./uninstall.sh
```

Remove o app, o início automático e as preferências. Para revogar a permissão de Acessibilidade:

```bash
tccutil reset Accessibility com.eber.perfectmouse
```

---

## Como funciona por dentro

Um único `CGEventTap` em `.cgSessionEventTap` escuta:

- `scrollWheel` → inverte os eixos quando a direção desejada difere da do sistema. O app distingue mouse de trackpad por `scrollWheelEventIsContinuous` (`0` = roda, `1` = trackpad).
- `flagsChanged`, `keyDown`, `keyUp` → alimentam o detector de latch.
- `leftMouseDown/Up`, `rightMouseDown/Up`, `otherMouse*`, `drag` → têm o flag `Ctrl` removido quando o latch está ativo.

Um timer de 0,5 s compara o que o tap viu com `CGEventSource.flagsState(.combinedSessionState)` — o estado real do HID. Isso pega o latch mesmo quando nenhum evento de teclado chega.

> ⚠️ O app precisa de Acessibilidade porque eventos sintéticos e taps de sessão exigem essa autorização. Nada sai da máquina.

---

## Privacidade

Sem rede, sem analytics, sem conta, sem coleta. Só um arquivo de log local, que você pode apagar quando quiser.

---

## Limitações conhecidas

- O bug é de firmware. O PerfectMouse **contorna** o Ctrl preso; não conserta o mouse. Não existe firmware público para o X6 (o pacote oficial traz apenas o app de configuração `.exe`).
- O Attack Shark HUB (`controlhub.top`) não funciona no Chrome do macOS: o WebHID bloqueia dispositivos que expõem coleções de teclado/mouse.
- Requer macOS 13+. Em versões anteriores o `NSImage(systemSymbolName:)` usado nos ícones pode não existir.

---

## Licença

MIT — veja [LICENSE](LICENSE).
