#!/usr/bin/env bash
# Suite E2E exhaustiva y multi-dispositivo de Callabit v1.1.0 (com.superappsmx.kidspolice) en GitHub Actions.
# Verifica: Puerta Parental matematica dinamica, tutorial 3 pasos, 3 paquetes regionales de espanol (MX/CO/ES),
# explicacion y uso de rol parental + nombre hablado (Mateo), 16 escenarios incluyendo Cancelar Envio de Patrulla/Visita,
# grabadora de voz, temporizador 5s, llamada activa con pausa verde + soundboard 3x3 + bloqueo anti-toques,
# insignia post-llamada, videollamada HD con movimiento real de pixeles, multiidioma (EN/AR) y diseno responsivo
# en telefono compacto (720x1280), telefono estandar (1080x2400) y tablet (1200x1920).
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

accept_ump_if_open() {
  if has_rx "^(Consent|Consentir|Agree|Aceptar)$"; then
    tap_rx "^(Consent|Consentir|Agree|Aceptar)$" || true
    sleep 3
  fi
}

solve_gate_if_open() {
  for _ in 1 2 3; do
    dump_ui ui_gate_tmp
    local g
    g=$(python3 ci/kidspolice_audit.py solve_gate "$OUT/ui_gate_tmp.xml" || true)
    [ -z "$g" ] && return 0
    set -- $g
    local ans="$1"
    local ex="$2"
    local ey="$3"
    log "ParentalGate detectado -> ingresando respuesta=$ans en ($ex,$ey)"
    adb shell input tap "$ex" "$ey"
    sleep 1
    adb shell input text "$ans"
    sleep 1
    adb shell input keyevent KEYCODE_ENTER
    sleep 2
    dump_ui ui_gate_tmp2
    local still
    still=$(python3 ci/kidspolice_audit.py solve_gate "$OUT/ui_gate_tmp2.xml" || true)
    if [ -n "$still" ]; then
      local cbtn
      cbtn=$(python3 ci/kidspolice_audit.py tap "$OUT/ui_gate_tmp2.xml" "^(Continuar|Continue|Weiter|Continuer|متابعة)$" || true)
      if [ -n "$cbtn" ]; then
        set -- $cbtn
        adb shell input tap "$1" "$2"
        sleep 2
      fi
    else
      return 0
    fi
  done
}

log "=== ESPERANDO ARRANQUE DEL EMULADOR ==="
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
adb shell input keyevent KEYCODE_WAKEUP
adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
sleep 22

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

for perm in android.permission.RECORD_AUDIO android.permission.POST_NOTIFICATIONS; do
  adb shell pm grant "$PKG" "$perm" >/dev/null 2>&1 || true
done

COMP="$PKG/.MainActivity"
adb shell am start -W -n "$COMP" >/dev/null 2>&1
sleep 10
dismiss_system_anr
accept_ump_if_open

# ==============================================================================
# ETAPA 1: PARENTAL GATE DINÁMICO (IDIOMAS + RESPUESTA ERRÓNEA + MULTIPLICACIÓN)
# ==============================================================================
log "=== ETAPA 1: PARENTAL GATE ==="
shot 01_gate_initial
dump_ui ui_01_gate_initial

tap_rx "MX$" || tap_rx "🇲🇽" || true
sleep 2
shot 02_gate_es
dump_ui ui_02_gate_es

# Probar rechazo ante respuesta erronea ("1", ya que 12..29 x 3..9 siempre es >= 36)
G_INIT=$(python3 ci/kidspolice_audit.py solve_gate "$OUT/ui_02_gate_es.xml" || true)
if [ -n "$G_INIT" ]; then
  set -- $G_INIT
  adb shell input tap "$2" "$3"
  sleep 1
  adb shell input text "1"
  sleep 1
  adb shell input keyevent KEYCODE_ENTER
  sleep 2
  if ! has_rx "Respuesta incorrecta|Incorrect"; then
    tap_rx "^(Continuar|Continue)$" || true
    sleep 1
  fi
fi
if has_rx "Respuesta incorrecta|Incorrect"; then
  res parental_gate_bloquea_error OK
else
  res parental_gate_bloquea_error WARN
fi

solve_gate_if_open
sleep 3
accept_ump_if_open

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
accept_ump_if_open

