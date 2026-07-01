---
name: voiceink-dev
description: Use when building, signing, deploying, or debugging the local VoiceInk macOS fork — covers `make local`, the stable code-signing that keeps the Accessibility/hotkey grant alive across rebuilds, deploy to /Applications, and the sleep/wake silent-recording fix. Project-scoped to ~/Developer/sandbox/VoiceInk.
---

# VoiceInk — desenvolvimento, build, assinatura e deploy

App de ditado macOS (fork pessoal). Build local sem conta Apple Developer. Este projeto tem
**duas armadilhas recorrentes** que custaram horas e estão resolvidas abaixo — leia antes de mexer.

## Layout & remotes

- Repo persistente: `~/Developer/sandbox/VoiceInk` (NÃO usar `/tmp` — some no reboot).
- Remotes:
  - `origin` → `https://github.com/Beingpax/VoiceInk.git` (upstream oficial)
  - `fork` → `https://github.com/rdutra7/VoiceInk.git` (fork do usuário, onde salvamos)
- Branches relevantes:
  - `main` — tracking upstream. **Pode conter WIP local não commitado** (ex: feature "Meeting Recorder"). Checar `git status` antes de trocar de branch.
  - `fix/audio-unit-rebuild-on-wake` — fix de gravação 0-frame após sleep/wake (commit `06622c5`), já no `fork`.
- Bundle id: `com.prakashjoshipax.VoiceInk`. App instalado: `/Applications/VoiceInk.app`.

## Build local

```bash
cd ~/Developer/sandbox/VoiceInk
make local        # ad-hoc, sem cert Apple; usa LocalBuild.xcconfig + VoiceInk.local.entitlements + flag LOCAL_BUILD
```
- Saída: `~/Downloads/VoiceInk.app`.
- O Makefile resolve/baixa o `whisper.xcframework` automaticamente (`make whisper`/`setup`) e os SPM packages.
- `make check` valida ferramentas. `make clean` limpa artefatos/deps.
- Build de debug inclui `VoiceInk.debug.dylib` (~64MB) e `__preview.dylib` em `Contents/MacOS/`.

## ⚠️ Armadilha 1 — hotkey global morre a cada rebuild (assinatura)

**Sintoma:** atalho global (ex: "Hybrid + Space") para de funcionar; gravação por **botão** ainda funciona.

**Por quê:** o atalho usa `CGEvent.tapCreate(.cgSessionEventTap, .defaultTap)` em
`VoiceInk/Shortcuts/ShortcutMonitor.swift`, que exige **Accessibility casada com a assinatura do
binário**. `make local` assina **ad-hoc** → CDHash muda a cada rebuild → o grant de Accessibility
(preso ao CDHash antigo) é invalidado **em silêncio**. O toggle no painel continua *aparecendo* ligado,
mas `AXIsProcessTrusted()` retorna false, `tapCreate` devolve `nil`, e o atalho morre sem erro visível.

> NÃO é dependência faltando. O README oficial cita `sindresorhus/KeyboardShortcuts`, mas isso foi
> removido em maio/2026 (commit `d3d55af`) — hoje a impl de atalho é própria. Pista falsa.

**Solução durável:** assinar com um **certificado self-signed estável** (não ad-hoc). Isso pina o
Designated Requirement no leaf cert → estável entre rebuilds → o grant de Accessibility **persiste**.

### Certificado de assinatura

- Identidade: **"VoiceInk Local Signing"**, SHA-1 `4C137AED1EB470B695E4EF4DD460CE4258B8E9FB`, na login keychain.
- Aparece como `CSSMERR_TP_NOT_TRUSTED` em `security find-identity -v` — **isso é OK**: codesign assina
  pela chave privada (não exige trust), e o TCC casa pelo leaf cert. **Assina-se pelo hash.**

**Recriar o cert se sumir** (nova máquina / keychain resetada):
```bash
cat > /tmp/vi-openssl.cnf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = VoiceInk Local Signing
[ v3 ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -keyout /tmp/vi-key.pem -out /tmp/vi-cert.pem \
  -days 3650 -nodes -config /tmp/vi-openssl.cnf
# Importar SEPARADO como PEM (p12 do openssl 3.x falha o MAC no `security` do macOS):
security import /tmp/vi-key.pem  -k ~/Library/Keychains/login.keychain-db
security import /tmp/vi-cert.pem -k ~/Library/Keychains/login.keychain-db
security find-identity -p codesigning   # confere o novo SHA-1; atualizar o hash no script/skill
rm -f /tmp/vi-key.pem /tmp/vi-cert.pem
```

