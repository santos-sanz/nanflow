# AGENTS.md — Nanflow

Clon de Wispr Flow para macOS con **transcripción vía API de Nan** (whisper cloud) y formateo LLM. Nada de transcripción local: la captura de audio es local, el audio viaja solo a la API de Nan.

## Comandos

```bash
swift build -c release                 # compilar todo
swift test                             # unit tests (51 tests)
./scripts/build-icon.sh                # regenera scripts/AppIcon.icns + docs/logo.*
./scripts/build-app.sh release         # genera build/Nanflow.app (firmado con "Nanflow Dev")
open build/Nanflow.app                 # lanzar la app (menú bar)
.build/release/nanflow-cli env         # config Nan cargada
.build/release/nanflow-cli test-llm    # ping al LLM
.build/release/nanflow-cli pipeline /tmp/nf-test-es.wav   # transcribe+formatea
.build/release/nanflow-cli pipeline /tmp/x.wav --no-fast   # fuerza LLM (comparativa)
.build/release/nanflow-cli pipeline /tmp/x.wav --no-vad    # simula subida de silencio
.build/release/nanflow-cli record-test --secs 3           # micro real → pipeline
.build/release/nanflow-cli tap-test                       # audio del sistema → whisper
.build/release/nanflow-cli meeting-test --secs 8          # motor de reuniones
.build/release/nanflow-cli detect                          # estado de detección
```

## Arquitectura

- **NanflowCore** (librería, testable sin GUI):
  - `Config/AppConfig.swift` — `Provider` (nan/openrouter) + `.env` (NAN_*, OPENROUTER_*, LLM_OPENROUTER_MODEL, STT_OPENROUTER_MODEL). Búsqueda: env vars → ~/.nanflow/.env → ~/Library/Application Support/Nanflow/.env → CWD/.env → bundle Resources/.env
  - `Config/ProviderSettings.swift` — **resolución de proveedor activo**: key (Keychain > .env), modelos por proveedor (UserDefaults > env > default), `client()` para los motores
  - `Config/KeychainStore.swift` — SecItem genérico para API keys metidas por UI (nunca en texto plano) + `masked()` para UI
  - `Config/NFLog.swift` — log en `~/Library/Application Support/Nanflow/nanflow.log`
  - `LLM/NanClient.swift` — whisper (`/v1/audio/transcriptions`, multipart, **también in-memory con `transcribe(samples:)`**) + chat (`/v1/chat/completions`, con `chat_template_kwargs: {enable_thinking: false}` para latencia <2s) + `prewarm()` (calienta DNS+TLS; comparte **una sola URLSession** para que la conexión se reutilice de verdad)
  - `LLM/Formatter.swift` — **TextStyle** (off/natural/informal/formal) con prompts por estilo + diccionario personalizado; `.off` no debe llamar al LLM (lo salta el motor)
  - `Text/VoiceCommands.swift` — comandos de dictado ("nueva línea"→\n, "punto y aparte"→\n\n) + limpieza de puntuación colgante
  - `Export/MeetingExporter.swift` — Markdown al portapapeles + PDF via NSPrintOperation (jobDisposition .save)
  - `Audio/MicRecorder.swift` — AVAudioEngine → 16k mono (converter por buffer)
  - `Audio/WavEncoder.swift` — WAV PCM16 en memoria (sin disco en el hot path de dictado)
  - `Audio/SystemAudioRecorder.swift` — **Core Audio Process Tap** (macOS 14.2+, SIN permiso de pantalla): tap global excluyendo nuestro proceso → aggregate device → IOProc @48k
  - `Audio/AudioMixer.swift` — resample (drena con `.endOfStream`) + mezcla con offset + `trimSilence` (recorta silencios cabecera/cola, ~15% menos upload)
  - `HotKey/HotKeyMonitor.swift` — CGEventTap en **hilo dedicado** (no en el run loop de NSApp), maneja `flagsChanged` con code=0 (eventos sintéticos) y con keycode real (teclado físico), suprime la tecla, reactiva el tap si el sistema lo deshabilita, **Esc cancela** y `stop()` cierra el run loop (sin hilos huérfanos)
  - `Dictation/DictationEngine.swift` — máquina de estados idle→recording→transcribing→formatting (usa `transition(from:to:)`, NUNCA lock anidado → deadlock); respeta `style`, `trimSilenceEnabled` y `fastShortUtterances`; VAD evita subir silencio; si el LLM falla pega la transcripción cruda; cancelación por generación
  - `Meeting/MeetingDetector.swift` — poll 2s: bundle IDs de apps nativas + pestañas meet.google.com en Chrome/Edge/Brave (AppleScript best-effort)
  - `Meeting/MeetingEngine.swift` — graba sistema+micro mezclados → WAV en AppSupport/meetings → whisper → resumen LLM → history; el estado sigue en `.processing` hasta que acaba la transcripción; se puede iniciar manualmente desde el menú
  - `TextInsert/TextInserter.swift` — clipboard backup → Cmd+V sintético → restaura clipboard
  - `History/HistoryStore.swift` — JSON en AppSupport, **iso8601 en lectura Y escritura**, instancia **`HistoryStore.shared`** para que UI y motores no se pisen