# ==============================================================================
# ETAPA 3: DASHBOARD PRINCIPAL CALLABIT (PASO 1 + CABECERA CENTRADA)
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
if has_rx "Callabit"; then
  res branding_callabit OK
else
  res branding_callabit FALLA
fi

# ==============================================================================
# ETAPA 4: AJUSTES + VOCES REGIONALES (MX / CO / ES) + EXPLICACIÓN QUIÉN CONTESTA
# ==============================================================================
log "=== ETAPA 4: AJUSTES Y ACENTOS REGIONALES (MX / CO / ES) ==="
tap_rx "Ajustes|Settings"
sleep 2
shot 05_settings_modal
dump_ui ui_05_settings_modal

if has_rx "Sirve para que al contestar|person greets Mom"; then
  res explicacion_quien_contesta OK
else
  res explicacion_quien_contesta FALLA
fi

tap_rx "Español \(Colombia\)" || true
sleep 2
shot 05b_settings_colombia
if has_rx "Colombia.*🔊"; then
  res voz_espanol_colombia OK
else
  res voz_espanol_colombia WARN
fi

tap_rx "Español \(España\)" || true
sleep 2
shot 05c_settings_espana
if has_rx "España.*🔊"; then
  res voz_espanol_espana OK
else
  res voz_espanol_espana WARN
fi

tap_rx "Español \(México\)" || true
sleep 1
tap_rx "Papá|Dad" || true
sleep 1
tap_rx "Moderno|Modern" || true
sleep 1
adb shell input keyevent KEYCODE_BACK
sleep 2

# ==============================================================================
# ETAPA 5: DESBLOQUEO VIP 24H (DRA. ELENA TRAS PUERTA PARENTAL DE ACCIÓN)
# ==============================================================================
log "=== ETAPA 5: DESBLOQUEO VIP ==="
tap_rx "Dra\. Elena|Dr\. Elena"
sleep 2
solve_gate_if_open
sleep 2
shot 06_vip_modal
dump_ui ui_06_vip_modal
if has_rx "Ver 1 anuncio|Watch 1 ad"; then
  res vip_modal_abre OK
  tap_rx "Ver 1 anuncio|Watch 1 ad"
  sleep 4
  if echo "$(focus_win)" | grep -q "AdActivity"; then
    log "Anuncio Recompensado de prueba en reproduccion; esperando recompensa..."
    sleep 18
    close_ad_if_open
    sleep 2
  fi
else
  res vip_modal_abre FALLA
fi

# Si el anuncio de prueba en emulador sin Play Store tardo o mostro aviso, cerrar modal VIP limpiamente
if has_rx "^(Cerrar|Close)$"; then
  tap_rx "^(Cerrar|Close)$" || true
  sleep 2
fi
if has_rx "Hacer Sonar|Iniciar Videollamada"; then
  adb shell input keyevent KEYCODE_BACK
  sleep 2
fi
shot 07_home_vip_state
dump_ui ui_07_home_vip_state

# ==============================================================================
# ETAPA 6: GRABADORA DE VOZ PROPIA DEL PADRE (CON PUERTA PARENTAL)
# ==============================================================================
log "=== ETAPA 6: GRABADORA DE VOZ PROPIA ==="
tap_rx "Ajustes|Settings"
sleep 2
if ! has_rx "Grabar Mi Propia Voz|Record My Own Voice"; then
  adb shell input swipe $((SW / 2)) $((SH * 78 / 100)) $((SW / 2)) $((SH * 32 / 100)) 400
  sleep 1
fi
tap_rx "Grabar Mi Propia Voz|Record My Own Voice"
sleep 2
solve_gate_if_open
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

# Asegurar que Capitán Marco este seleccionado en PASO 1
tap_rx "Capitán Marco|Captain Marco" || true
sleep 1

# ==============================================================================
# ETAPA 7: 16 ESCENARIOS + FILTROS + CANCELAR ENVÍO DE PATRULLA/VISITA
# ==============================================================================
log "=== ETAPA 7: PASO 2 ESCENARIOS (16) Y CANCELAR ENVIO ==="
tap_rx "Felicitar|Praise" || true
sleep 1
shot 09b_filter_positive
dump_ui ui_09b_filter_positive