### Assinar (inside-out — `--deep` no bundle inteiro falha em build de debug)

Use o script `scripts/build-sign-deploy.sh` desta skill. Manual, se precisar:
```bash
APP=/Applications/VoiceInk.app
ID=4C137AED1EB470B695E4EF4DD460CE4258B8E9FB
find "$APP" -name '*.cstemp' -delete                                   # limpa temp órfão
codesign -d --entitlements - --xml "$APP" > /tmp/vi-ent.plist          # preserva entitlements
for fw in Sparkle whisper MediaRemoteAdapter; do
  codesign --force --deep --sign "$ID" --timestamp=none "$APP/Contents/Frameworks/$fw.framework"
done
for dy in VoiceInk.debug.dylib __preview.dylib; do
  codesign --force --sign "$ID" --timestamp=none "$APP/Contents/MacOS/$dy"
done
codesign --force --sign "$ID" --entitlements /tmp/vi-ent.plist --timestamp=none "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E 'Authority|flags'                 # Authority=VoiceInk Local Signing, flags 0x0 (sem adhoc)
codesign -d -r- "$APP" | grep designated                               # DR pinado em certificate leaf = H"4c137aed…"
```

### Primeiro deploy com o cert novo (re-grant ÚNICO)

```bash
tccutil reset Accessibility com.prakashjoshipax.VoiceInk
tccutil reset ListenEvent  com.prakashjoshipax.VoiceInk   # Input Monitoring, por garantia
open /Applications/VoiceInk.app
```
Depois: **Ajustes do Sistema → Privacidade e Segurança → Acessibilidade → ligar VoiceInk** (uma vez).
**Reiniciar o app** após o grant (o tap só instala no launch). Testar o atalho.
> Rebuilds futuros assinados com o MESMO cert **não pedem re-grant** — o DR não muda.

## Deploy completo

`make local` joga em `~/Downloads/VoiceInk.app`. Para virar o app de uso:
```bash
cp -R ~/Downloads/VoiceInk.app /Applications/   # (fechar o app antes; sobrescreve)
# depois assinar inside-out (acima) — sempre, senão volta a ad-hoc e o atalho quebra
```
O script `scripts/build-sign-deploy.sh` faz build → copy → sign → verify de uma vez, e **remove
`~/Downloads/VoiceInk.app`** após o deploy. Importante: `make local` SEMPRE gera o app em
`~/Downloads` (ad-hoc); se não remover, vira um **ícone duplicado** no Spotlight/Launchpad e, pior,
se for aberto por engano roda com identidade ad-hoc e re-quebra o grant de Acessibilidade. Regra:
o único VoiceInk que deve existir é `/Applications/VoiceInk.app` (assinado com o cert estável).

## ⚠️ Armadilha 2 — gravações 0-frame após sleep/wake (já corrigida no fork)

Após ~25h de uptime atravessando sleep/wake, o AUHAL do CoreAudio é resetado mas a unit fica em cache
"viva" e muda — gravações saem com 0 frames, sem erro. Fix na branch `fix/audio-unit-rebuild-on-wake`:
`Recorder.swift` ganhou `setupSystemWakeObserver()` (NSWorkspace.didWakeNotification) que força
`teardown()` + `prepare()` no wake. Se rebase/merge com upstream apagar isso, reaplicar.

## Troubleshooting rápido

| Sintoma | Causa provável | Ação |
|---|---|---|
| Atalho global não dispara, botão funciona | assinatura ad-hoc / grant órfão | re-assinar com o cert + re-grant + reiniciar app |
| `codesign --deep` no bundle: `.cstemp No such file or directory` | temp órfão em build debug | `find APP -name '*.cstemp' -delete` e assinar inside-out |
| `find-identity -v` mostra 0 válidas | cert untrusted (esperado) | assinar pelo hash mesmo assim |
| Gravação sai vazia (0 frames) após dias ligado | AUHAL stale pós-wake | já corrigido na branch do fix; conferir `setupSystemWakeObserver` |
| App não abre após assinar | assinou só o bundle, não inside-out | re-assinar frameworks/dylibs primeiro |

## Verificação (sempre antes de declarar "feito")

1. `codesign -dvvv /Applications/VoiceInk.app` → `Authority=VoiceInk Local Signing`, sem `adhoc`.
2. `codesign --verify --verbose=2 /Applications/VoiceInk.app` → `valid on disk` + `satisfies its Designated Requirement`.
3. Atalho global inicia gravação (painel recorder aparece) E gravação salva com frames > 0.
