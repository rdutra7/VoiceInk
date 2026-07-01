#!/usr/bin/env bash
# VoiceInk: build local -> deploy em /Applications -> assina com cert estável -> verifica.
# Mantém o atalho global vivo (evita ad-hoc que invalida o grant de Accessibility a cada rebuild).
#
# Uso:
#   ./build-sign-deploy.sh            # build + deploy + sign + verify
#   ./build-sign-deploy.sh --no-build # pula 'make local', só re-assina o /Applications atual
#   ./build-sign-deploy.sh --regrant  # ao final, reseta TCC p/ forçar re-grant (1ª vez / cert novo)
#
# Pré-requisito: cert "VoiceInk Local Signing" na login keychain (ver SKILL.md p/ recriar).
set -euo pipefail

REPO="$HOME/Developer/sandbox/VoiceInk"
APP="/Applications/VoiceInk.app"
BUILT="$HOME/Downloads/VoiceInk.app"
BUNDLE_ID="com.prakashjoshipax.VoiceInk"
CERT_NAME="VoiceInk Local Signing"

DO_BUILD=1; DO_REGRANT=0
for a in "$@"; do
  case "$a" in
    --no-build) DO_BUILD=0 ;;
    --regrant)  DO_REGRANT=1 ;;
    *) echo "flag desconhecida: $a" >&2; exit 2 ;;
  esac
done

# Resolve a identidade pelo nome (pega o SHA-1 mesmo untrusted/CSSMERR_TP_NOT_TRUSTED).
ID="$(security find-identity -p codesigning 2>/dev/null | awk -v n="$CERT_NAME" '$0 ~ n {print $2; exit}')"
if [ -z "${ID:-}" ]; then
  echo "ERRO: identidade '$CERT_NAME' não encontrada na keychain. Ver SKILL.md (seção 'Recriar o cert')." >&2
  exit 1
fi
echo "==> Identidade: $ID ($CERT_NAME)"

if [ "$DO_BUILD" = 1 ]; then
  echo "==> make local"
  ( cd "$REPO" && make local )
fi

echo "==> Fechar VoiceInk"
osascript -e 'quit app "VoiceInk"' 2>/dev/null || true; sleep 2
pkill -f "$APP/Contents/MacOS/VoiceInk" 2>/dev/null || true; sleep 1

if [ "$DO_BUILD" = 1 ]; then
  [ -d "$BUILT" ] || { echo "ERRO: build não encontrado em $BUILT" >&2; exit 1; }
  echo "==> Deploy: $BUILT -> $APP"
  rm -rf "$APP"; cp -R "$BUILT" "$APP"
  echo "==> Remover artefato de ~/Downloads (evita ícone duplicado no Spotlight/Launchpad)"
  rm -rf "$BUILT"
fi

[ -d "$APP" ] || { echo "ERRO: $APP não existe (rode sem --no-build)" >&2; exit 1; }

echo "==> Limpar .cstemp órfãos"
find "$APP" -name '*.cstemp' -delete 2>/dev/null || true

echo "==> Preservar entitlements"
codesign -d --entitlements - --xml "$APP" 2>/dev/null > /tmp/vi-ent.plist || true

echo "==> Assinar inside-out"
for fw in Sparkle whisper MediaRemoteAdapter; do
  [ -d "$APP/Contents/Frameworks/$fw.framework" ] && \
    codesign --force --deep --sign "$ID" --timestamp=none "$APP/Contents/Frameworks/$fw.framework"
done
for dy in VoiceInk.debug.dylib __preview.dylib; do
  [ -f "$APP/Contents/MacOS/$dy" ] && \
    codesign --force --sign "$ID" --timestamp=none "$APP/Contents/MacOS/$dy"
done
ENT_ARG=(); [ -s /tmp/vi-ent.plist ] && ENT_ARG=(--entitlements /tmp/vi-ent.plist)
codesign --force --sign "$ID" "${ENT_ARG[@]}" --timestamp=none "$APP"

echo "==> Verificar"
codesign -dvvv "$APP" 2>&1 | grep -E 'Authority=|flags=' || true
codesign --verify --verbose=2 "$APP" 2>&1 | tail -2 || true
codesign -d -r- "$APP" 2>&1 | grep -i designated || true

if [ "$DO_REGRANT" = 1 ]; then
  echo "==> Reset TCC (re-grant necessário)"
  tccutil reset Accessibility "$BUNDLE_ID" || true
  tccutil reset ListenEvent  "$BUNDLE_ID" || true
  echo "    -> Ligue VoiceInk em Ajustes > Privacidade > Acessibilidade, depois reinicie o app."
fi

echo "==> Abrir VoiceInk"
open "$APP"
echo "OK. Teste o atalho global. Se nada disparar e foi 1º deploy do cert, rode com --regrant."