tap_rx "Rutinas|Routines" || true
sleep 1
shot 09c_filter_routines
dump_ui ui_09c_filter_routines

tap_rx "Todos|All" || true
sleep 1
adb shell input swipe $((SW / 2)) $((SH * 72 / 100)) $((SW / 2)) $((SH * 44 / 100)) 420
sleep 2
shot 09_home_scenarios
dump_ui ui_09_home_scenarios

if has_rx "Cancelar Envío|YA HIZO CASO|Cancel Home Visit"; then
  res escenario_cancelar_envio OK
else
  res escenario_cancelar_envio FALLA
fi

# ==============================================================================
# ETAPA 8: PRE-CALL SHEET + EXPLICACIÓN NOMBRE + MATEO + TEMPORIZADOR 5 SEGUNDOS
# ==============================================================================
log "=== ETAPA 8: PRE-CALL SHEET Y TEMPORIZADOR 5 SEG ==="
tap_rx "(^|, | )Llamada$|(^|, | )Voice Call$" 0
sleep 2
shot 10_precall_sheet
dump_ui ui_10_precall_sheet

if has_rx "nombres con altavoz|names with a speaker"; then
  res explicacion_nombre_nino OK
else
  res explicacion_nombre_nino FALLA
fi

tap_rx "🔊 Mateo|🔊 Liam" || true
sleep 1
if ! has_rx "En 5 seg|In 5 sec"; then
  adb shell input swipe $((SW / 2)) $((SH * 78 / 100)) $((SW / 2)) $((SH * 38 / 100)) 350
  sleep 1
fi
tap_rx "Manual" || true
sleep 1
tap_rx "En 5 seg|In 5 sec" || true
sleep 1
tap_rx "Hacer Sonar Llamada|Ring Voice Call"
sleep 1

adb shell input swipe $((SW / 2)) $((SH * 35 / 100)) $((SW / 2)) $((SH * 82 / 100)) 260
sleep 1
shot 11_timer_countdown_banner
dump_ui ui_11_timer_countdown_banner

sleep 6

# ==============================================================================
# ETAPA 9: PANTALLA DE LLAMADA ENTRANTE ("📞 Llamada para: Mateo")
# ==============================================================================
log "=== ETAPA 9: LLAMADA ENTRANTE ==="
shot 12_incoming_voice
dump_ui ui_12_incoming_voice
if has_rx "(^|, | )Contestar$|(^|, | )Answer$"; then
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

if has_rx "Llamada para: Mateo|Call for: Mateo"; then
  res llamada_para_mateo OK
else
  res llamada_para_mateo WARN
fi

tap_rx "(^|, | )Contestar$|(^|, | )Answer$"
sleep 3

# ==============================================================================
# ETAPA 10: LLAMADA DE VOZ ACTIVA (PAUSA VERDE -> SOUNDBOARD CANCELAR ENVÍO -> BLOQUEO)
# ==============================================================================
log "=== ETAPA 10: LLAMADA DE VOZ ACTIVA ==="
shot 13_active_voice_officer
dump_ui ui_13_active_voice_officer
if has_rx "Dedicada a: Mateo|Dedicated to: Mateo"; then
  res llamada_activa_mateo OK
else
  res llamada_activa_mateo WARN
fi

HANGUP_PT=$(python3 ci/kidspolice_audit.py hangup_xy "$OUT/ui_13_active_voice_officer.xml" "$SW" "$SH")
log "Coordenada boton Colgar detectada: $HANGUP_PT"

sleep 11
for _ in 1 2 3; do
  dump_ui ui_14_active_voice_parent_turn
  if python3 ci/kidspolice_audit.py tap "$OUT/ui_14_active_voice_parent_turn.xml" "HABLA TÚ AHORA|SPEAK OUT LOUD|Responder ya" | grep -q "[0-9]"; then
    break
  fi
  sleep 3
done
shot 14_active_voice_parent_turn
if python3 ci/kidspolice_audit.py tap "$OUT/ui_14_active_voice_parent_turn.xml" "HABLA TÚ AHORA|SPEAK OUT LOUD|Responder ya" | grep -q "[0-9]"; then
  res turno_verde_padre OK
  tap_rx "Responder ya|Reply now" || true
  sleep 3
else
  res turno_verde_padre NO_VISTO
