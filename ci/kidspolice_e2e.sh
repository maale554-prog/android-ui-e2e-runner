#!/usr/bin/env bash
# Suite E2E exhaustiva de Kids Police (com.superappsmx.kidspolice) en Emulador Android de GitHub Actions.
# Prueba TODAS las pantallas, modales, idiomas, grabadora, temporizador, llamada de voz, frases extra,
# candado anti-toques, videollamada HD con movimiento real de video y medalla post-llamada,
# auditando geometricamente el centrado horizontal en los volcados XML de uiautomator.
set -u

APK="${1:-apk/kidspolice-test.apk}"
PKG="com.superappsmx.kidspolice"
OUT="results/$PKG"
mkdir -p "$OUT"
: > "$OUT/result.env"

log() { echo "[$(date +%T)] $*" | tee -a "$OUT/log.txt"; }
res() { echo "$1=$2" | tee -a "$OUT/result.env"; }

dump_ui() {
  local name="$1"
  rm -f /tmp/ui_pull.xml
  adb shell uiautomator dump --compressed /sdcard/ui.xml >/dev/null 2>&1 || adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
  adb pull /sdcard/ui.xml "$OUT/${name}.xml" >/dev/null 2>&1 || true
}

shot() {
  local name="$1"
  adb exec-out screencap -p > "$OUT/${name}.png"
  log "captura guardada: ${name}.png"
}

focus_win() {
  adb shell dumpsys window | grep mCurrentFocus | head -1 | tr -d '\r'
}

dismiss_system_anr() {
  for _ in 1 2 3; do
    dump_ui ui_anr
    local p
    p=$(python3 ci/kidspolice_audit.py tap "$OUT/ui_anr.xml" "^(Wait|Esperar|OK|Allow|Permitir)$" || true)
    [ -z "$p" ] && return 0
    set -- $p
    log "descarta dialogo del sistema: $p"
    adb shell input tap "$1" "$2"
    sleep 2
  done
}

close_ad_if_open() {
  for _ in 1 2 3 4; do
    local f
    f=$(focus_win)
    case "$f" in
      *AdActivity*)
        log "AdActivity detectada ($f), esperando cierre limpio..."
        sleep 5
        dump_ui ui_ad
        local p
        p=$(python3 ci/kidspolice_audit.py tap "$OUT/ui_ad.xml" "^(Close|Cerrar|Close Ad|Dismiss|Skip|No thanks|✕|X)$" || true)
        if [ -n "$p" ]; then
          set -- $p
          adb shell input tap "$1" "$2"
        else
          adb shell input keyevent KEYCODE_BACK
          sleep 2
          adb shell input tap $((SW - 70)) 95
        fi
        sleep 3
        ;;
      *)
        return 0
        ;;
    esac
  done
}

tap_rx() {
  local rx="$1"
  local nth="${2:-0}"
  dump_ui ui_t
  local p
  p=$(python3 ci/kidspolice_audit.py tap_nth "$OUT/ui_t.xml" "$rx" "$nth" || true)
  if [ -n "$p" ]; then
    set -- $p
    log "TAP [$rx#$nth] -> ($1, $2) $3"
    adb shell input tap "$1" "$2"
    return 0
  fi
  log "WARN: no se encontro nodo para regex [$rx#$nth]"
  return 1
}

has_rx() {
  local rx="$1"
  dump_ui ui_h
  local p
  p=$(python3 ci/kidspolice_audit.py tap "$OUT/ui_h.xml" "$rx" || true)
  [ -n "$p" ]
}

log "=== ESPERANDO ARRANQUE DEL EMULADOR ==="
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
sleep 25

