# Nanflow

**Dictado por voz estilo Wispr Flow para macOS — pulsar y hablar, texto perfecto en cualquier app.**

Nanflow captura tu voz con un atajo global, la transcribe con el whisper de la API de Nan y la pule con un LLM (puntuación, tildes, sin muletillas) antes de pegarla donde estés escribiendo. También detecta reuniones (Zoom, Teams, FaceTime, Webex, Meet en el navegador), las graba, las transcribe y genera un resumen.

## Features

- 🎙️ **Dictado hold-to-talk** — mantén ⌘ derecho (configurable: ⌥ der, Fn, F5), habla, suelta. El texto aparece en la app activa.
- 🇪🇸🇬🇧 **Español e inglés** — detección automática de idioma por dictado.
- ✨ **Formateo con IA** — puntuación, capitalización, acentos y limpieza de muletillas vía LLM (se puede desactivar).
- 🔵 **Reuniones automáticas** — detecta cuando entras a una reunión, graba el audio del sistema + tu micro, transcribe al terminar y genera resumen con puntos clave, decisiones y acciones.
- 🔒 **Privacidad** — el audio solo viaja a la API de Nan (whisper + LLM). Nada se queda en servidores de terceros; transcripciones e historial viven en local.
- 📜 **Historial local** — últimos dictados y reuniones accesibles desde el menú de la barra.

## Instalación

```bash
./scripts/build-app.sh release
open build/Nanflow.app
```

En el primer arranque, concede:

1. **Accesibilidad** — para el atajo global y pegar texto (Ajustes > Privacidad y seguridad > Accesibilidad).
2. **Micrófono** — para capturar tu voz (se pide solo).
3. **Notificaciones** — para avisos de reuniones (opcional).

## Configuración

`.env` (junto a la app, en `~/.nanflow/.env` o `~/Library/Application Support/Nanflow/.env`):

```
NAN_API_KEY=sk-...
NAN_BASE_URL=https://api.nan.builders/v1
NAN_MODEL=qwen3.8-flash
NAN_WHISPER_MODEL=whisper
```

## CLI de desarrollo

```bash
swift build -c release
.build/release/nanflow-cli env            # verificar config
.build/release/nanflow-cli test-llm       # ping al LLM
.build/release/nanflow-cli transcribe /tmp/audio.wav
.build/release/nanflow-cli pipeline /tmp/audio.wav   # transcribe + formatea
.build/release/nanflow-cli record-test --secs 3      # micro → pipeline completo
.build/release/nanflow-cli tap-test                  # audio del sistema → whisper
.build/release/nanflow-cli meeting-test --secs 8     # motor de reuniones
```

## Requisitos

- macOS 14.2+ (Process Tap de Core Audio)
- Apple Silicon o Intel
- API key de Nan (compatible OpenAI)

## Testing

```bash
swift test    # 16 unit tests
```

E2E sin manos (ver AGENTS.md): genera audio con `say`, dispara el hotkey sintético con `osascript` y verifica el pipeline en el log.

## Arquitectura

Swift nativo (SwiftPM, sin dependencias externas):

- **NanflowCore** — captura (AVAudioEngine + Core Audio Process Tap), cliente Nan (whisper + chat), formateo LLM, detección de reuniones, hotkey (CGEventTap), inserción de texto, historial.
- **nanflow** — app menú-bar (AppKit, burbuja flotante no activable).
- **nanflow-cli** — harness de pruebas.

Hecho como clon educativo de Wispr Flow; el análisis de la app original se hizo con ingeniería inversa del bundle Electron (app.asar).