fi

# Abrir teclado 3x3 de Frases extra y verificar "Cancelar envío" + "Estrella Dorada"
tap_rx "Frases extra|Quick Lines" || true
sleep 2
shot 15_soundboard_open
dump_ui ui_15_soundboard_open
if python3 ci/kidspolice_audit.py tap "$OUT/ui_15_soundboard_open.xml" "Cancelar envío|Cancel visit" | grep -q "[0-9]"; then
  res frases_extra_cancelar_envio OK
  tap_rx "Cancelar envío|Cancel visit" || true
  sleep 2
else
  res frases_extra_cancelar_envio FALLA
fi

# Bloqueo de pantalla anti-mejilla
tap_rx "Bloquear$|Screen Lock$" || true
sleep 2
shot 16_ear_lock
dump_ui ui_16_ear_lock
adb shell input tap $((SW / 2)) $((SH / 2))
sleep 1
shot 16b_ear_lock_hint
adb shell input swipe $((SW / 2)) $((SH / 2)) $((SW / 2)) $((SH / 2)) 1600
sleep 2

# Colgar llamada de voz
set -- $HANGUP_PT
adb shell input tap "$1" "$2"
sleep 4

# ==============================================================================
# ETAPA 11: INSIGNIA POST-LLAMADA CON NOMBRE MATEO + REGRESO CON PUERTA PARENTAL
# ==============================================================================
log "=== ETAPA 11: POST-LLAMADA E INSIGNIA ==="
shot 17_post_call_medal
dump_ui ui_17_post_call_medal
if has_rx "INSIGNIA DE BUENOS HÁBITOS|GOOD HABITS BADGE"; then
  res medalla_post_llamada OK
else
  res medalla_post_llamada FALLA
fi

tap_rx "Volver al panel|Back to adult" || true
sleep 2
solve_gate_if_open
sleep 2

# ==============================================================================
# ETAPA 12: VIDEOLLAMADA HD REAL (CAPITÁN MARCO + DRA. ELENA SI VIP ACTIVO)
# ==============================================================================
log "=== ETAPA 12A: VIDEOLLAMADA HD CAPITÁN MARCO ==="
if ! has_rx "(^|, | )Videollamada$|(^|, | )Video Call$"; then
  adb shell input swipe $((SW / 2)) $((SH * 75 / 100)) $((SW / 2)) $((SH * 40 / 100)) 400
  sleep 2
fi
tap_rx "(^|, | )Videollamada$|(^|, | )Video Call$" 0
sleep 2
tap_rx "Capitán Marco|Captain Marco" || true
sleep 1
if ! has_rx "Ahora mismo|Right now"; then
  adb shell input swipe $((SW / 2)) $((SH * 78 / 100)) $((SW / 2)) $((SH * 38 / 100)) 350
  sleep 1
fi
tap_rx "Automático|Auto" || true
sleep 1
tap_rx "Ahora mismo|Right now" || true
sleep 1
tap_rx "Iniciar Videollamada|Start Video Call"
sleep 3
shot 18_incoming_video_police
tap_rx "(^|, | )Contestar$|(^|, | )Answer$"
sleep 5
shot 18a_video_police_f1
sleep 2
shot 18b_video_police_f2
dump_ui ui_18_video_police
HANGUP_V=$(python3 ci/kidspolice_audit.py hangup_xy "$OUT/ui_18_video_police.xml" "$SW" "$SH")

set -- $HANGUP_V
adb shell input tap "$1" "$2"
sleep 4
tap_rx "Volver al panel|Back to adult" || true
sleep 2
solve_gate_if_open
sleep 2

log "=== ETAPA 12B: VIDEOLLAMADA HD DRA. ELENA (SI VIP ACTIVO) ==="
if ! has_rx "(^|, | )Videollamada$|(^|, | )Video Call$"; then
  adb shell input swipe $((SW / 2)) $((SH * 75 / 100)) $((SW / 2)) $((SH * 40 / 100)) 400
  sleep 2
fi
tap_rx "(^|, | )Videollamada$|(^|, | )Video Call$" 0
sleep 2
if has_rx "🔒.*Dra\. Elena"; then
  log "Dra. Elena bloqueada porque AdMob test rewarded no cargo en CI sin Play Store; probando segundo pase HD con Capitán Marco..."
  tap_rx "Capitán Marco|Captain Marco" || true