- **nanflow** (app menú-bar):
  - `AppDelegate.swift` — status item, menú (Ajustes…, Estilo, Atajo, Historial, permisos), wiring de motores
  - `SettingsStore.swift` — ObservableObject con @Published persistidos en UserDefaults, aplica cambios en vivo a los motores
  - `SettingsView.swift` — frontend SwiftUI: panel de control (estilo, atajo, reuniones, permisos, historial reciente con copiar)
  - `SettingsWindowController.swift` — NSWindow + NSHostingView
  - `BubblePanel.swift` — NSPanel no activable cerca del cursor
- **nanflow-cli**: harness de testing (sin GUI)

## Gotchas aprendidos (no repetir)

1. **TCC + firma**: la app se firma con el certificado estable "Nanflow Dev" (en el login keychain). Si se firmara ad-hoc, cada rebuild rompería Accesibilidad.
2. **Event tap**: si vives en el run loop principal de NSApplication, se silencia cuando el run loop cambia de modo (burbuja, mic). Por eso el hilo dedicado.
3. **Modificadores y eventos sintéticos**: osascript/System Events emiten `flagsChanged` con keycode=0; un teclado físico emite keycode=54. El monitor cubre ambos.
4. **AVAudioConverter**: una sola llamada a `convert` retiene ~15% del audio; hay que drenar con `.endOfStream`.
5. **NSLock no es reentrante**: no llamar `setState()` (que lockea) desde una sección que ya lockea.
6. **whisper de Nan**: el campo `language` de la respuesta miente (dice "en" para español); hay heurística `looksSpanish` en NanClient.
7. **qwen3.8-flash** (default NAN_MODEL) formatea bien y rápido; `glm5.3-flash` es reasoning y tarda 8s+.
8. **OpenRouter**: los modelos whisper NO aparecen en `/models` pero `/audio/transcriptions` funciona igual (multipart OpenAI). Los LLM del catálogo con `input_modalities` audio se excluyen (no sirven para chat de texto). Para desactivar thinking: `"reasoning": {"exclude": true, "enabled": false}` (el `chat_template_kwargs` de Nan NO funciona ahí).
9. **Historial**: usa `HistoryStore.shared`. Varias instancias con el mismo JSON se pisan al escribir (cada una tiene su copia en memoria).
10. **Prewarm**: crear un `NanClient` nuevo por petición hacía que el HEAD de prewarm no compartiera conexión. Ahora `ProviderSettings` cachea el cliente y `NanClient` comparte URLSession.
11. **Dictado corto**: Natural con ≤3 palabras y sin diccionario/comandos omite el LLM (~1.3s vs ~2.0s). `.off` no debe añadir puntuación.

## Testing E2E sin manos

```bash
say -v Monica -o /tmp/test.aiff "texto de prueba"   # genera audio
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/test.aiff /tmp/test.wav
# hotkey sintético (requiere que la app esté corriendo con Accesibilidad):
osascript -e 'tell application "System Events" to key down 54'   # hold
afplay /tmp/test.wav                                             # el micro captura los altavoces
osascript -e 'tell application "System Events" to key up 54'     # release
tail ~/Library/Application\ Support/Nanflow/nanflow.log          # verificar pipeline
```

Estado de la app: `~/Library/Application Support/Nanflow/` (history.json, meetings/, nanflow.log). Debug del tap: `defaults write com.nanflow.nanflow nanflow.debug.taplog -bool true`.