SIZE_RAW=$(adb shell wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)
SW=${SIZE_RAW%x*}
SH=${SIZE_RAW#*x}
SW=${SW:-1080}
SH=${SH:-2400}
log "Resolucion detectada del emulador: ${SW}x${SH}"
dismiss_system_anr

log "=== INSTALANDO APK CON PERMISOS CONCEDIDOS (-g) ==="
adb logcat -c
INST=$(adb install -r -g "$APK" 2>&1 | tr '\n' ' ')
log "Instalacion: $INST"
if ! echo "$INST" | grep -q "Success"; then
  res instalacion FALLA
  exit 1
fi
res instalacion OK

for perm in android.permission.CAMERA android.permission.RECORD_AUDIO android.permission.POST_NOTIFICATIONS; do
  adb shell pm grant "$PKG" "$perm" >/dev/null 2>&1 || true
done

COMP="$PKG/.MainActivity"
adb shell am start -W -n "$COMP" >/dev/null 2>&1
sleep 10
dismiss_system_anr

# Si aparece formulario UMP GDPR de prueba, aceptarlo
if has_rx "Consent|Consentir|Agree|Aceptar"; then
  tap_rx "Consent|Consentir|Agree|Aceptar" || true
  sleep 3
fi

# ==============================================================================
# ETAPA 1: PARENTAL GATE (IDIOMAS + RESPUESTA INCORRECTA + DESBLOQUEO 12+7=19)
# ==============================================================================
log "=== ETAPA 1: PARENTAL GATE ==="
shot 01_gate_initial
dump_ui ui_01_gate_initial

# Cambiar a Espanol tocando chip ES
tap_rx "ES$" || tap_rx "🇲🇽" || true
sleep 2
shot 02_gate_es
dump_ui ui_02_gate_es

# Probar bloqueo ante respuesta erronea (15)
tap_rx "(^| )15$" || true
sleep 1
tap_rx "Soy Padre|Adult" || true
sleep 1
if has_rx "12 \+ 7 = 19"; then
  res parental_gate_bloquea_error OK
else
  res parental_gate_bloquea_error WARN
fi

# Seleccionar 19 y entrar
tap_rx "(^| )19$"
sleep 1
tap_rx "Soy Padre|Adult"
sleep 3

# ==============================================================================
# ETAPA 2: MODAL AUTO-EXPLICATIVO ¿CÓMO FUNCIONA? (3 PASOS)
# ==============================================================================
log "=== ETAPA 2: MODAL COMO FUNCIONA ==="
shot 03_how_it_works
dump_ui ui_03_how_it_works
if has_rx "Cómo funciona|How It Works"; then
  res modal_como_funciona OK
  tap_rx "Entendido|Got it" || true
  sleep 2
else
  res modal_como_funciona NO_VISTO
fi

# ==============================================================================
# ETAPA 3: DASHBOARD PRINCIPAL (PASO 1 + CABECERA CENTRADA)
# ==============================================================================
log "=== ETAPA 3: DASHBOARD PRINCIPAL ==="
close_ad_if_open
shot 04_home_top
dump_ui ui_04_home_top
if has_rx "PASO 1|STEP 1"; then
  res home_paso1 OK
else
  res home_paso1 FALLA
fi

# ==============================================================================
# ETAPA 4: MODAL DE AJUSTES (ROLES + SKINS)
# ==============================================================================
log "=== ETAPA 4: AJUSTES ==="
tap_rx "Ajustes|Settings"
sleep 2
shot 05_settings_modal
dump_ui ui_05_settings_modal
tap_rx "Papá$|Dad$" || true
sleep 1
tap_rx "Google Pixel" || true
sleep 1
# Cerrar Ajustes (boton X arriba a la derecha del sheet o BACK)
adb shell input keyevent KEYCODE_BACK
sleep 2

# ==============================================================================
# ETAPA 5: DESBLOQUEO VIP 24H (DRA. ELENA Y COMANDANTE BRUNO)
# ==============================================================================
log "=== ETAPA 5: DESBLOQUEO VIP ==="
tap_rx "Dra\. Elena|Dr\. Elena"
sleep 2
shot 06_vip_modal
dump_ui ui_06_vip_modal
if has_rx "Ver 1 Video|Watch 1 Video"; then
  res vip_modal_abre OK
  tap_rx "Ver 1 Video|Watch 1 Video"
  sleep 4
  # Si se abrio AdActivity de prueba de Google Rewarded, esperar recompensa (~15s) y cerrar
  if echo "$(focus_win)" | grep -q "AdActivity"; then
    log "Anuncio Recompensado de prueba en reproduccion; esperando recompensa..."
    sleep 18
    close_ad_if_open
    sleep 2
  fi
else
  res vip_modal_abre FALLA
fi

shot 07_home_vip_unlocked
dump_ui ui_07_home_vip_unlocked
# Si se abrio PreCallSheet o se selecciono Dra. Elena sin candado, VIP quedo activo
if has_rx "Preparar|Automático|Dra\. Elena"; then
  res vip_desbloqueo OK
else
  res vip_desbloqueo WARN
fi
# Si hubiese quedado PreCallSheet abierta, cerrarla
if has_rx "Hacer Sonar|Iniciar Videollamada"; then
  adb shell input keyevent KEYCODE_BACK
  sleep 2
fi

# ==============================================================================
# ETAPA 6: GRABADORA DE VOZ PROPIA DEL PADRE
# ==============================================================================
log "=== ETAPA 6: GRABADORA DE VOZ PROPIA ==="
tap_rx "Ajustes|Settings"
sleep 2
# Deslizar un poco dentro de Ajustes si hace falta para ver Grabar Mi Propia Voz
if ! has_rx "Grabar Mi Propia Voz|Record My Own Voice"; then
  adb shell input swipe $((SW / 2)) $((SH * 75 / 100)) $((SW / 2)) $((SH * 35 / 100)) 400
  sleep 1
fi
tap_rx "Grabar Mi Propia Voz|Record My Own Voice"
sleep 2
shot 08a_recorder_modal
dump_ui ui_08a_recorder_modal
tap_rx "Grabar Audio|Start Recording" || true
sleep 3
tap_rx "Detener Grabación|Stop Recording" || true
sleep 2
shot 08b_recorder_saved
dump_ui ui_08b_recorder_saved
if has_rx "Audio personalizado listo|Escuchar Muestra|Custom recording ready"; then
  res grabadora_audio OK
else
  res grabadora_audio WARN
fi
adb shell input keyevent KEYCODE_BACK
sleep 2

# Volver a seleccionar Oficial Marco arriba en PASO 1
tap_rx "Oficial Marco|Officer Marcus" || true
sleep 1

# ==============================================================================
# ETAPA 7: ESCENARIOS PASO 2 Y FILTROS
# ==============================================================================
log "=== ETAPA 7: PASO 2 ESCENARIOS Y FILTROS ==="
tap_rx "Felicitar|Praise" || true
sleep 1
shot 09b_filter_positive
tap_rx "Corregir|Guide" || true
sleep 1
tap_rx "Todos|All" || true
sleep 1
adb shell input swipe $((SW / 2)) $((SH * 70 / 100)) $((SW / 2)) $((SH * 45 / 100)) 450
sleep 2
shot 09_home_scenarios
dump_ui ui_09_home_scenarios

# ==============================================================================
# ETAPA 8: PRE-CALL SHEET + TEMPORIZADOR 5 SEGUNDOS + DISPARO AUTOMÁTICO
# ==============================================================================
log "=== ETAPA 8: PRE-CALL SHEET Y TEMPORIZADOR 5 SEG ==="
tap_rx "(^|, | )Llamada$|(^|, | )Voice Call$" 0
sleep 2
shot 10_precall_sheet
dump_ui ui_10_precall_sheet

# Elegir modo Manual (A mi ritmo), nombre Mateo y temporizador En 5 seg
tap_rx "Manual" || true
sleep 1
if ! has_rx "(^|, | )Mateo$"; then
  adb shell input swipe $((SW / 2)) $((SH * 78 / 100)) $((SW / 2)) $((SH * 40 / 100)) 350
  sleep 1
fi
tap_rx "(^|, | )Mateo$" || true
sleep 1
tap_rx "En 5 seg|In 5 sec" || true
sleep 1
tap_rx "Hacer Sonar Llamada|Ring Voice Call"
sleep 2

# Volver arriba del scroll para ver el banner amarillo de cuenta regresiva
adb shell input swipe $((SW / 2)) $((SH * 35 / 100)) $((SW / 2)) $((SH * 80 / 100)) 300
sleep 1
shot 11_timer_countdown_banner
dump_ui ui_11_timer_countdown_banner

# Esperar a que termine la cuenta regresiva de 5s y salte sola a IncomingCallScreen
sleep 5

# ==============================================================================
# ETAPA 9: PANTALLA DE LLAMADA ENTRANTE
# ==============================================================================
log "=== ETAPA 9: LLAMADA ENTRANTE ==="
shot 12_incoming_voice
dump_ui ui_12_incoming_voice
if has_rx "Contestar|Answer"; then
  res llamada_entrante_temporizada OK
else
  log "Abriendo llamada directa de respaldo..."
  res llamada_entrante_temporizada FALLBACK
  tap_rx "(^|, | )Llamada$|(^|, | )Voice Call$" 0 || true
  sleep 2
  tap_rx "Ahora mismo|Right now" || true
  tap_rx "Hacer Sonar Llamada|Ring Voice Call" || true
  sleep 2
  shot 12_incoming_voice
  dump_ui ui_12_incoming_voice
fi

tap_rx "Contestar|Answer"
sleep 3

# ==============================================================================
# ETAPA 10: LLAMADA DE VOZ ACTIVA (VOZ HUMANA -> PAUSA VERDE -> FRASES EXTRA -> BLOQUEO)
# ==============================================================================
log "=== ETAPA 10: LLAMADA DE VOZ ACTIVA ==="
shot 13_active_voice_officer
dump_ui ui_13_active_voice_officer
HANGUP_PT=$(python3 ci/kidspolice_audit.py hangup_xy "$OUT/ui_13_active_voice_officer.xml" "$SW" "$SH")
log "Coordenada boton Colgar detectada: $HANGUP_PT"

# Esperar fin del saludo inicial (~11s) para verificar turno verde HABLA TU AHORA (en modo Manual espera sin prisa)
sleep 11
for _ in 1 2 3; do
  dump_ui ui_14_active_voice_parent_turn
  if python3 ci/kidspolice_audit.py tap "$OUT/ui_14_active_voice_parent_turn.xml" "HABLA TÚ AHORA|SPEAK OUT LOUD|Responder ahora" | grep -q "[0-9]"; then
    break
  fi
  sleep 3
done
shot 14_active_voice_parent_turn
if python3 ci/kidspolice_audit.py tap "$OUT/ui_14_active_voice_parent_turn.xml" "HABLA TÚ AHORA|SPEAK OUT LOUD|Responder ahora" | grep -q "[0-9]"; then
  res turno_verde_padre OK
  tap_rx "Responder ahora|Next Response" || true
  sleep 2
else
  res turno_verde_padre NO_VISTO
fi

# Abrir teclado de Frases extra
tap_rx "Frases extra|Quick Lines" || true
sleep 2
shot 15_soundboard_open
dump_ui ui_15_soundboard_open
if python3 ci/kidspolice_audit.py tap "$OUT/ui_15_soundboard_open.xml" "Estrella de Oro|Gold Star|Te escucho" | grep -q "[0-9]"; then
  res frases_extra OK
  tap_rx "Estrella de Oro|Gold Star" || true
  sleep 2
else
  res frases_extra FALLA
fi

# Probar Bloqueo de pantalla anti-mejilla
tap_rx "Bloquear$|Screen Lock$" || true
sleep 2
shot 16_ear_lock
dump_ui ui_16_ear_lock
# Toque corto para activar aviso dorado y pulsacion larga de 1.5s para desbloquear
adb shell input tap $((SW / 2)) $((SH / 2))
sleep 1
shot 16b_ear_lock_hint
adb shell input swipe $((SW / 2)) $((SH / 2)) $((SW / 2)) $((SH / 2)) 1600
sleep 2

# Colgar llamada de voz
set -- $HANGUP_PT
adb shell input tap "$1" "$2"
sleep 4
close_ad_if_open
sleep 2

# ==============================================================================
# ETAPA 11: MEDALLA POST-LLAMADA (CERTIFICADO CON NOMBRE MATEO)
# ==============================================================================
log "=== ETAPA 11: POST-LLAMADA Y MEDALLA ==="
shot 17_post_call_medal
dump_ui ui_17_post_call_medal
if has_rx "MEDALLA OFICIAL|SUPER KID"; then
  res medalla_post_llamada OK
else
  res medalla_post_llamada FALLA
fi

tap_rx "Volver al Inicio|Back to Home" || true
sleep 3
close_ad_if_open

# ==============================================================================
# ETAPA 12: VIDEOLLAMADA HD REAL (OFICIAL MARCO + DRA. ELENA CON PRUEBA DE MOVIMIENTO)
# ==============================================================================
log "=== ETAPA 12A: VIDEOLLAMADA HD OFICIAL MARCO ==="
if ! has_rx "(^|, | )Videollamada$|(^|, | )Video Call$"; then
  adb shell input swipe $((SW / 2)) $((SH * 75 / 100)) $((SW / 2)) $((SH * 40 / 100)) 400
  sleep 2
fi
tap_rx "(^|, | )Videollamada$|(^|, | )Video Call$" 0
sleep 2
tap_rx "Oficial Marco|Officer Marcus" || true
sleep 1
tap_rx "Automático|Auto" || true
sleep 1
tap_rx "Ahora mismo|Right now" || true
sleep 1
tap_rx "Iniciar Videollamada|Start Real HD Video"
sleep 3
shot 18_incoming_video_police
tap_rx "Contestar|Answer"
sleep 5
shot 18a_video_police_f1
sleep 2
shot 18b_video_police_f2
dump_ui ui_18_video_police

# Colgar videollamada Oficial Marco
set -- $HANGUP_PT
adb shell input tap "$1" "$2"
sleep 4
close_ad_if_open
tap_rx "Volver al Inicio|Back to Home" || true
sleep 3
close_ad_if_open

log "=== ETAPA 12B: VIDEOLLAMADA HD DRA. ELENA ==="
if ! has_rx "(^|, | )Videollamada$|(^|, | )Video Call$"; then
  adb shell input swipe $((SW / 2)) $((SH * 75 / 100)) $((SW / 2)) $((SH * 40 / 100)) 400
  sleep 2
fi
tap_rx "(^|, | )Videollamada$|(^|, | )Video Call$" 0
sleep 2
tap_rx "Dra\. Elena|Dr\. Elena" || true
sleep 1
tap_rx "Iniciar Videollamada|Start Real HD Video"
sleep 3
tap_rx "Contestar|Answer"
sleep 5
shot 19a_video_doctor_f1
sleep 2
shot 19b_video_doctor_f2
dump_ui ui_19_video_doctor

set -- $HANGUP_PT
adb shell input tap "$1" "$2"
sleep 4
close_ad_if_open
tap_rx "Volver al Inicio|Back to Home" || true
sleep 3
close_ad_if_open

# ==============================================================================
# ETAPA 13: PRUEBA MULTIIDIOMA (INGLÉS + ÁRABE)
# ==============================================================================
log "=== ETAPA 13: PRUEBA MULTIIDIOMA EN Y AR ==="
adb shell input swipe $((SW / 2)) $((SH * 28 / 100)) $((SW / 2)) $((SH * 88 / 100)) 350
sleep 1
adb shell input swipe $((SW / 2)) $((SH * 28 / 100)) $((SW / 2)) $((SH * 88 / 100)) 350
sleep 2
tap_rx "Ajustes|Settings"
sleep 2
tap_rx "English" || true
sleep 2
adb shell input keyevent KEYCODE_BACK
sleep 2
shot 20_home_english
dump_ui ui_20_home_english

tap_rx "Settings|Ajustes"
sleep 2
tap_rx "العربية" || true
sleep 2
adb shell input keyevent KEYCODE_BACK
sleep 2
shot 21_home_arabic
dump_ui ui_21_home_arabic

# ==============================================================================
# ETAPA 14: AUDITORÍA GEOMÉTRICA XML + MOVIMIENTO DE VIDEO + LOGCAT
# ==============================================================================
log "=== ETAPA 14: AUDITORIA FINAL ==="
adb logcat -d -v time > "$OUT/logcat_full.txt"
grep -E "$PKG|FATAL EXCEPTION|AndroidRuntime|ANR in|ReactNativeJS" "$OUT/logcat_full.txt" | tail -250 > "$OUT/logcat_filtered.txt" || true
rm -f "$OUT/logcat_full.txt"

CRASHES=$(grep -A3 "FATAL EXCEPTION" "$OUT/logcat_filtered.txt" | grep -c "Process: $PKG" || true)
RN_ERRORS=$(grep -cE "ReactNativeJS.*(Unhandled|ReferenceError|TypeError|SyntaxError)" "$OUT/logcat_filtered.txt" || true)
PROD_ADS_SEEN=$(grep -c "ca-app-pub-6096906922082278" "$OUT/logcat_filtered.txt" || true)

res crashes "$CRASHES"
res rn_js_errors "$RN_ERRORS"
res prod_ads_seen "$PROD_ADS_SEEN"

python3 ci/kidspolice_audit.py audit "$OUT" "$SW"
log "=== FIN DE SUITE E2E ==="
cat "$OUT/result.env"
exit 0