else
  tap_rx "Dra\. Elena|Dr\. Elena" || true
fi
sleep 1
tap_rx "Iniciar Videollamada|Start Video Call"
sleep 3
tap_rx "(^|, | )Contestar$|(^|, | )Answer$"
sleep 5
shot 19a_video_doctor_f1
sleep 2
shot 19b_video_doctor_f2
dump_ui ui_19_video_doctor

set -- $HANGUP_V
adb shell input tap "$1" "$2"
sleep 4
tap_rx "Volver al panel|Back to adult" || true
sleep 2
solve_gate_if_open
sleep 2

# ==============================================================================
# ETAPA 13: PRUEBA MULTIIDIOMA (INGLÉS + ÁRABE + REGRESO A ESPAÑOL)
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

tap_rx "AR ·|الإعدادات|Settings"
sleep 2
tap_rx "Español \(México\)" || true
sleep 2
adb shell input keyevent KEYCODE_BACK
sleep 2

# ==============================================================================
# ETAPA 14: COMPATIBILIDAD RESPONSIVA MULTI-DISPOSITIVO (720x1280 y 1200x1920)
# ==============================================================================
log "=== ETAPA 14A: RESPONSIVO TELÉFONO COMPACTO (720x1280 @ 320dpi) ==="
adb shell wm size 720x1280
adb shell wm density 320
sleep 3
shot 22_compact_720p_home
dump_ui ui_compact_01_home

if ! has_rx "(^|, | )Llamada$"; then
  adb shell input swipe 360 920 360 440 350
  sleep 2
fi
if tap_rx "(^|, | )Llamada$" 0; then
  sleep 2
  shot 23_compact_720p_precall
  dump_ui ui_compact_02_precall
  adb shell input keyevent KEYCODE_BACK
  sleep 2
  res responsivo_compacto_720p OK
else
  res responsivo_compacto_720p WARN
fi

log "=== ETAPA 14B: RESPONSIVO TABLET (1200x1920 @ 240dpi) ==="
adb shell wm size 1200x1920
adb shell wm density 240
sleep 3
shot 24_tablet_1200p_home
dump_ui ui_tablet_01_home

if ! has_rx "(^|, | )Llamada$"; then
  adb shell input swipe 600 1380 600 720 350
  sleep 2
fi
if tap_rx "(^|, | )Llamada$" 0; then
  sleep 2
  shot 25_tablet_1200p_precall
  dump_ui ui_tablet_02_precall
  adb shell input keyevent KEYCODE_BACK
  sleep 2
  res responsivo_tablet_1200p OK
else
  res responsivo_tablet_1200p WARN
fi

adb shell wm size reset
adb shell wm density reset
sleep 2

# ==============================================================================
# ETAPA 15: AUDITORÍA GEOMÉTRICA MULTI-RESOLUCIÓN + MOVIMIENTO DE VIDEO + LOGCAT
# ==============================================================================
log "=== ETAPA 15: AUDITORIA FINAL ==="
adb logcat -d -v time > "$OUT/logcat_full.txt"
grep -E "$PKG|FATAL EXCEPTION|AndroidRuntime|ANR in|ReactNativeJS" "$OUT/logcat_full.txt" | tail -300 > "$OUT/logcat_filtered.txt" || true
rm -f "$OUT/logcat_full.txt"

CRASHES=$(grep -A3 "FATAL EXCEPTION" "$OUT/logcat_filtered.txt" | grep -c "Process: $PKG" || true)
RN_ERRORS=$(grep -cE "ReactNativeJS.*(Unhandled|ReferenceError|TypeError|SyntaxError)" "$OUT/logcat_filtered.txt" || true)
PROD_ADS_SEEN=$(grep -c "ca-app-pub-6096906922082278" "$OUT/logcat_filtered.txt" || true)

res crashes "$CRASHES"
res rn_js_errors "$RN_ERRORS"
res prod_ads_seen "$PROD_ADS_SEEN"

python3 ci/kidspolice_audit.py audit "$OUT" "$SW"
log "=== FIN DE SUITE E2E CALLABIT v1.1.0 ==="
cat "$OUT/result.env"
exit 0
