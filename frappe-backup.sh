#!/usr/bin/env bash
# =====================================================================
#  iZONE ENTERPRISE - BACKUPS
#  Gestor de respaldos para Frappe / ERPNext
#  Destinos soportados: Unidad de Red (CIFS o rclone) y Google Drive (rclone)
#  Version: 2.5.0
#
#  Un respaldo que no se puede restaurar no es un respaldo. Desde la 2.4.0
#  cada ejecucion comprueba que el volcado se pueda abrir y este completo
#  ANTES de copiarlo, ANTES de borrar el original y ANTES de aplicar la
#  retencion. Si la verificacion falla no se borra ni se elimina nada.
#
#  Desde la 2.5.0 la Unidad de Red tiene dos caminos. El primero monta el
#  recurso por CIFS. Cuando el servidor no puede montar (un contenedor
#  LXC sin privilegios, por ejemplo) el gestor lo detecta y usa el
#  segundo: rclone habla SMB directo con el NAS, sin montar nada. En ese
#  camino cada respaldo se relee desde el NAS byte a byte y solo recibe
#  su nombre definitivo despues de esa comprobacion.
#
#  Uso:  sudo ./izone-backup-manager.sh
# =====================================================================
set -uo pipefail

APP_DIR="/etc/izone-backup"
BIN_DIR="/usr/local/bin"
LOG_DIR="/var/log/izone-backup"
CRON_TAG="izone-backup"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
BASE="${HOST_SHORT}-backup"
RCLONE_ESPERA=150
NAV_ON=0          # 1 dentro de los asistentes: habilita v=volver, x=cancelar
# Version del codigo que se escribe en los scripts. Si cambia, al abrir el
# gestor se regeneran los scripts de TODOS los trabajos. La 2.5.0 no toca
# los scripts de CIFS ni de Drive, por eso sigue en 2.4.0: los trabajos
# que ya estan en produccion no se reescriben.
GEN_VERSION_ACTUAL="2.4.0"
# Copia de rclone propia del gestor, solo para la red sin montaje. Se usa
# cuando el rclone del sistema no trae SMB; nunca reemplaza al del sistema.
RCLONE_PRIV="/usr/local/lib/izone-backup/rclone"
TRABAJO_BASE="/var/tmp/izone-backup"   # carpeta local de trabajo por defecto

C_R=$'\033[0m'; C_B=$'\033[1m'; C_DIM=$'\033[2m'
C_CY=$'\033[0;36m'; C_GR=$'\033[0;32m'; C_RD=$'\033[0;31m'; C_YL=$'\033[0;33m'

say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "  ${C_GR}[OK]${C_R}    $*"; }
err()  { printf '%b\n' "  ${C_RD}[ERROR]${C_R} $*"; }
warn() { printf '%b\n' "  ${C_YL}[AVISO]${C_R} $*"; }
info() { printf '%b\n' "  ${C_CY}[INFO]${C_R}  $*"; }
hr()   { printf '%b\n' "${C_DIM}  ---------------------------------------------------------------${C_R}"; }

banner_izone() {
  say "
${C_CY}${C_B}  ██╗${C_R}███████╗ ██████╗ ███╗   ██╗███████╗
${C_CY}${C_B}  ██║${C_R}╚══███╔╝██╔═══██╗████╗  ██║██╔════╝
${C_CY}${C_B}  ██║${C_R}  ███╔╝ ██║   ██║██╔██╗ ██║█████╗
${C_CY}${C_B}  ██║${C_R} ███╔╝  ██║   ██║██║╚██╗██║██╔══╝
${C_CY}${C_B}  ██║${C_R}███████╗╚██████╔╝██║ ╚████║███████╗
${C_CY}${C_B}  ╚═╝${C_R}╚══════╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝
${C_B}       E N T E R P R I S E  -  B A C K U P S${C_R}
"
  return 0
}

pantalla() {
  clear
  banner_izone
  hr
  printf '%b\n' "  ${C_B}$1${C_R}"
  printf '%b\n' "  ${C_DIM}servidor: ${HOST_SHORT}${C_R}"
  hr
  echo
}

enter() { echo; read -rsp "  Presione ENTER para continuar..." _ || true; echo; }
fin_entrada() { echo; err "Entrada terminada. Saliendo del gestor."; exit 1; }

# --------------------------- Entradas --------------------------------
pedir() {
  local __var="$1" __txt="$2" __def="${3-}" __in=""
  while true; do
    if [ -n "$__def" ]; then
      read -rp "  ${__txt} [${__def}]: " __in || fin_entrada
      __in="${__in:-$__def}"
    else
      read -rp "  ${__txt}: " __in || fin_entrada
    fi
    __in="$(printf '%s' "$__in" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    _nav_check "$__in"; local __n=$?
    [ "$__n" -ne 0 ] && return "$__n"
    [ -n "$__in" ] && break
    err "Este dato es obligatorio."
  done
  printf -v "$__var" '%s' "$__in"
  return 0
}

pedir_secreto() {
  local __var="$1" __txt="$2" __a="" __b=""
  while true; do
    read -rsp "  ${__txt}: " __a || fin_entrada; echo
    if [ "${NAV_ON:-0}" = "1" ] && { [ "${__a,,}" = "v" ] || [ "${__a,,}" = "x" ]; }; then
      if [ "${__a,,}" = "v" ]; then
        si_no "Escribio 'v'. Quiere volver al paso anterior?" && return 2
      else
        si_no "Escribio 'x'. Quiere cancelar el asistente?" && return 3
      fi
      continue
    fi
    [ -z "$__a" ] && { err "No puede quedar vacia."; continue; }
    read -rsp "  Confirme el dato: " __b || fin_entrada; echo
    [ "$__a" = "$__b" ] && break
    err "No coinciden, intente de nuevo."
  done
  printf -v "$__var" '%s' "$__a"
}

si_no() {
  local r=""
  while true; do
    read -rp "  $1 (s/n): " r || fin_entrada
    case "${r,,}" in s|si|y|yes) return 0;; n|no) return 1;; *) err "Responda s o n.";; esac
  done
}

# Navegacion dentro de los asistentes: 'v' vuelve, 'x' cancela.
# Devuelve 0 si el valor es normal, 2 para volver, 3 para cancelar.
_nav_check() {
  [ "${NAV_ON:-0}" = "1" ] || return 0
  case "${1,,}" in
    v|volver) return 2;;
    x|cancelar) return 3;;
  esac
  return 0
}

# si/no con navegacion: 0=si 1=no 2=volver 3=cancelar
si_no_nav() {
  local r=""
  while true; do
    read -rp "  $1 (s/n): " r || fin_entrada
    _nav_check "$r"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    case "${r,,}" in s|si|y|yes) return 0;; n|no) return 1;; *) err "Responda s o n.";; esac
  done
}

# ------------------------ Horarios y cron ----------------------------
hora_valida() { [[ "$1" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; }

normalizar_hora() {
  local h="${1%%:*}" m="${1##*:}"
  printf '%02d:%02d' "$((10#$h))" "$((10#$m))"
}

ordenar_horarios() { printf '%s\n' $1 | sort -u | paste -sd' ' -; }

pedir_horarios() {
  local entrada lista t valido
  while true; do
    say "  ${C_DIM}Una o varias horas del dia separadas por coma, formato HH:MM (24 horas).${C_R}"
    say "  ${C_DIM}Ejemplo de formato: 12:00,18:00${C_R}"
    read -rp "  Horas de respaldo: " entrada || fin_entrada
    _nav_check "$entrada"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    entrada="${entrada//,/ }"
    lista=""; valido=1
    for t in $entrada; do
      if hora_valida "$t"; then
        lista="${lista}${lista:+ }$(normalizar_hora "$t")"
      else
        err "Hora invalida: '$t'"; valido=0; break
      fi
    done
    if [ "$valido" -eq 1 ] && [ -n "$lista" ]; then
      HORARIOS="$(ordenar_horarios "$lista")"; return 0
    fi
    [ -z "$lista" ] && err "Debe indicar al menos una hora."
  done
}

pedir_dias() {
  local o
  while true; do
    echo
    say "  1) Todos los dias"
    say "  2) Lunes a viernes"
    say "  3) Fin de semana (sabado y domingo)"
    say "  4) Personalizado (formato cron: 0=domingo ... 6=sabado)"
    read -rp "  Dias de ejecucion [1-4]: " o || fin_entrada
    _nav_check "$o"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    case "$o" in
      1) DIAS_CRON="*";   return 0;;
      2) DIAS_CRON="1-5"; return 0;;
      3) DIAS_CRON="6,0"; return 0;;
      4) pedir DIAS_CRON "Valor cron para dia de semana"; return 0;;
      *) err "Opcion invalida.";;
    esac
  done
}

describir_dias() {
  case "$1" in
    "*")   echo "todos los dias";;
    "1-5") echo "lunes a viernes";;
    "6,0"|"0,6") echo "sabado y domingo";;
    *)     echo "cron: $1";;
  esac
}

lineas_cron() {
  local horarios="$1" dias="$2" cmd="$3" log="$4" t m minutos horas
  minutos="$(for t in $horarios; do echo "${t##*:}"; done | sort -u)"
  for m in $minutos; do
    horas="$(for t in $horarios; do
               [ "${t##*:}" = "$m" ] && echo $((10#${t%%:*}))
             done | sort -n -u | paste -sd, -)"
    echo "$((10#$m)) ${horas} * * ${dias} ${cmd} >> ${log} 2>&1"
  done
}

cron_aplicar() {
  local tag="$1" bloque="$2" tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk \
    -v s="# >>> ${CRON_TAG}:${tag} >>>" \
    -v e="# <<< ${CRON_TAG}:${tag} <<<" \
    '$0==s {inb=1; next} $0==e {inb=0; next} inb!=1 {print}' > "$tmp"
  if [ -n "$bloque" ]; then
    {
      echo "# >>> ${CRON_TAG}:${tag} >>>"
      echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      printf '%s\n' "$bloque"
      echo "# <<< ${CRON_TAG}:${tag} <<<"
    } >> "$tmp"
  fi
  crontab "$tmp" && rm -f "$tmp"
}

cron_mostrar() {
  crontab -l 2>/dev/null | awk \
    -v s="# >>> ${CRON_TAG}:${1} >>>" \
    -v e="# <<< ${CRON_TAG}:${1} <<<" \
    '$0==s {inb=1; next} $0==e {inb=0} inb==1 {print "    " $0}'
}

reprogramar() {
  local conf="$1"
  ( cargar_conf "$conf"
    cron_aplicar "$JOB_NOMBRE" \
      "$(lineas_cron "$HORARIOS" "$DIAS_CRON" "${BIN_DIR}/${JOB_NOMBRE}.sh" "$LOG_FILE")" )
  systemctl restart cron >/dev/null 2>&1
}

# ----------------------- Configuracion -------------------------------
cargar_conf() {
  unset JOB_TIPO JOB_NOMBRE ETIQUETA SERVIDOR RECURSO SUBCARPETA UNC MOUNT_POINT CRED_FILE \
        SMB_VERS MOUNT_OPTS RCLONE_REMOTE DEST_PATH RCLONE_CONFIG TEMP_LOCAL BENCH_PATH \
        SITE BACKUP_ORIGEN WITH_FILES BORRAR_ORIGEN RETENCION_DIAS HORARIOS DIAS_CRON SMB_PORT \
        MENSUAL_CONSERVAR MENSUAL_MESES VERIFICAR VERIFICAR_DESTINO ESTADO_FILE GEN_VERSION \
        METODO_RED ENTORNO RCLONE_BIN DIR_TRABAJO BENCH_RUTA_PROPIA \
        LOG_FILE RCLONE_LOG 2>/dev/null
  # shellcheck disable=SC1090
  . "$1"
}

guardar_conf() {
  local f="$1"; shift
  mkdir -p "$APP_DIR"; chmod 750 "$APP_DIR"
  : > "$f"
  {
    echo "# Configuracion generada por iZone ENTERPRISE - BACKUPS"
    echo "# $(date '+%Y-%m-%d %H:%M:%S')  -  servidor: ${HOST_SHORT}"
    local kv
    for kv in "$@"; do printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}"; done
  } >> "$f"
  chmod 640 "$f"
}

set_conf() {
  local f="$1" k="$2" v="$3" tmp
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    tmp="$(mktemp)"
    awk -v k="$k" -v v="$v" 'BEGIN{FS="="} $1==k {print k "=\"" v "\""; next} {print}' "$f" > "$tmp"
    mv "$tmp" "$f"
  else
    printf '%s="%s"\n' "$k" "$v" >> "$f"
  fi
  chmod 640 "$f"
}

listar_confs() { ls -1 "$APP_DIR"/*.conf 2>/dev/null; }

pedir_etiqueta() {
  local e
  say "  ${C_DIM}Etiqueta corta que identifique este destino. Se usa en el nombre del${C_R}"
  say "  ${C_DIM}script, la configuracion y el log, para que quien de mantenimiento${C_R}"
  say "  ${C_DIM}sepa de un vistazo cual es. Solo minusculas, numeros y guion.${C_R}"
  say "  ${C_DIM}Ejemplos: nas-contabilidad, nas-bodega, drive-gerencia${C_R}"
  while true; do
    pedir e "Etiqueta del trabajo" || return $?
    e="${e,,}"; e="${e// /-}"; e="${e//_/-}"
    if ! [[ "$e" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      err "Etiqueta invalida. Use minusculas, numeros y guion."
      continue
    fi
    if [ -f "${APP_DIR}/${BASE}-${e}.conf" ]; then
      err "Ya existe un trabajo con la etiqueta '${e}'."
      continue
    fi
    ETIQUETA="$e"; JOB="${BASE}-${e}"; return 0
  done
}

# ------------------------------ Sistema ------------------------------
requiere_root() {
  if [ "$(id -u)" -ne 0 ]; then
    pantalla "PERMISOS INSUFICIENTES"
    err "Este gestor debe ejecutarse como root."
    say  "  Vuelva a iniciarlo con:  ${C_B}sudo $0${C_R}"
    echo; exit 1
  fi
}

ayuda_repo_roto() {
  say "    ${C_DIM}Si hay un repositorio de terceros roto, desactivelo y reintente:${C_R}"
  say "    ${C_DIM}  ls /etc/apt/sources.list.d/${C_R}"
  say "    ${C_DIM}  sudo mv /etc/apt/sources.list.d/<archivo>.list{,.disabled}${C_R}"
  say "    ${C_DIM}  sudo apt-get update${C_R}"
  return 0
}

asegurar_paquete() {
  local pkg="$1" cmd="$2" salida roto
  command -v "$cmd" >/dev/null 2>&1 && { ok "'$pkg' ya esta instalado."; return 0; }

  info "Instalando '$pkg'..."
  salida="$(apt-get update 2>&1)"
  if printf '%s' "$salida" | grep -q "^E:"; then
    roto="$(printf '%s' "$salida" | grep -oP "(?<=The repository ')[^']+" | head -n 1)"
    warn "Un repositorio de terceros no responde; se continua igual."
    [ -n "$roto" ] && say "    ${C_DIM}${roto}${C_R}"
  fi

  # --no-remove: si apt necesitara eliminar paquetes para resolver la
  # instalacion, aborta en vez de tocar el sistema.
  salida="$(apt-get install -y --no-remove "$pkg" 2>&1)"
  if command -v "$cmd" >/dev/null 2>&1; then ok "'$pkg' instalado."; return 0; fi

  err "No se pudo instalar '$pkg'."
  printf '%s\n' "$salida" | grep -iE "^E:|Unable to locate|no installation candidate" | head -n 3 | sed 's/^/    /'
  ayuda_repo_roto

  if [ "$pkg" = "rclone" ]; then
    echo
    if si_no "rclone tiene un instalador oficial. Usarlo?"; then
      info "Instalando desde rclone.org..."
      curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1
      command -v rclone >/dev/null 2>&1 && { ok "rclone instalado."; return 0; }
      err "Tampoco se pudo. Revise la salida a internet del servidor."
    fi
  fi
  return 1
}

# ------------------------------ Frappe -------------------------------
pedir_frappe() {
  local encontrados n i opcion sitios
  echo
  say "  ${C_B}Entorno Frappe / ERPNext${C_R}"
  mapfile -t encontrados < <(ls -d /home/*/frappe-bench 2>/dev/null)
  n="${#encontrados[@]}"
  if [ "$n" -gt 0 ]; then
    say "  Benches detectados:"
    for i in "${!encontrados[@]}"; do say "    $((i+1))) ${encontrados[$i]}"; done
    say "    0) Escribir la ruta manualmente"
    read -rp "  Seleccione la ruta del bench: " opcion || fin_entrada
    _nav_check "$opcion" || return $?
    if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "$n" ]; then
      BENCH_PATH="${encontrados[$((opcion-1))]}"
    else
      pedir BENCH_PATH "Ruta absoluta del bench"
    fi
  else
    warn "No se detectaron carpetas frappe-bench en /home."
    pedir BENCH_PATH "Ruta absoluta del bench"
  fi
  [ -d "$BENCH_PATH/sites" ] || { err "No existe ${BENCH_PATH}/sites"; enter; return 1; }

  mapfile -t sitios < <(find "$BENCH_PATH/sites" -maxdepth 2 -name site_config.json -printf '%h\n' 2>/dev/null | xargs -r -n1 basename)
  if [ "${#sitios[@]}" -gt 0 ]; then
    say "  Sitios detectados:"
    for i in "${!sitios[@]}"; do say "    $((i+1))) ${sitios[$i]}"; done
    say "    0) Escribir el nombre manualmente"
    read -rp "  Seleccione el sitio a respaldar: " opcion || fin_entrada
    _nav_check "$opcion" || return $?
    if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "${#sitios[@]}" ]; then
      SITE="${sitios[$((opcion-1))]}"
    else
      pedir SITE "Nombre exacto del sitio"
    fi
  else
    warn "No se detectaron sitios."
    pedir SITE "Nombre exacto del sitio"
  fi

  BACKUP_ORIGEN="${BENCH_PATH}/sites/${SITE}/private/backups"
  [ -d "$BACKUP_ORIGEN" ] || warn "Aun no existe ${BACKUP_ORIGEN} (se creara con el primer backup)."
  si_no_nav "Incluir archivos adjuntos en el respaldo (--with-files)?"; local n=$?
  case "$n" in 0) WITH_FILES="si";; 1) WITH_FILES="no";; *) return "$n";; esac
  if [ "${TIPO_TRABAJO:-}" = "red" ] && [ "${METODO_RED:-}" = "rclone" ]; then
    # En la red sin montaje la verificacion no se elige: siempre completa
    # en el servidor y siempre releyendo desde el NAS byte a byte.
    VERIFICAR="si"; VERIFICAR_DESTINO="descarga"
    echo
    say "  ${C_B}Verificacion del respaldo${C_R}: completa, y cada respaldo se relee"
    say "  desde el NAS byte a byte antes de darlo por bueno."
    say "  ${C_DIM}En este metodo no se puede desactivar ni aligerar.${C_R}"
    echo
    info "Comprobando si este bench puede dejar el respaldo en una carpeta propia..."
    if bench_admite_ruta_propia "$BENCH_PATH" "$SITE"; then
      BENCH_RUTA_PROPIA="si"
      ok "Si. Cada respaldo se arma aparte y no se mezcla con otros trabajos."
    else
      BENCH_RUTA_PROPIA="no"
      warn "Este bench no admite --backup-path."
      say "    ${C_DIM}Se usara la carpeta de respaldos del sitio, tomando solo los archivos${C_R}"
      say "    ${C_DIM}que deje cada ejecucion.${C_R}"
    fi
    sleep 2
    return 0
  fi
  pedir_verificacion || return $?
  [ "${VERIFICAR:-si}" = "no" ] || pedir_verificacion_destino || return $?
  return 0
}

# bench >= v13 acepta --backup-path. Solo se pide la ayuda: no respalda nada.
bench_admite_ruta_propia() {   # bench_admite_ruta_propia <bench> <sitio>
  ( cd "$1" 2>/dev/null || exit 1
    # shellcheck disable=SC1091
    . env/bin/activate >/dev/null 2>&1
    timeout 120 bench --site "$2" backup --help 2>/dev/null ) | grep -q -- '--backup-path'
}

pedir_retencion() {
  local v n
  while true; do
    say "  ${C_DIM}Dias que se conservan TODOS los respaldos en el destino. 0 = no borrar nada.${C_R}"
    read -rp "  Dias de retencion: " v || fin_entrada
    _nav_check "$v"; n=$?
    [ "$n" -ne 0 ] && return "$n"
    [[ "$v" =~ ^[0-9]+$ ]] && { RETENCION_DIAS="$v"; break; }
    err "Escriba un numero entero (0 o mayor)."
  done

  MENSUAL_CONSERVAR="no"; MENSUAL_MESES="0"
  [ "$RETENCION_DIAS" -eq 0 ] && return 0

  echo
  say "  ${C_DIM}Ademas de esos dias se puede conservar el primer respaldo de cada mes,${C_R}"
  say "  ${C_DIM}para tener historial largo sin guardar todo. Los demas se eliminan.${C_R}"
  si_no_nav "Conservar un respaldo mensual?"; n=$?
  case "$n" in
    2|3) return "$n";;
    1)   return 0;;
  esac
  MENSUAL_CONSERVAR="si"
  while true; do
    say "  ${C_DIM}Meses que se conserva ese respaldo mensual. 0 = para siempre.${C_R}"
    read -rp "  Meses a conservar [12]: " v || fin_entrada
    v="${v:-12}"
    _nav_check "$v"; n=$?
    [ "$n" -ne 0 ] && return "$n"
    [[ "$v" =~ ^[0-9]+$ ]] && { MENSUAL_MESES="$v"; return 0; }
    err "Escriba un numero entero (0 o mayor)."
  done
}

describir_retencion() {   # describir_retencion <dias> <si/no> <meses>
  if [ "${1:-0}" -eq 0 ] 2>/dev/null; then echo "sin limite"; return; fi
  if [ "${2:-no}" = "si" ]; then
    if [ "${3:-0}" -eq 0 ] 2>/dev/null; then echo "${1} dias + mensual indefinido"
    else echo "${1} dias + mensual ${3} meses"; fi
  else
    echo "${1} dias"
  fi
}

# ====================== VERIFICACION Y ESTADO ========================
pedir_verificacion() {
  local o
  echo
  say "  ${C_B}Verificacion del respaldo${C_R}"
  say "  ${C_DIM}Antes de dar un respaldo por bueno se comprueba que se pueda abrir y${C_R}"
  say "  ${C_DIM}que el volcado no haya quedado a la mitad. Si la comprobacion falla,${C_R}"
  say "  ${C_DIM}el respaldo local NO se borra, NO se copia al destino y la retencion${C_R}"
  say "  ${C_DIM}NO se aplica: nunca se pierde un respaldo bueno por uno danado.${C_R}"
  echo
  say "   1) Completa ${C_DIM}(recomendada)${C_R}"
  say "      ${C_DIM}Revisa el volcado de la base y tambien los archivos adjuntos.${C_R}"
  say "   2) Rapida"
  say "      ${C_DIM}Igual de estricta con el volcado. En adjuntos de mas de 2 GB solo${C_R}"
  say "      ${C_DIM}comprueba el cierre del archivo. Util si el respaldo es enorme.${C_R}"
  say "   3) Sin verificacion"
  say "      ${C_DIM}Vuelve al comportamiento anterior. No recomendada.${C_R}"
  echo
  while true; do
    read -rp "  Verificacion [1]: " o || fin_entrada
    o="${o:-1}"
    _nav_check "$o"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    case "$o" in
      1) VERIFICAR="si";     return 0;;
      2) VERIFICAR="rapida"; return 0;;
      3) if si_no "Seguro? Un respaldo danado no avisaria a nadie."; then
           VERIFICAR="no"; return 0
         fi;;
      *) err "Opcion invalida.";;
    esac
  done
}

describir_verificacion() {
  case "${1:-si}" in
    si)     echo "completa";;
    rapida) echo "rapida";;
    no)     echo "DESACTIVADA";;
    *)      echo "${1}";;
  esac
}

# Cuanta certeza se exige sobre la copia que quedo en el destino, antes
# de borrar el respaldo local. Las opciones dependen del tipo de trabajo.
pedir_verificacion_destino() {
  local o tipo="${TIPO_TRABAJO:-red}"
  echo
  say "  ${C_B}Comprobacion de la copia en el destino${C_R}"
  say "  ${C_DIM}El respaldo local solo se borra cuando esta comprobacion pasa.${C_R}"
  echo
  if [ "$tipo" = "drive" ]; then
    say "   1) Por huella ${C_DIM}(recomendada)${C_R}"
    say "      ${C_DIM}Compara la huella MD5 que reporta Google contra la del archivo${C_R}"
    say "      ${C_DIM}local. Detecta cualquier diferencia de contenido, incluso si el${C_R}"
    say "      ${C_DIM}archivo danado pesa exactamente lo mismo. No descarga nada.${C_R}"
    say "      ${C_DIM}Si Google no devuelve la huella de algun archivo, se da por${C_R}"
    say "      ${C_DIM}fallido: comparar solo tamanos no prueba nada.${C_R}"
    say "   2) Descargando de vuelta"
    say "      ${C_DIM}Baja el respaldo desde Drive y lo compara byte a byte. Certeza${C_R}"
    say "      ${C_DIM}maxima y ademas prueba que se puede descargar. Consume el mismo${C_R}"
    say "      ${C_DIM}trafico que la subida, en cada respaldo.${C_R}"
  else
    say "   1) Basica ${C_DIM}(recomendada)${C_R}"
    say "      ${C_DIM}rsync ya comprueba cada archivo con checksum mientras copia;${C_R}"
    say "      ${C_DIM}ademas se confirma archivo por archivo que llego completo.${C_R}"
    say "   2) Completa"
    say "      ${C_DIM}Vuelve a leer el respaldo entero desde el NAS y recalcula las${C_R}"
    say "      ${C_DIM}huellas. Lo mas seguro, pero lee todo el respaldo por la red${C_R}"
    say "      ${C_DIM}en cada ejecucion.${C_R}"
  fi
  echo
  while true; do
    read -rp "  Comprobacion del destino [1]: " o || fin_entrada
    o="${o:-1}"
    _nav_check "$o"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    case "$o" in
      1) [ "$tipo" = "drive" ] && VERIFICAR_DESTINO="hash" || VERIFICAR_DESTINO="basico"
         return 0;;
      2) [ "$tipo" = "drive" ] && VERIFICAR_DESTINO="descarga" || VERIFICAR_DESTINO="completo"
         return 0;;
      *) err "Opcion invalida.";;
    esac
  done
}

describir_verificacion_destino() {
  case "${1:-}" in
    hash)     echo "huella MD5 de Google";;
    descarga) echo "releyendo y comparando byte a byte";;
    basico)   echo "basica";;
    completo) echo "relectura completa";;
    *)        echo "basica";;
  esac
}

# Los scripts de respaldo dejan el resultado de cada ejecucion en
# <trabajo>.estado. Aqui se lee para poder mostrarlo en los menus.
estado_leer() {   # estado_leer <archivo .estado>
  EST_ESTADO=""; EST_CODIGO=""; EST_DETALLE=""
  EST_FIN=""; EST_OK=""; EST_BYTES=""; EST_DESTINO=""
  [ -r "$1" ] || return 1
  local l k v
  while IFS= read -r l; do
    k="${l%%=*}"; v="${l#*=}"
    case "$k" in
      ULTIMO_ESTADO)  EST_ESTADO="$v";;
      ULTIMO_CODIGO)  EST_CODIGO="$v";;
      ULTIMO_DETALLE) EST_DETALLE="$v";;
      ULTIMO_FIN)     EST_FIN="$v";;
      ULTIMO_OK)      EST_OK="$v";;
      ULTIMO_BYTES)   EST_BYTES="$v";;
      ULTIMO_DESTINO) EST_DESTINO="$v";;
    esac
  done < "$1"
  return 0
}

# Ruta del archivo de estado a partir de la del .conf
estado_archivo() { printf '%s' "${1%.conf}.estado"; }

# Una linea con el resultado del ultimo respaldo, en color.
estado_resumen() {   # estado_resumen <archivo .conf>
  local e; e="$(estado_archivo "$1")"
  if ! estado_leer "$e"; then
    printf '%b' "${C_DIM}sin ejecutar todavia${C_R}"; return 0
  fi
  case "$EST_ESTADO" in
    OK)    printf '%b' "${C_GR}ultimo respaldo correcto${C_R} ${C_DIM}(${EST_FIN})${C_R}";;
    AVISO) printf '%b' "${C_YL}ultimo respaldo con aviso${C_R} ${C_DIM}(${EST_FIN})${C_R}";;
    FALLO) printf '%b' "${C_RD}${C_B}ULTIMO RESPALDO FALLIDO${C_R} ${C_DIM}(${EST_FIN})${C_R}";;
    *)     printf '%b' "${C_DIM}${EST_ESTADO:-sin datos}${C_R}";;
  esac
}

# Cuantos trabajos tienen el ultimo respaldo fallido.
trabajos_fallidos() {
  local c e n=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    e="$(estado_archivo "$c")"
    [ -r "$e" ] && grep -q '^ULTIMO_ESTADO=FALLO' "$e" && n=$((n+1))
  done < <(listar_confs)
  printf '%s' "$n"
}

# Bloque completo del estado, para el diagnostico y el menu del trabajo.
estado_detalle() {   # estado_detalle <archivo .conf>
  local e; e="$(estado_archivo "$1")"
  say "  ${C_B}Ultima ejecucion${C_R}"
  if ! estado_leer "$e"; then
    warn "todavia no se ha ejecutado ningun respaldo"
    return 0
  fi
  case "$EST_ESTADO" in
    OK)    ok   "resultado: correcto  (${EST_FIN})";;
    AVISO) warn "resultado: correcto con avisos  (${EST_FIN})";;
    FALLO) err  "resultado: FALLIDO  (${EST_FIN})  codigo ${EST_CODIGO}";;
    *)     warn "resultado: ${EST_ESTADO}";;
  esac
  [ -n "$EST_DETALLE" ] && say "    ${C_DIM}${EST_DETALLE}${C_R}"
  if [ -n "$EST_OK" ]; then
    say "    ${C_DIM}ultimo respaldo bueno: ${EST_OK}${C_R}"
  else
    say "    ${C_RD}aun no hay ningun respaldo bueno registrado${C_R}"
  fi
  [ -n "$EST_DESTINO" ] && say "    ${C_DIM}quedo en: ${EST_DESTINO}${C_R}"
  return 0
}

# ========================= AYUDAS DE RED =============================
puerto_abierto() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }

explicar_error_mount() {
  local s="$1"
  case "$s" in
    *"error(13)"*)
      err "Permiso denegado."
      say "    ${C_DIM}Revise usuario, contrasena, dominio, y que ese usuario tenga${C_R}"
      say "    ${C_DIM}Lectura/Escritura sobre la carpeta compartida en el servidor.${C_R}";;
    *"error(2)"*)
      err "No existe la ruta indicada."
      say "    ${C_DIM}En un NAS Synology la ruta NO incluye el volumen interno (volume1).${C_R}";;
    *"error(112)"*|*"error(101)"*|*"error(113)"*)
      err "No se alcanza el servidor. Revise IP, red o firewall.";;
    *"error(115)"*|*"error(110)"*)
      err "Tiempo agotado. El puerto 445 parece bloqueado.";;
    *"error(95)"*|*"error(5)"*)
      err "El servidor no acepta esa version del protocolo SMB.";;
    *"error(16)"*)
      err "El punto de montaje esta ocupado por otro recurso.";;
    *"error(1)"*)
      err "El sistema no permite montar carpetas de red (Operation not permitted)."
      say "    ${C_DIM}Pasa en contenedores LXC o Docker sin privilegios. No es un problema${C_R}"
      say "    ${C_DIM}de usuario, contrasena ni ruta.${C_R}";;
    *) err "No se pudo montar el recurso.";;
  esac
  [ -n "$s" ] && printf '%s\n' "$s" | sed 's/^/    /'
}

descubrir_recursos() {
  local p="${5:-445}"
  smbclient -L "//$1" -U "$2%$3" -W "$4" -p "$p" -g -m SMB3 2>/dev/null \
    | awk -F'|' '$1=="Disk" && $2 !~ /\$$/ {print $2}'
}

descubrir_subcarpetas() {
  local p="${6:-445}"
  smbclient "//$1/$2" -U "$3%$4" -W "$5" -p "$p" -c "ls" 2>/dev/null \
    | sed -nE 's/^  (.*[^ ]) +([DAHNRS]+) +[0-9]+ +.*$/\2\t\1/p' \
    | awk -F'\t' '$1 ~ /D/ && $2 != "." && $2 != ".." {print $2}'
}

probar_version_smb() {
  local unc="$1" cred="$2" puerto="${3:-445}" d v extra=""
  [ "$puerto" != "445" ] && extra=",port=${puerto}"
  d="$(mktemp -d)"
  for v in 3.1.1 3.0 2.1; do
    if mount -t cifs "$unc" "$d" \
         -o "credentials=${cred},vers=${v},sec=ntlmssp,iocharset=utf8,nounix,noserverino${extra}" \
         >/dev/null 2>&1; then
      umount "$d" >/dev/null 2>&1; rmdir "$d"; printf '%s' "$v"; return 0
    fi
  done
  rmdir "$d" 2>/dev/null; return 1
}

# ================ ENTORNO Y RED SIN MONTAJE (rclone) ==================
# Tipo de contenedor (lxc, docker...) o vacio si no es un contenedor.
entorno_contenedor() {
  local c=""
  c="$(systemd-detect-virt --container 2>/dev/null)" || c=""
  [ "$c" = "none" ] && c=""
  if [ -z "$c" ]; then
    if [ -r /run/systemd/container ]; then
      c="$(head -n 1 /run/systemd/container 2>/dev/null)"
    elif [ -f /.dockerenv ]; then
      c="docker"
    else
      c="$(tr '\0' '\n' 2>/dev/null < /proc/1/environ | sed -n 's/^container=//p' | head -n 1)"
    fi
  fi
  printf '%s' "$c"
}

# 0 si el root de aqui no es el root real del equipo (espacio de usuarios
# propio): es lo que tiene un contenedor sin privilegios.
entorno_sin_privilegios() {
  local m
  m="$(awk 'NR==1 {print $1" "$2" "$3}' /proc/self/uid_map 2>/dev/null)"
  [ -n "$m" ] && [ "$m" != "0 0 4294967295" ]
}

# Decide si tiene sentido intentar un montaje CIFS. Deja la descripcion
# en ENTORNO_DESC y, si no se puede, el motivo en ENTORNO_MOTIVO.
#   0 = se puede intentar   1 = el entorno no lo permite
entorno_puede_montar() {
  local c; c="$(entorno_contenedor)"
  ENTORNO_MOTIVO=""
  if [ -z "$c" ]; then
    ENTORNO_DESC="servidor o maquina virtual"; return 0
  fi
  if entorno_sin_privilegios; then
    ENTORNO_DESC="contenedor ${c} sin privilegios"
    ENTORNO_MOTIVO="es un ${ENTORNO_DESC}: el sistema no permite montar carpetas de red"
    return 1
  fi
  ENTORNO_DESC="contenedor ${c} con privilegios"
  return 0
}

rclone_con_smb() {   # rclone_con_smb <binario>  -> 0 si trae el backend smb (v1.60+)
  [ -n "${1:-}" ] && command -v "$1" >/dev/null 2>&1 || return 1
  "$1" help backends 2>/dev/null | awk '{print $1}' | grep -qx smb
}

rclone_version_de() { "$1" version 2>/dev/null | head -n 1 | awk '{print $2}'; }

# Descarga el rclone oficial y lo deja en RCLONE_PRIV. Comprueba la huella
# SHA256 que publica rclone.org antes de instalar nada. El rclone del
# sistema, que usan los trabajos de Drive, no se toca.
instalar_rclone_privado() {
  local arq ver base zip tmp bin
  case "$(uname -m)" in
    x86_64|amd64)  arq="amd64";;
    aarch64|arm64) arq="arm64";;
    armv7l)        arq="arm-v7";;
    i?86)          arq="386";;
    *) err "Arquitectura no soportada: $(uname -m)"; return 1;;
  esac
  command -v curl >/dev/null 2>&1 || asegurar_paquete curl curl || return 1
  info "Consultando la version actual de rclone..."
  ver="$(curl -fsSL --max-time 30 https://downloads.rclone.org/version.txt 2>/dev/null | awk '{print $2}')"
  [[ "$ver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    err "No se pudo consultar rclone.org. Revise la salida a internet del servidor."; return 1; }
  base="https://downloads.rclone.org/${ver}"
  zip="rclone-${ver}-linux-${arq}.zip"
  tmp="$(mktemp -d)"
  info "Descargando rclone ${ver}..."
  if ! curl -fsSL --max-time 600 -o "${tmp}/${zip}" "${base}/${zip}" \
     || ! curl -fsSL --max-time 60 -o "${tmp}/SHA256SUMS" "${base}/SHA256SUMS"; then
    err "Fallo la descarga."; rm -rf "$tmp"; return 1
  fi
  if ! ( cd "$tmp" && awk -v f="$zip" '$2==f' SHA256SUMS | grep -q . \
         && awk -v f="$zip" '$2==f' SHA256SUMS | sha256sum -c - >/dev/null 2>&1 ); then
    err "La huella SHA256 de la descarga no coincide. No se instalo nada."
    rm -rf "$tmp"; return 1
  fi
  ok "Huella SHA256 de la descarga verificada."
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "${tmp}/${zip}" -d "$tmp" 2>/dev/null
  else
    python3 -I -m zipfile -e "${tmp}/${zip}" "$tmp" 2>/dev/null
  fi
  bin="${tmp}/rclone-${ver}-linux-${arq}/rclone"
  [ -f "$bin" ] || { err "El paquete descargado no trae el binario esperado."; rm -rf "$tmp"; return 1; }
  mkdir -p "$(dirname "$RCLONE_PRIV")"
  install -m 755 "$bin" "${RCLONE_PRIV}.nuevo" && mv -f "${RCLONE_PRIV}.nuevo" "$RCLONE_PRIV"
  rm -rf "$tmp"
  if rclone_con_smb "$RCLONE_PRIV"; then
    ok "rclone ${ver} instalado en ${RCLONE_PRIV}."; return 0
  fi
  err "La copia instalada no responde."; return 1
}

# Deja en RCLONE_BIN un rclone con soporte SMB: el del sistema si sirve,
# si no la copia del gestor, y si tampoco existe ofrece instalarla.
# 0 = listo   2 = volver   3 = cancelar
red_asegurar_rclone() {
  local sis r
  sis="$(command -v rclone 2>/dev/null)"
  if [ -n "$sis" ] && rclone_con_smb "$sis"; then
    RCLONE_BIN="$sis"; ok "rclone $(rclone_version_de "$sis") del sistema, con soporte SMB."; return 0
  fi
  if rclone_con_smb "$RCLONE_PRIV"; then
    RCLONE_BIN="$RCLONE_PRIV"; ok "rclone $(rclone_version_de "$RCLONE_PRIV") del gestor, con soporte SMB."; return 0
  fi
  if [ -n "$sis" ]; then
    warn "El rclone de este servidor ($(rclone_version_de "$sis")) es anterior a la v1.60 y no trae SMB."
  else
    warn "rclone no esta instalado en este servidor."
  fi
  say "  ${C_DIM}Se puede descargar el rclone oficial SOLO para estos trabajos, en:${C_R}"
  say "  ${C_DIM}  ${RCLONE_PRIV}${C_R}"
  say "  ${C_DIM}No reemplaza ni modifica el rclone del sistema: los trabajos de Google${C_R}"
  say "  ${C_DIM}Drive siguen usando el suyo. No reinicia ni detiene nada.${C_R}"
  echo
  si_no_nav "Descargar e instalar esa copia ahora?"; r=$?
  case "$r" in
    0) instalar_rclone_privado && { RCLONE_BIN="$RCLONE_PRIV"; return 0; }
       enter; return 2;;
    1) err "Sin un rclone con SMB este servidor no puede enviar al NAS sin montarlo."
       enter; return 3;;
    *) return "$r";;
  esac
}

# rclone hacia el NAS sin archivo de configuracion: la conexion se arma en
# variables de entorno de un subproceso a partir del .cred, que sigue
# siendo el unico lugar donde vive la contrasena. Nada se escribe en el
# rclone.conf, asi que el NAS no aparece entre las cuentas de Drive.
nas_usar() {   # nas_usar <servidor> <puerto> <archivo .cred> <rclone>
  NAS_SRV="$1"; NAS_PUERTO="${2:-445}"; NAS_CRED="$3"; NAS_BIN="$4"
}

nas_rc() {   # nas_rc <argumentos de rclone>   (NAS_ESPERA=segundos para limitar)
  ( u="$(sed -n 's/^username=//p' "$NAS_CRED" 2>/dev/null | head -n 1)"
    p="$(sed -n 's/^password=//p' "$NAS_CRED" 2>/dev/null | head -n 1)"
    d="$(sed -n 's/^domain=//p'   "$NAS_CRED" 2>/dev/null | head -n 1)"
    if [ -z "$u" ] || [ -z "$p" ]; then
      echo "No se pudieron leer las credenciales de ${NAS_CRED}" >&2; exit 98
    fi
    export RCLONE_CONFIG_IZONENAS_TYPE="smb"
    export RCLONE_CONFIG_IZONENAS_HOST="$NAS_SRV"
    export RCLONE_CONFIG_IZONENAS_PORT="$NAS_PUERTO"
    export RCLONE_CONFIG_IZONENAS_USER="$u"
    export RCLONE_CONFIG_IZONENAS_DOMAIN="${d:-WORKGROUP}"
    RCLONE_CONFIG_IZONENAS_PASS="$(printf '%s' "$p" | "$NAS_BIN" obscure - 2>/dev/null)"
    export RCLONE_CONFIG_IZONENAS_PASS
    if [ -n "${NAS_ESPERA:-}" ]; then
      exec timeout "$NAS_ESPERA" "$NAS_BIN" "$@" --contimeout 20s </dev/null
    fi
    exec "$NAS_BIN" "$@" --contimeout 20s </dev/null )
}

nas_explicar_error() {
  local s="$1"
  case "$s" in
    *LOGON_FAILURE*|*"logon failure"*)
      say "    ${C_DIM}Usuario o contrasena incorrectos.${C_R}";;
    *BAD_NETWORK_NAME*)
      say "    ${C_DIM}No existe esa carpeta compartida en el servidor.${C_R}";;
    *ACCESS_DENIED*|*"access denied"*)
      say "    ${C_DIM}El usuario no tiene Lectura/Escritura sobre esa carpeta.${C_R}";;
    *"connection refused"*|*"i/o timeout"*|*"no route"*|*"unreachable"*)
      say "    ${C_DIM}No se alcanza el servidor por el puerto SMB.${C_R}";;
  esac
  [ -n "$s" ] && printf '%s\n' "$s" | grep -v '^[[:space:]]*$' | tail -n 4 | sed 's/^/    /'
  return 0
}

# Prueba el canal completo tal como lo usara cada respaldo: crear,
# escribir, renombrar, leer, comparar la huella y borrar. Si algo no sale
# perfecto no se da por bueno.
nas_probar_canal() {   # nas_probar_canal <recurso/subcarpeta>
  local base="$1" tmp h1 h2 prueba salida
  prueba=".izone_prueba_$$"
  info "Conectando con //${NAS_SRV}/${base} por rclone..."
  NAS_ESPERA=90 nas_rc mkdir "izonenas:${base}" >/dev/null 2>&1
  if ! salida="$(NAS_ESPERA=90 nas_rc lsf "izonenas:${base}" --max-depth 1 2>&1)"; then
    err "No se pudo abrir esa carpeta en el NAS."
    nas_explicar_error "$salida"; return 1
  fi
  ok "Carpeta accesible."
  tmp="$(mktemp)"
  head -c 1048576 /dev/urandom > "$tmp"
  h1="$(sha256sum "$tmp" | awk '{print $1}')"
  info "Escribiendo un archivo de prueba de 1 MB..."
  if ! salida="$(NAS_ESPERA=120 nas_rc copyto "$tmp" "izonenas:${base}/${prueba}.a/prueba.bin" 2>&1)"; then
    rm -f "$tmp"; err "No se pudo escribir en el NAS."
    nas_explicar_error "$salida"; return 1
  fi
  rm -f "$tmp"
  info "Renombrando en el NAS, como se hara con cada respaldo..."
  if ! salida="$(NAS_ESPERA=120 nas_rc moveto "izonenas:${base}/${prueba}.a" "izonenas:${base}/${prueba}.b" 2>&1)"; then
    NAS_ESPERA=60 nas_rc purge "izonenas:${base}/${prueba}.a" >/dev/null 2>&1
    err "El NAS no permitio renombrar la carpeta."
    nas_explicar_error "$salida"; return 1
  fi
  info "Releyendo desde el NAS y comparando la huella..."
  if ! h2="$(NAS_ESPERA=120 nas_rc cat "izonenas:${base}/${prueba}.b/prueba.bin" 2>/dev/null | sha256sum | awk '{print $1}')"; then
    NAS_ESPERA=60 nas_rc purge "izonenas:${base}/${prueba}.b" >/dev/null 2>&1
    err "No se pudo leer de vuelta el archivo de prueba desde el NAS."; return 1
  fi
  NAS_ESPERA=60 nas_rc purge "izonenas:${base}/${prueba}.b" >/dev/null 2>&1
  if [ "$h1" != "$h2" ]; then
    err "Lo que se leyo del NAS no coincide con lo que se escribio."; return 1
  fi
  if NAS_ESPERA=60 nas_rc lsf "izonenas:${base}" --max-depth 1 2>/dev/null | grep -q "^${prueba}"; then
    warn "No se pudo borrar la carpeta de prueba ${prueba}.b; puede eliminarla a mano."
  fi
  ok "Escritura, renombrado, lectura y borrado correctos."
  return 0
}

# Carpeta local donde se arma cada respaldo antes de subirlo.
pedir_dir_trabajo() {   # usa y deja DIR_TRABAJO
  local fs
  say "  ${C_DIM}Carpeta local donde se arma cada respaldo antes de enviarlo. Se vacia${C_R}"
  say "  ${C_DIM}al terminar. Debe estar en disco, no en memoria (tmpfs).${C_R}"
  while true; do
    pedir DIR_TRABAJO "Carpeta local de trabajo" "${DIR_TRABAJO:-${TRABAJO_BASE}/${JOB}}" || return $?
    DIR_TRABAJO="${DIR_TRABAJO%/}"
    if [ "${DIR_TRABAJO:0:1}" != "/" ] || [ "$DIR_TRABAJO" = "" ]; then
      err "Debe ser una ruta absoluta, distinta de /."; DIR_TRABAJO=""; continue
    fi
    mkdir -p "$DIR_TRABAJO" 2>/dev/null || { err "No se pudo crear ${DIR_TRABAJO}."; continue; }
    chmod 750 "$DIR_TRABAJO"
    fs="$(findmnt -n -o FSTYPE -T "$DIR_TRABAJO" 2>/dev/null)"
    if [ "$fs" = "tmpfs" ] || [ "$fs" = "ramfs" ]; then
      err "Esa carpeta esta en memoria RAM (${fs}): un respaldo grande dejaria"
      say "    ${C_DIM}al servidor sin memoria. Elija una carpeta en disco.${C_R}"
      DIR_TRABAJO=""; continue
    fi
    ok "Espacio libre ahi: $(df -h "$DIR_TRABAJO" | awk 'NR==2 {print $4}')"
    return 0
  done
}

fstab_escribir() {      # <tag> <unc> <mountpoint> <opts> [mp_anterior]
  local tag="$1" unc="$2" mp="$3" opts="$4" mp_old="${5:-$3}" marca tmp
  marca="# ${CRON_TAG}:${tag}"
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  awk -v m="$marca" -v a="$mp" -v b="$mp_old" '
    $0==m { skip=1; next }
    skip==1 { skip=0; next }
    ($1 !~ /^#/ && ($2==a || $2==b)) { next }
    { print }' /etc/fstab > "$tmp"
  printf '%s\n%s  %s  cifs  %s  0 0\n' "$marca" "${unc// /\\040}" "$mp" "$opts" >> "$tmp"
  cat "$tmp" > /etc/fstab; rm -f "$tmp"
  systemctl daemon-reload >/dev/null 2>&1
}

fstab_quitar() {
  local marca="# ${CRON_TAG}:${1}" mp="$2" tmp
  cp /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  awk -v m="$marca" -v mp="$mp" '
    $0==m { skip=1; next } skip==1 { skip=0; next }
    ($1 !~ /^#/ && $2==mp) { next } { print }' /etc/fstab > "$tmp"
  cat "$tmp" > /etc/fstab; rm -f "$tmp"
  systemctl daemon-reload >/dev/null 2>&1
}

# ======================== AYUDAS DE DRIVE =============================
rc() { timeout "$RCLONE_ESPERA" rclone "$@" </dev/null; }

drive_archivo_config() {
  local f
  f="$(rclone config file 2>/dev/null | tail -n 1)"
  [ -n "$f" ] && [ "${f:0:1}" = "/" ] || f="/root/.config/rclone/rclone.conf"
  printf '%s' "$f"
}

drive_escribir_remote() {
  local nombre="$1" token="$2" cid="${3:-}" csec="${4:-}" cfg tmp
  if ! [[ "$nombre" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    err "El nombre '${nombre}' no es valido para rclone; no se escribio nada."
    return 1
  fi
  cfg="$(drive_archivo_config)"
  mkdir -p "$(dirname "$cfg")"; [ -f "$cfg" ] || : > "$cfg"; chmod 600 "$cfg"
  tmp="$(mktemp)"
  awk -v s="[${nombre}]" '$0==s {skip=1; next} /^\[/ {skip=0} skip!=1 {print}' "$cfg" > "$tmp"
  {
    printf '[%s]\n' "$nombre"
    printf 'type = drive\n'
    [ -n "$cid" ]  && printf 'client_id = %s\n' "$cid"
    [ -n "$csec" ] && printf 'client_secret = %s\n' "$csec"
    printf 'scope = drive\n'
    printf 'token = %s\n' "$token"
    printf '\n'
  } >> "$tmp"
  cat "$tmp" > "$cfg"; rm -f "$tmp"; chmod 600 "$cfg"
  rclone listremotes 2>/dev/null | grep -qx "${nombre}:"
}

drive_crear_remote() {
  local NAV_ON=1 NOMBRE="" CLIENT_ID="" CLIENT_SECRET="" TOKEN=""
  local paso=1 estado
  while :; do
    case "$paso" in
      1) drv_cta_nombre;;
      2) drv_cta_credenciales;;
      3) drv_cta_token;;
      *) break;;
    esac
    estado=$?
    case "$estado" in
      0) paso=$((paso+1));;
      2) paso=$((paso-1)); [ "$paso" -lt 1 ] && return 0;;
      3) pantalla "CUENTAS DE GOOGLE DRIVE  >  Cancelado"
         warn "No se conecto ninguna cuenta."; enter; return 0;;
      9) break;;
    esac
  done
  return 0
}

drv_cta_nombre() {
  pantalla "CONECTAR UNA CUENTA  >  [1 de 3] Nombre"
  aviso_navegacion
  say "  Google exige un navegador para autorizar. Este servidor no lo tiene, asi que"
  say "  la autorizacion se hace en su computadora y aqui solo se pega el resultado."
  hr
  say "  ${C_DIM}Etiqueta interna del servidor, no un correo. Solo letras, numeros,${C_R}"
  say "  ${C_DIM}guion y guion bajo. Nombrela por su proposito: izone-backups.${C_R}"
  local r
  while true; do
    pedir NOMBRE "Nombre de la cuenta" "${NOMBRE:-gdrive}" || return $?
    if ! [[ "$NOMBRE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
      err "Nombre invalido: rclone rechaza @ . espacios y acentos."
      continue
    fi
    if rclone listremotes 2>/dev/null | grep -qx "${NOMBRE}:"; then
      warn "Ya existe una cuenta llamada '${NOMBRE}'."
      si_no_nav "Desea reemplazarla?"; r=$?
      case "$r" in
        2|3) return "$r";;
        1)   say "  ${C_DIM}Escriba otro nombre.${C_R}"; continue;;
      esac
      rclone config delete "$NOMBRE" >/dev/null 2>&1
    fi
    return 0
  done
}

drv_cta_credenciales() {
  local r
  pantalla "CONECTAR UNA CUENTA  >  [2 de 3] Credenciales de Google"
  aviso_navegacion
  say "  rclone trae credenciales publicas compartidas por todos sus usuarios. Cuando"
  say "  ese cupo se satura Google responde 'Quota exceeded' y todo se vuelve lento."
  echo
  si_no_nav "Usar credenciales propias de Google? (muy recomendado)"; r=$?
  case "$r" in
    2|3) return "$r";;
    1) CLIENT_ID=""; CLIENT_SECRET=""
       warn "Se usaran las credenciales compartidas de rclone."
       say "    ${C_DIM}Si mas adelante ve esperas largas, vuelva aqui con 'v'.${C_R}"
       sleep 2; return 0;;
  esac
  echo
  say "  ${C_DIM} 1. console.cloud.google.com > cree un proyecto${C_R}"
  say "  ${C_DIM} 2. APIs y servicios > Biblioteca > habilite 'Google Drive API'${C_R}"
  say "  ${C_DIM} 3. Pantalla de consentimiento OAuth > Externo > agregue su cuenta${C_R}"
  say "  ${C_DIM} 4. Credenciales > Crear credenciales > ID de cliente de OAuth${C_R}"
  say "  ${C_DIM}    Tipo de aplicacion: Aplicacion de escritorio${C_R}"
  echo
  pedir CLIENT_ID "ID de cliente" "$CLIENT_ID" || return $?
  pedir CLIENT_SECRET "Secreto de cliente" "$CLIENT_SECRET" || return $?
  return 0
}

drv_cta_token() {
  local salida estado
  pantalla "CONECTAR UNA CUENTA  >  [3 de 3] Autorizacion"
  aviso_navegacion
  if [ -n "$CLIENT_ID" ]; then
    say "  ${C_DIM}Usando credenciales propias de Google.${C_R}"
  else
    say "  ${C_DIM}Usando las credenciales compartidas de rclone.${C_R}"
    say "  ${C_DIM}Con 'v' vuelve al paso anterior si prefiere usar las propias.${C_R}"
  fi
  echo
  say "  ${C_B}Paso 1.${C_R} En su computadora con navegador, instale rclone:"
  say "    ${C_DIM}Windows : https://rclone.org/downloads/ y abra PowerShell en esa carpeta${C_R}"
  say "    ${C_DIM}Linux/Mac: sudo -v && curl https://rclone.org/install.sh | sudo bash${C_R}"
  echo
  say "  ${C_B}Paso 2.${C_R} Ejecute alli exactamente:"
  echo
  if [ -n "$CLIENT_ID" ]; then
    say "        ${C_CY}${C_B}rclone authorize \"drive\" \"${CLIENT_ID}\" \"${CLIENT_SECRET}\"${C_R}"
  else
    say "        ${C_CY}${C_B}rclone authorize \"drive\"${C_R}"
  fi
  echo
  say "  ${C_B}Paso 3.${C_R} Copie el bloque entre 'Paste the following' y 'End paste'"
  say "    ${C_DIM}(empieza con { y termina con }) y peguelo aqui en una sola linea.${C_R}"
  echo
  while true; do
    read -rp "  Token: " TOKEN || fin_entrada
    TOKEN="$(printf '%s' "$TOKEN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    _nav_check "$TOKEN"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    if [ -z "$TOKEN" ]; then err "No pego nada."
    elif [ "${TOKEN:0:1}" != "{" ] || [ "${TOKEN: -1}" != "}" ]; then
      err "Debe empezar con '{' y terminar con '}'."
    elif ! printf '%s' "$TOKEN" | grep -q "access_token"; then
      err "Ese texto no parece el token de Google."
    else break; fi
  done

  echo
  info "Registrando la cuenta (maximo ${RCLONE_ESPERA} segundos)..."
  if [ -n "$CLIENT_ID" ]; then
    salida="$(rc config create "$NOMBRE" drive scope=drive token="$TOKEN" \
                client_id="$CLIENT_ID" client_secret="$CLIENT_SECRET" 2>&1)"; estado=$?
  else
    salida="$(rc config create "$NOMBRE" drive scope=drive token="$TOKEN" 2>&1)"; estado=$?
  fi
  case "$estado" in
    0) ok "Cuenta registrada por rclone.";;
    *) if [ "$estado" -eq 124 ]; then warn "rclone no respondio a tiempo."
       else warn "rclone rechazo el comando:"; printf '%s\n' "$salida" | head -n 4 | sed 's/^/    /'; fi
       info "Registrando la configuracion directamente..."
       if drive_escribir_remote "$NOMBRE" "$TOKEN" "$CLIENT_ID" "$CLIENT_SECRET"; then
         ok "Cuenta registrada."
       else
         err "No se pudo registrar."; enter; return 3
       fi;;
  esac

  echo
  info "Verificando el acceso (maximo ${RCLONE_ESPERA} segundos)..."
  salida="$(rc lsd "${NOMBRE}:" 2>&1)"; estado=$?
  case "$estado" in
    0)   ok "Cuenta conectada correctamente."
         printf '%s\n' "$salida" | head -n 5 | sed 's/^/    /';;
    124) warn "La verificacion tardo mas de ${RCLONE_ESPERA} segundos."
         say "    ${C_DIM}La cuenta quedo guardada. Suele ser el limite de peticiones de Google.${C_R}"
         [ -z "$CLIENT_ID" ] && say "    ${C_DIM}Se corrige reconectando con credenciales propias.${C_R}";;
    *)   err "No se pudo usar la cuenta:"
         printf '%s\n' "$salida" | head -n 5 | sed 's/^/    /'
         case "$salida" in
           *"invalid characters"*) say "    ${C_DIM}Nombre invalido. Repita con algo simple.${C_R}";;
           *"oauth2"*|*"invalid_grant"*|*"401"*) say "    ${C_DIM}El token expiro. Genere uno nuevo.${C_R}";;
           *"storageQuota"*) say "    ${C_DIM}La cuenta no tiene espacio disponible.${C_R}";;
           *"403"*|*"Quota"*|*"rateLimit"*) say "    ${C_DIM}Limite de cuota: use credenciales propias.${C_R}";;
         esac;;
  esac
  enter
  return 9
}

drive_diagnostico() {
  local r="$1" out ini fin seg est
  pantalla "CUENTAS DE GOOGLE DRIVE  >  Diagnostico"
  say "  Cuenta: ${C_B}${r}${C_R}"
  echo
  if rclone config show "$r" 2>/dev/null | grep -q "^client_id"; then
    ok "Usa credenciales propias de Google."
  else
    warn "Usa las credenciales compartidas de rclone."
    say "    ${C_DIM}Causa habitual de esperas largas y errores 403 'Quota exceeded'.${C_R}"
  fi
  echo
  info "Listando la raiz del Drive (maximo ${RCLONE_ESPERA} segundos)..."
  ini="$(date +%s)"; out="$(rc lsd "${r}:" -vv 2>&1)"; est=$?
  fin="$(date +%s)"; seg=$((fin-ini))
  echo
  if printf '%s' "$out" | grep -qi "rateLimitExceeded\|Quota exceeded\|userRateLimitExceeded"; then
    err "Google esta limitando las peticiones (403 Quota exceeded)."
    say "    ${C_DIM}rclone reintenta con esperas crecientes, por eso parece congelado.${C_R}"
    say "    ${C_DIM}Reconecte la cuenta con credenciales propias de Google.${C_R}"
  elif [ "$est" -eq 124 ]; then
    err "No hubo respuesta en ${RCLONE_ESPERA} segundos."
  elif [ "$est" -ne 0 ]; then
    err "rclone devolvio un error:"
    printf '%s\n' "$out" | grep -v "DEBUG" | head -n 8 | sed 's/^/    /'
  else
    ok "Respuesta correcta en ${seg} segundos."
    [ "$seg" -gt 15 ] && warn "Tardo mas de lo normal; revise las credenciales."
    printf '%s\n' "$out" | grep -v "DEBUG\|INFO" | head -n 5 | sed 's/^/    /'
  fi
  enter
}

drive_elegir_carpeta() {
  local remote="$1" ruta="${2:-}" items=() i op nueva destino salida est
  while true; do
    pantalla "GOOGLE DRIVE  >  Carpeta destino"
    say "  Ubicacion actual: ${C_B}${remote}:/${ruta}${C_R}"
    echo
    mapfile -t items < <(rc lsf "${remote}:${ruta}" --dirs-only 2>/dev/null | sed 's:/$::')
    if [ "${#items[@]}" -gt 0 ]; then
      say "  Carpetas aqui dentro:"
      for i in "${!items[@]}"; do say "    $((i+1))) ${items[$i]}"; done
    else
      say "  ${C_DIM}(no hay subcarpetas en esta ubicacion)${C_R}"
    fi
    echo
    say "    ${C_B}a${C_R}) Usar ESTA carpeta como destino"
    say "    ${C_B}n${C_R}) Crear una carpeta nueva aqui"
    [ -n "$ruta" ] && say "    ${C_B}s${C_R}) Subir un nivel"
    say "    ${C_B}r${C_R}) Volver a leer el contenido del Drive"
    say "    ${C_B}m${C_R}) Escribir la ruta completa a mano"
    [ "${NAV_ON:-0}" = "1" ] && say "    ${C_B}v${C_R}) Volver al paso anterior    ${C_B}x${C_R}) Cancelar"
    echo
    read -rp "  Numero para entrar, o letra: " op || fin_entrada
    if [ "${NAV_ON:-0}" = "1" ]; then
      case "${op,,}" in v) return 2;; x) return 3;; esac
    fi
    case "$op" in
      a|A) if [ -z "$ruta" ]; then
             warn "La raiz del Drive mezclaria los respaldos con todo lo demas."
             si_no "Aun asi desea usar la raiz?" || continue
           fi
           DEST_PATH="$ruta"; return 0;;
      n|N) pedir nueva "Nombre de la carpeta nueva"
           destino="${ruta}${ruta:+/}${nueva}"
           info "Creando '${nueva}'..."
           salida="$(rc mkdir "${remote}:${destino}" 2>&1)"; est=$?
           if [ "$est" -eq 0 ] && rc lsf "${remote}:${destino}" >/dev/null 2>&1; then
             ok "Carpeta creada."; ruta="$destino"; sleep 1
           else
             echo; err "No se pudo crear la carpeta en ${remote}:/${ruta}"
             [ -n "$salida" ] && printf '%s\n' "$salida" | head -n 5 | sed 's/^/    /'
             case "${est}:${salida}" in
               124:*) say "    ${C_DIM}Google no respondio a tiempo. En la raiz rclone recorre todo el${C_R}"
                      say "    ${C_DIM}Drive y eso choca con el limite compartido. Entre a una carpeta${C_R}"
                      say "    ${C_DIM}existente, o reconecte con credenciales propias.${C_R}";;
               *storageQuota*) say "    ${C_DIM}La cuenta de Google no tiene espacio disponible.${C_R}";;
               *403*|*Quota*|*rateLimit*)
                      say "    ${C_DIM}Limite de peticiones de Google: use credenciales propias.${C_R}";;
               *)     say "    ${C_DIM}Alternativa: creela en drive.google.com y pulse 'r' aqui.${C_R}";;
             esac
             enter
           fi;;
      s|S) if [[ "$ruta" == */* ]]; then ruta="${ruta%/*}"; else ruta=""; fi;;
      r|R) ;;
      m|M) pedir DEST_PATH "Ruta completa dentro del Drive"
           DEST_PATH="${DEST_PATH#/}"; DEST_PATH="${DEST_PATH%/}"
           rc mkdir "${remote}:${DEST_PATH}" >/dev/null 2>&1
           return 0;;
      *)   if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le "${#items[@]}" ]; then
             ruta="${ruta}${ruta:+/}${items[$((op-1))]}"
           else err "Opcion invalida."; sleep 1; fi;;
    esac
  done
}

menu_cuentas_drive() {
  command -v rclone >/dev/null 2>&1 || { pantalla "CUENTAS DE GOOGLE DRIVE"; asegurar_paquete rclone rclone || { enter; return 1; }; }
  local op remotes n
  while true; do
    pantalla "CUENTAS DE GOOGLE DRIVE"
    remotes="$(rclone listremotes 2>/dev/null | sed 's/:$//')"
    if [ -n "$remotes" ]; then
      say "  Cuentas registradas en este servidor:"
      printf '%s\n' "$remotes" | sed 's/^/    - /'
    else
      warn "Todavia no hay ninguna cuenta conectada."
    fi
    echo
    say "   1) Conectar una cuenta"
    say "   2) Diagnosticar una cuenta"
    say "   3) Eliminar una cuenta"
    say "   4) Asistente completo de rclone (avanzado)"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) drive_crear_remote;;
      2) [ -z "$remotes" ] && { err "No hay cuentas."; sleep 1; continue; }
         pedir n "Nombre de la cuenta"; drive_diagnostico "$n";;
      3) [ -z "$remotes" ] && { err "No hay cuentas."; sleep 1; continue; }
         pedir n "Nombre de la cuenta a eliminar"
         if si_no "Confirma eliminar '${n}'?"; then
           rclone config delete "$n" && ok "Eliminada."
           warn "Los trabajos que la usaban dejaran de funcionar."
         fi; enter;;
      4) clear; rclone config; enter;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

# ==================== GENERADORES DE SCRIPT ==========================
# Escribe el script en un archivo nuevo, comprueba su sintaxis y solo
# entonces lo pone en su lugar, de una sola vez. Si en ese momento hay un
# respaldo corriendo con el script anterior, sigue leyendo el archivo
# viejo hasta terminar: sobrescribirlo en el mismo lugar podria cortarlo
# a la mitad. Si algo falla, el script anterior queda intacto.
instalar_script() {   # instalar_script <generador> <archivo .conf> <script>
  local tmp="${3}.nuevo.$$"
  "$1" "$2" "$tmp" 2>/dev/null && [ -s "$tmp" ] && bash -n "$tmp" 2>/dev/null \
    && chmod 750 "$tmp" && mv -f "$tmp" "$3" && return 0
  rm -f "$tmp"
  return 1
}

generar_script_red() {
  cat > "$2" <<EOF
#!/usr/bin/env bash
# Generado por iZone ENTERPRISE - BACKUPS  -  destino: Unidad de Red (CIFS)
# La configuracion vive en el .conf; no edite valores aqui.
#
# Codigos de salida:
#   0 correcto   1 entorno o rutas   2 fallo 'bench backup'
#   3 fallo la copia   5 bench no dejo archivos   6 respaldo danado
CONF="$1"
EOF
  cat >> "$2" <<'EOF'
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -r "$CONF" ] || { echo "[ERROR] No se encuentra la configuracion: $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

# ---------------------------------------------------------------------
#  Registro y estado
# ---------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ULTIMO_BYTES_NUEVO=""

# Lee una clave del archivo de estado de este trabajo.
estado_valor() {   # estado_valor <CLAVE>
  [ -n "${ESTADO_FILE:-}" ] && [ -r "$ESTADO_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ESTADO_FILE" | tail -n 1
}

# Deja constancia de como termino esta ejecucion. ULTIMO_OK solo se mueve
# cuando el respaldo fue bueno, asi que siempre se puede responder
# "cuando fue la ultima vez que hubo un respaldo sano".
estado_escribir() {   # estado_escribir <OK|AVISO|FALLO> <codigo> <detalle> [destino]
  [ -n "${ESTADO_FILE:-}" ] || return 0
  local ok_previo bytes_previo ahora
  ahora="$(date '+%Y-%m-%d %H:%M:%S')"
  ok_previo="$(estado_valor ULTIMO_OK)"
  bytes_previo="$(estado_valor ULTIMO_BYTES)"
  [ "$1" = "OK" ] && ok_previo="$ahora"
  [ "$1" != "FALLO" ] && [ -n "$ULTIMO_BYTES_NUEVO" ] && bytes_previo="$ULTIMO_BYTES_NUEVO"
  mkdir -p "$(dirname "$ESTADO_FILE")" 2>/dev/null
  {
    echo "ULTIMO_ESTADO=$1"
    echo "ULTIMO_CODIGO=$2"
    echo "ULTIMO_DETALLE=$3"
    echo "ULTIMO_FIN=$ahora"
    echo "ULTIMO_OK=$ok_previo"
    echo "ULTIMO_BYTES=$bytes_previo"
    echo "ULTIMO_DESTINO=${4:-}"
  } > "$ESTADO_FILE" 2>/dev/null
  chmod 640 "$ESTADO_FILE" 2>/dev/null
  return 0
}

# Unica salida del script: siempre deja escrito el estado.
salir() {   # salir <codigo> <OK|AVISO|FALLO> <detalle> [destino]
  estado_escribir "$2" "$1" "$3" "${4:-}"
  case "$2" in
    OK)    log "[OK] $3";;
    AVISO) log "[AVISO] $3";;
    *)     log "[ERROR] $3";;
  esac
  exit "$1"
}

# Suma en bytes de los archivos regulares de una carpeta. Se usa find y no
# 'du' porque el tamano que du atribuye a los directorios cambia entre un
# disco local y un recurso CIFS, y eso daria diferencias falsas.
bytes_de() { find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

# ---------------------------------------------------------------------
#  Verificacion del respaldo recien creado
#  Devuelve 0 correcto - 1 danado - 2 correcto pero con avisos
# ---------------------------------------------------------------------
verificar_respaldo() {   # verificar_respaldo <carpeta> <si|rapida|no>
  local dir="$1" nivel="${2:-si}" f tam hay_sql=0 aviso=0 previo ahora_b

  if [ "$nivel" = "no" ]; then
    log "[AVISO] La verificacion esta desactivada para este trabajo."
    ULTIMO_BYTES_NUEVO="$(bytes_de "$dir")"
    return 0
  fi

  # 1. El volcado de la base de datos es obligatorio: sin el, no hay respaldo.
  for f in "$dir"/*.sql.gz; do
    [ -e "$f" ] || continue
    hay_sql=1
    tam="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    if [ "$tam" -lt 10240 ]; then
      log "[ERROR] Verificacion: $(basename "$f") pesa solo ${tam} bytes."
      return 1
    fi
    # 1a. El contenedor gzip esta completo.
    if ! gzip -t "$f" 2>/dev/null; then
      log "[ERROR] Verificacion: $(basename "$f") esta corrupto (gzip no puede abrirlo)."
      return 1
    fi
    # 1b. Y el volcado llega hasta el final. Esto es lo que de verdad importa:
    #     si mysqldump muere a la mitad, gzip recibe fin de entrada y cierra
    #     un archivo .gz perfectamente valido que contiene un SQL incompleto.
    #     El unico rastro es que falte la marca de cierre.
    if ! gzip -dc "$f" 2>/dev/null | tail -c 4000 \
         | grep -qE -- "-- Dump completed|UNLOCK TABLES;|^COMMIT;"; then
      log "[ERROR] Verificacion: $(basename "$f") termina a la mitad."
      log "        El volcado quedo incompleto; no sirve para restaurar."
      return 1
    fi
  done
  if [ "$hay_sql" -eq 0 ]; then
    log "[ERROR] Verificacion: no hay ningun volcado .sql.gz en $dir"
    return 1
  fi

  # 2. Los archivos adjuntos, si se incluyeron.
  for f in "$dir"/*.tar; do
    [ -e "$f" ] || continue
    tam="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    if [ "$nivel" = "rapida" ] && [ "$tam" -gt 2147483648 ]; then
      # En modo rapido, sobre un tar enorme se comprueba solo el cierre
      # (un tar termina en bloques de ceros) en vez de recorrerlo entero.
      if [ "$(tail -c 1024 "$f" 2>/dev/null | tr -d '\0' | wc -c)" -ne 0 ]; then
        log "[ERROR] Verificacion: $(basename "$f") no termina correctamente (truncado)."
        return 1
      fi
    else
      if ! tar -tf "$f" >/dev/null 2>&1; then
        log "[ERROR] Verificacion: $(basename "$f") esta corrupto (tar no puede leerlo)."
        return 1
      fi
    fi
  done

  # 3. La configuracion del sitio que acompana al respaldo.
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    [ -s "$f" ] || { log "[ERROR] Verificacion: $(basename "$f") esta vacio."; return 1; }
  done

  # 4. Comparacion con el ultimo respaldo bueno. No invalida nada: avisa.
  #    Un respaldo que de pronto pesa la mitad suele significar que se
  #    perdieron datos en origen, no que la copia fallara.
  ahora_b="$(bytes_de "$dir")"
  ULTIMO_BYTES_NUEVO="$ahora_b"
  previo="$(estado_valor ULTIMO_BYTES)"
  if [ -n "$previo" ] && [ "$previo" -gt 0 ] 2>/dev/null; then
    if [ "$((ahora_b * 2))" -lt "$previo" ]; then
      log "[AVISO] Este respaldo pesa ${ahora_b} bytes; el anterior pesaba ${previo}."
      log "        Menos de la mitad. Revise que no se hayan perdido datos en el sitio."
      aviso=1
    fi
  fi

  log "[OK] Verificacion superada: el respaldo se puede abrir y esta completo."
  [ "$aviso" -eq 1 ] && return 2
  return 0
}

# Huella de cada archivo, para poder comprobar el respaldo el dia de la
# restauracion con:  sha256sum -c SHA256SUMS
escribir_huellas() {   # escribir_huellas <carpeta>
  ( cd "$1" 2>/dev/null || exit 0
    : > SHA256SUMS
    for f in *; do
      [ -f "$f" ] && [ "$f" != "SHA256SUMS" ] && sha256sum "$f" >> SHA256SUMS
    done ) 2>/dev/null
  return 0
}

# Retencion por niveles sobre carpetas <base>/<dd-mes-aaaa>
retencion_niveles_local() {
  local base="$1" dias="$2" mensual="$3" meses="$4"
  [ "${dias:-0}" -gt 0 ] 2>/dev/null || return 0
  local ahora ym_hoy d nombre ts ym edad dif
  declare -A pri_ts pri_dir
  ahora="$(date +%s)"
  ym_hoy=$(( $(date +%Y) * 12 + 10#$(date +%m) ))

  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    nombre="$(basename "$d")"
    ts="$(LC_ALL=C date -d "${nombre//-/ }" +%s 2>/dev/null)" || continue
    [ -n "$ts" ] || continue
    ym="$(date -d "@$ts" +%Y-%m)"
    if [ -z "${pri_ts[$ym]:-}" ] || [ "$ts" -lt "${pri_ts[$ym]}" ]; then
      pri_ts[$ym]="$ts"; pri_dir[$ym]="$nombre"
    fi
  done

  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    nombre="$(basename "$d")"
    ts="$(LC_ALL=C date -d "${nombre//-/ }" +%s 2>/dev/null)" || continue
    [ -n "$ts" ] || continue
    edad=$(( (ahora - ts) / 86400 ))
    [ "$edad" -le "$dias" ] && continue
    if [ "$mensual" = "si" ]; then
      ym="$(date -d "@$ts" +%Y-%m)"
      if [ "${pri_dir[$ym]:-}" = "$nombre" ]; then
        [ "${meses:-0}" -eq 0 ] && continue
        dif=$(( ym_hoy - ( $(date -d "@$ts" +%Y) * 12 + 10#$(date -d "@$ts" +%m) ) ))
        [ "$dif" -lt "$meses" ] && continue
      fi
    fi
    rm -rf "$d" && log "[INFO] Retencion: eliminado $nombre"
  done
}

FECHA="$(date +'%d-%B-%Y' | tr '[:upper:]' '[:lower:]')"
HORA="$(date +'%H-%M')"
DESTINO_FINAL="${MOUNT_POINT}/${FECHA}/${HORA}"

log "[INFO] Inicio del respaldo de '${SITE}' hacia ${MOUNT_POINT}"

# ---- 1. El destino tiene que estar montado ---------------------------
if ! mountpoint -q "$MOUNT_POINT"; then
  log "[AVISO] $MOUNT_POINT no esta montado. Intentando montar..."
  mount "$MOUNT_POINT" >/dev/null 2>&1
fi
mountpoint -q "$MOUNT_POINT" || \
  salir 1 FALLO "$MOUNT_POINT no esta montado. No se creo ningun respaldo."

# ---- 2. Crear el respaldo -------------------------------------------
cd "$BENCH_PATH" || salir 1 FALLO "No existe el bench: $BENCH_PATH"
# shellcheck disable=SC1091
. env/bin/activate
BENCH_ARGS=(--site "$SITE" backup)
[ "${WITH_FILES:-si}" = "si" ] && BENCH_ARGS+=(--with-files)
# La salida de bench se guarda: si falla, es lo unico que explica por que.
SALIDA_BENCH="$(bench "${BENCH_ARGS[@]}" 2>&1)" || {
  printf '%s\n' "$SALIDA_BENCH" | tail -n 15
  salir 2 FALLO "'bench backup' fallo para $SITE"
}

# Que bench devuelva 0 no garantiza que dejara archivos.
if [ ! -d "$BACKUP_ORIGEN" ] || [ -z "$(ls -A "$BACKUP_ORIGEN" 2>/dev/null)" ]; then
  salir 5 FALLO "bench no dejo ningun archivo en $BACKUP_ORIGEN"
fi

# ---- 3. Verificar ANTES de copiar y ANTES de borrar nada -------------
verificar_respaldo "$BACKUP_ORIGEN" "${VERIFICAR:-si}"; VERIF=$?
if [ "$VERIF" -eq 1 ]; then
  salir 6 FALLO "El respaldo recien creado esta danado. Se conserva en ${BACKUP_ORIGEN} y no se toco el destino ni la retencion."
fi
[ "${VERIFICAR:-si}" = "no" ] || escribir_huellas "$BACKUP_ORIGEN"

# ---- 4. Copiar (rsync verifica cada archivo con checksum) ------------
mkdir -p "$DESTINO_FINAL" || salir 1 FALLO "No se pudo crear $DESTINO_FINAL"
rsync -a "${BACKUP_ORIGEN}/" "${DESTINO_FINAL}/" || \
  salir 3 FALLO "Fallo la copia hacia $DESTINO_FINAL" "$DESTINO_FINAL"

# ---- 5. Confirmar que llego todo ------------------------------------
# Se comparan uno por uno los archivos que acabamos de copiar, en vez de
# los totales de la carpeta: si por lo que fuera ya hubiera algo en el
# destino -dos respaldos en el mismo minuto, restos de una corrida
# anterior- un conteo global daria un fallo falso, y una alarma falsa
# termina haciendo que nadie mire las alarmas.
FALTAN=0; N_COP=0; B_COP=0
while IFS= read -r ARCH; do
  REL="${ARCH#"$BACKUP_ORIGEN"/}"
  COPIA="${DESTINO_FINAL}/${REL}"
  if [ ! -f "$COPIA" ]; then
    log "[ERROR] No llego al destino: ${REL}"
    FALTAN=$((FALTAN+1)); continue
  fi
  T_ORI="$(stat -c '%s' "$ARCH"  2>/dev/null || echo -1)"
  T_DES="$(stat -c '%s' "$COPIA" 2>/dev/null || echo -2)"
  if [ "$T_ORI" != "$T_DES" ]; then
    log "[ERROR] Llego incompleto: ${REL} (${T_ORI} bytes en origen, ${T_DES} en destino)"
    FALTAN=$((FALTAN+1)); continue
  fi
  N_COP=$((N_COP+1)); B_COP=$((B_COP+T_ORI))
done < <(find "$BACKUP_ORIGEN" -type f 2>/dev/null)

if [ "$FALTAN" -gt 0 ]; then
  salir 3 FALLO "${FALTAN} archivo(s) no llegaron bien a ${DESTINO_FINAL}. No se borro nada del origen." "$DESTINO_FINAL"
fi
if [ "$N_COP" -eq 0 ]; then
  salir 3 FALLO "No se copio ningun archivo a ${DESTINO_FINAL}." "$DESTINO_FINAL"
fi
log "[OK] Respaldo copiado en $DESTINO_FINAL (${N_COP} archivos, ${B_COP} bytes)"

# ---- 5b. Comprobacion profunda: releer desde el destino --------------
# rsync ya comprobo cada archivo con checksum al transferirlo. Esto va un
# paso mas alla: vuelve a LEER el respaldo desde el recurso de red y
# recalcula las huellas. Cuesta leer el respaldo entero por la red, por
# eso es opcional.
if [ "${VERIFICAR_DESTINO:-basico}" = "completo" ] && [ -f "${DESTINO_FINAL}/SHA256SUMS" ]; then
  log "[INFO] Releyendo el respaldo desde el destino para comprobar las huellas..."
  if ( cd "$DESTINO_FINAL" && sha256sum -c SHA256SUMS ) >/dev/null 2>&1; then
    log "[OK] Las huellas coinciden leyendo desde el destino."
  else
    salir 3 FALLO "Al releer desde ${DESTINO_FINAL} las huellas no coinciden. No se borro nada del origen." "$DESTINO_FINAL"
  fi
fi

# ---- 6. Recien ahora se libera el disco local ------------------------
find "$BACKUP_ORIGEN" -mindepth 1 -type f -delete 2>/dev/null
find "$BACKUP_ORIGEN" -mindepth 1 -type d -empty -delete 2>/dev/null

# ---- 7. Retencion: solo despues de un respaldo bueno -----------------
retencion_niveles_local "$MOUNT_POINT" "${RETENCION_DIAS:-0}" \
  "${MENSUAL_CONSERVAR:-no}" "${MENSUAL_MESES:-0}"

if [ "$VERIF" -eq 2 ]; then
  salir 0 AVISO "Respaldo correcto en ${DESTINO_FINAL}, pero mucho mas pequeno que el anterior." "$DESTINO_FINAL"
fi
salir 0 OK "Respaldo verificado en ${DESTINO_FINAL}" "$DESTINO_FINAL"
EOF
  chmod 750 "$2"
}

generar_script_drive() {
  cat > "$2" <<EOF
#!/usr/bin/env bash
# Generado por iZone ENTERPRISE - BACKUPS  -  destino: Google Drive (rclone)
# La configuracion vive en el .conf; no edite valores aqui.
#
# Codigos de salida:
#   0 correcto   1 entorno o rutas   2 fallo 'bench backup'
#   3 fallo la copia local   4 fallo la subida o la verificacion en Drive
#   5 bench no dejo archivos   6 respaldo danado
CONF="$1"
EOF
  cat >> "$2" <<'EOF'
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -r "$CONF" ] || { echo "[ERROR] No se encuentra la configuracion: $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
export RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"

# ---------------------------------------------------------------------
#  Registro y estado
# ---------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ULTIMO_BYTES_NUEVO=""

# Lee una clave del archivo de estado de este trabajo.
estado_valor() {   # estado_valor <CLAVE>
  [ -n "${ESTADO_FILE:-}" ] && [ -r "$ESTADO_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ESTADO_FILE" | tail -n 1
}

# Deja constancia de como termino esta ejecucion. ULTIMO_OK solo se mueve
# cuando el respaldo fue bueno, asi que siempre se puede responder
# "cuando fue la ultima vez que hubo un respaldo sano".
estado_escribir() {   # estado_escribir <OK|AVISO|FALLO> <codigo> <detalle> [destino]
  [ -n "${ESTADO_FILE:-}" ] || return 0
  local ok_previo bytes_previo ahora
  ahora="$(date '+%Y-%m-%d %H:%M:%S')"
  ok_previo="$(estado_valor ULTIMO_OK)"
  bytes_previo="$(estado_valor ULTIMO_BYTES)"
  [ "$1" = "OK" ] && ok_previo="$ahora"
  [ "$1" != "FALLO" ] && [ -n "$ULTIMO_BYTES_NUEVO" ] && bytes_previo="$ULTIMO_BYTES_NUEVO"
  mkdir -p "$(dirname "$ESTADO_FILE")" 2>/dev/null
  {
    echo "ULTIMO_ESTADO=$1"
    echo "ULTIMO_CODIGO=$2"
    echo "ULTIMO_DETALLE=$3"
    echo "ULTIMO_FIN=$ahora"
    echo "ULTIMO_OK=$ok_previo"
    echo "ULTIMO_BYTES=$bytes_previo"
    echo "ULTIMO_DESTINO=${4:-}"
  } > "$ESTADO_FILE" 2>/dev/null
  chmod 640 "$ESTADO_FILE" 2>/dev/null
  return 0
}

# Unica salida del script: siempre deja escrito el estado.
salir() {   # salir <codigo> <OK|AVISO|FALLO> <detalle> [destino]
  estado_escribir "$2" "$1" "$3" "${4:-}"
  case "$2" in
    OK)    log "[OK] $3";;
    AVISO) log "[AVISO] $3";;
    *)     log "[ERROR] $3";;
  esac
  exit "$1"
}

# Suma en bytes de los archivos regulares de una carpeta. Se usa find y no
# 'du' porque el tamano que du atribuye a los directorios cambia entre un
# disco local y un recurso CIFS, y eso daria diferencias falsas.
bytes_de() { find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

# ---------------------------------------------------------------------
#  Verificacion del respaldo recien creado
#  Devuelve 0 correcto - 1 danado - 2 correcto pero con avisos
# ---------------------------------------------------------------------
verificar_respaldo() {   # verificar_respaldo <carpeta> <si|rapida|no>
  local dir="$1" nivel="${2:-si}" f tam hay_sql=0 aviso=0 previo ahora_b

  if [ "$nivel" = "no" ]; then
    log "[AVISO] La verificacion esta desactivada para este trabajo."
    ULTIMO_BYTES_NUEVO="$(bytes_de "$dir")"
    return 0
  fi

  # 1. El volcado de la base de datos es obligatorio: sin el, no hay respaldo.
  for f in "$dir"/*.sql.gz; do
    [ -e "$f" ] || continue
    hay_sql=1
    tam="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    if [ "$tam" -lt 10240 ]; then
      log "[ERROR] Verificacion: $(basename "$f") pesa solo ${tam} bytes."
      return 1
    fi
    # 1a. El contenedor gzip esta completo.
    if ! gzip -t "$f" 2>/dev/null; then
      log "[ERROR] Verificacion: $(basename "$f") esta corrupto (gzip no puede abrirlo)."
      return 1
    fi
    # 1b. Y el volcado llega hasta el final. Esto es lo que de verdad importa:
    #     si mysqldump muere a la mitad, gzip recibe fin de entrada y cierra
    #     un archivo .gz perfectamente valido que contiene un SQL incompleto.
    #     El unico rastro es que falte la marca de cierre.
    if ! gzip -dc "$f" 2>/dev/null | tail -c 4000 \
         | grep -qE -- "-- Dump completed|UNLOCK TABLES;|^COMMIT;"; then
      log "[ERROR] Verificacion: $(basename "$f") termina a la mitad."
      log "        El volcado quedo incompleto; no sirve para restaurar."
      return 1
    fi
  done
  if [ "$hay_sql" -eq 0 ]; then
    log "[ERROR] Verificacion: no hay ningun volcado .sql.gz en $dir"
    return 1
  fi

  # 2. Los archivos adjuntos, si se incluyeron.
  for f in "$dir"/*.tar; do
    [ -e "$f" ] || continue
    tam="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    if [ "$nivel" = "rapida" ] && [ "$tam" -gt 2147483648 ]; then
      # En modo rapido, sobre un tar enorme se comprueba solo el cierre
      # (un tar termina en bloques de ceros) en vez de recorrerlo entero.
      if [ "$(tail -c 1024 "$f" 2>/dev/null | tr -d '\0' | wc -c)" -ne 0 ]; then
        log "[ERROR] Verificacion: $(basename "$f") no termina correctamente (truncado)."
        return 1
      fi
    else
      if ! tar -tf "$f" >/dev/null 2>&1; then
        log "[ERROR] Verificacion: $(basename "$f") esta corrupto (tar no puede leerlo)."
        return 1
      fi
    fi
  done

  # 3. La configuracion del sitio que acompana al respaldo.
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    [ -s "$f" ] || { log "[ERROR] Verificacion: $(basename "$f") esta vacio."; return 1; }
  done

  # 4. Comparacion con el ultimo respaldo bueno. No invalida nada: avisa.
  #    Un respaldo que de pronto pesa la mitad suele significar que se
  #    perdieron datos en origen, no que la copia fallara.
  ahora_b="$(bytes_de "$dir")"
  ULTIMO_BYTES_NUEVO="$ahora_b"
  previo="$(estado_valor ULTIMO_BYTES)"
  if [ -n "$previo" ] && [ "$previo" -gt 0 ] 2>/dev/null; then
    if [ "$((ahora_b * 2))" -lt "$previo" ]; then
      log "[AVISO] Este respaldo pesa ${ahora_b} bytes; el anterior pesaba ${previo}."
      log "        Menos de la mitad. Revise que no se hayan perdido datos en el sitio."
      aviso=1
    fi
  fi

  log "[OK] Verificacion superada: el respaldo se puede abrir y esta completo."
  [ "$aviso" -eq 1 ] && return 2
  return 0
}

# Huella de cada archivo, para poder comprobar el respaldo el dia de la
# restauracion con:  sha256sum -c SHA256SUMS
escribir_huellas() {   # escribir_huellas <carpeta>
  ( cd "$1" 2>/dev/null || exit 0
    : > SHA256SUMS
    for f in *; do
      [ -f "$f" ] && [ "$f" != "SHA256SUMS" ] && sha256sum "$f" >> SHA256SUMS
    done ) 2>/dev/null
  return 0
}

# Retencion por niveles sobre <remoto>/<dd-mes-aaaa>
retencion_niveles_drive() {
  local remoto="$1" dias="$2" mensual="$3" meses="$4"
  [ "${dias:-0}" -gt 0 ] 2>/dev/null || return 0
  local ahora ym_hoy nombre ts ym edad dif dirs=()
  declare -A pri_ts pri_dir
  ahora="$(date +%s)"
  ym_hoy=$(( $(date +%Y) * 12 + 10#$(date +%m) ))
  mapfile -t dirs < <(rclone lsf "$remoto" --dirs-only 2>/dev/null | sed 's:/$::')

  for nombre in "${dirs[@]}"; do
    ts="$(LC_ALL=C date -d "${nombre//-/ }" +%s 2>/dev/null)" || continue
    [ -n "$ts" ] || continue
    ym="$(date -d "@$ts" +%Y-%m)"
    if [ -z "${pri_ts[$ym]:-}" ] || [ "$ts" -lt "${pri_ts[$ym]}" ]; then
      pri_ts[$ym]="$ts"; pri_dir[$ym]="$nombre"
    fi
  done

  for nombre in "${dirs[@]}"; do
    ts="$(LC_ALL=C date -d "${nombre//-/ }" +%s 2>/dev/null)" || continue
    [ -n "$ts" ] || continue
    edad=$(( (ahora - ts) / 86400 ))
    [ "$edad" -le "$dias" ] && continue
    if [ "$mensual" = "si" ]; then
      ym="$(date -d "@$ts" +%Y-%m)"
      if [ "${pri_dir[$ym]:-}" = "$nombre" ]; then
        [ "${meses:-0}" -eq 0 ] && continue
        dif=$(( ym_hoy - ( $(date -d "@$ts" +%Y) * 12 + 10#$(date -d "@$ts" +%m) ) ))
        [ "$dif" -lt "$meses" ] && continue
      fi
    fi
    rclone purge "${remoto}/${nombre}" >/dev/null 2>&1 && log "[INFO] Retencion: eliminado $nombre"
  done
}

FECHA="$(date +'%d-%B-%Y' | tr '[:upper:]' '[:lower:]')"
HORA="$(date +'%H-%M')"
DESTINO="${RCLONE_REMOTE}:${DEST_PATH}/${FECHA}/${HORA}"

log "[INFO] Inicio del respaldo de '${SITE}' hacia ${RCLONE_REMOTE}:${DEST_PATH}"

# ---- 1. Carpeta temporal limpia -------------------------------------
mkdir -p "$TEMP_LOCAL" || salir 1 FALLO "No se pudo crear $TEMP_LOCAL"
rm -rf "${TEMP_LOCAL:?}"/*

# ---- 2. Crear el respaldo -------------------------------------------
cd "$BENCH_PATH" || salir 1 FALLO "No existe el bench: $BENCH_PATH"
# shellcheck disable=SC1091
. env/bin/activate
BENCH_ARGS=(--site "$SITE" backup)
[ "${WITH_FILES:-si}" = "si" ] && BENCH_ARGS+=(--with-files)
SALIDA_BENCH="$(bench "${BENCH_ARGS[@]}" 2>&1)" || {
  printf '%s\n' "$SALIDA_BENCH" | tail -n 15
  salir 2 FALLO "'bench backup' fallo para $SITE"
}

if [ ! -d "$BACKUP_ORIGEN" ] || [ -z "$(ls -A "$BACKUP_ORIGEN" 2>/dev/null)" ]; then
  salir 5 FALLO "bench no dejo ningun archivo en $BACKUP_ORIGEN"
fi

# ---- 3. Verificar ANTES de subir y ANTES de borrar nada --------------
verificar_respaldo "$BACKUP_ORIGEN" "${VERIFICAR:-si}"; VERIF=$?
if [ "$VERIF" -eq 1 ]; then
  salir 6 FALLO "El respaldo recien creado esta danado. Se conserva en ${BACKUP_ORIGEN} y no se subio nada."
fi
[ "${VERIFICAR:-si}" = "no" ] || escribir_huellas "$BACKUP_ORIGEN"

# ---- 4. Armar el paquete y subirlo ----------------------------------
cp -r "$BACKUP_ORIGEN"/* "$TEMP_LOCAL"/ || salir 3 FALLO "No se pudo copiar a $TEMP_LOCAL"

if ! rclone copy "$TEMP_LOCAL" "$DESTINO" \
     --contimeout 30s --timeout 5m --retries 3 --low-level-retries 10 \
     --log-file="$RCLONE_LOG" --log-level INFO; then
  rm -rf "${TEMP_LOCAL:?}"/*
  salir 4 FALLO "Fallo la subida hacia $DESTINO" "$DESTINO"
fi

# ---- 5. Comprobar que lo que quedo en Drive sea lo que se subio ------
# Devuelve 0 si coincide, 1 si hay diferencias o si no se pudo comprobar.
comprobar_en_drive() {   # comprobar_en_drive <carpeta local> <destino>
  local extra=() salida est sin_hash l
  [ "${VERIFICAR_DESTINO:-hash}" = "descarga" ] && extra=(--download)
  salida="$(rclone check "$1" "$2" --one-way "${extra[@]:+${extra[@]}}" \
              --contimeout 30s --timeout 5m --retries 2 2>&1)"; est=$?
  printf '%s\n' "$salida" >> "$RCLONE_LOG" 2>/dev/null

  if [ "$est" -ne 0 ]; then
    printf '%s\n' "$salida" | grep -Ei "differ|missing|not in|error" | head -n 5 \
      | while IFS= read -r l; do log "        $l"; done
    return 1
  fi

  # Si rclone no pudo obtener el hash de algun archivo, para ese archivo
  # solo comparo tamanos, y un archivo danado del mismo tamano pasaria
  # inadvertido. Comprobado: con comparacion por tamano, un archivo
  # corrupto del mismo peso devuelve 0. Asi que esto NO se deja pasar.
  sin_hash="$(printf '%s' "$salida" \
    | sed -nE 's/.*[^0-9]([0-9]+) hashes could not be checked.*/\1/p' | tail -n 1)"
  if [ -n "$sin_hash" ] && [ "$sin_hash" -gt 0 ] 2>/dev/null; then
    log "[ERROR] Google no devolvio el hash de ${sin_hash} archivo(s)."
    log "        Solo se pudo comparar el tamano, y eso no prueba que el"
    log "        contenido este bien. Se trata como fallo a proposito."
    return 1
  fi
  return 0
}

INTENTO=1
while :; do
  if [ "${VERIFICAR_DESTINO:-hash}" = "descarga" ]; then
    log "[INFO] Comprobando en Drive: se descarga de vuelta y se compara byte a byte..."
  else
    log "[INFO] Comprobando en Drive: se comparan los hashes que reporta Google..."
  fi
  comprobar_en_drive "$TEMP_LOCAL" "$DESTINO" && break

  if [ "$INTENTO" -ge 2 ]; then
    rm -rf "${TEMP_LOCAL:?}"/*
    salir 4 FALLO "Lo que quedo en ${DESTINO} no coincide con lo que se subio, ni siquiera tras resubirlo. El respaldo local NO se borro." "$DESTINO"
  fi
  # Esto es lo que usted haria a mano: borrar lo que quedo mal y subirlo
  # otra vez. Se hace aqui mismo, mientras el respaldo local todavia existe.
  log "[AVISO] La copia en Drive no coincide. Se borra y se sube de nuevo."
  rclone purge "$DESTINO" >/dev/null 2>&1
  if ! rclone copy "$TEMP_LOCAL" "$DESTINO" \
       --contimeout 30s --timeout 5m --retries 3 --low-level-retries 10 \
       --log-file="$RCLONE_LOG" --log-level INFO; then
    rm -rf "${TEMP_LOCAL:?}"/*
    salir 4 FALLO "Fallo el reintento de subida hacia ${DESTINO}. El respaldo local NO se borro." "$DESTINO"
  fi
  INTENTO=2
done
log "[OK] Comprobado en Drive: lo que quedo alla es identico a lo que se subio."

# ---- 6. Recien ahora se libera el disco local ------------------------
if [ "${BORRAR_ORIGEN:-si}" = "si" ]; then
  find "$BACKUP_ORIGEN" -mindepth 1 -type f -delete 2>/dev/null
fi
rm -rf "${TEMP_LOCAL:?}"/*

# ---- 7. Retencion: solo despues de un respaldo bueno -----------------
retencion_niveles_drive "${RCLONE_REMOTE}:${DEST_PATH}" "${RETENCION_DIAS:-0}" \
  "${MENSUAL_CONSERVAR:-no}" "${MENSUAL_MESES:-0}"

if [ "$VERIF" -eq 2 ]; then
  salir 0 AVISO "Respaldo correcto en ${DESTINO}, pero mucho mas pequeno que el anterior." "$DESTINO"
fi
salir 0 OK "Respaldo verificado en ${DESTINO}" "$DESTINO"
EOF
  chmod 750 "$2"
}


generar_script_red_rclone() {
  cat > "$2" <<EOF
#!/usr/bin/env bash
# Generado por iZone ENTERPRISE - BACKUPS  -  destino: Unidad de Red por rclone (sin montaje)
# La configuracion vive en el .conf; no edite valores aqui.
#
# Este camino se usa cuando el servidor no puede montar carpetas de red,
# por ejemplo un contenedor LXC sin privilegios. rclone habla SMB directo
# con el NAS: no se monta nada y no se toca /etc/fstab.
#
# Codigos de salida:
#   0 correcto   1 entorno, rutas o espacio   2 fallo 'bench backup'
#   3 fallo el envio o la comprobacion en el NAS   5 bench no dejo archivos
#   6 respaldo danado   7 otra ejecucion de este trabajo sigue en curso
CONF="$1"
EOF
  cat >> "$2" <<'EOF'
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
umask 027
[ -r "$CONF" ] || { echo "[ERROR] No se encuentra la configuracion: $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

# ---------------------------------------------------------------------
#  Registro y estado
# ---------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ULTIMO_BYTES_NUEVO=""

# Lee una clave del archivo de estado de este trabajo.
estado_valor() {   # estado_valor <CLAVE>
  [ -n "${ESTADO_FILE:-}" ] && [ -r "$ESTADO_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ESTADO_FILE" | tail -n 1
}

# Deja constancia de como termino esta ejecucion. ULTIMO_OK solo se mueve
# cuando el respaldo fue bueno, asi que siempre se puede responder
# "cuando fue la ultima vez que hubo un respaldo sano".
estado_escribir() {   # estado_escribir <OK|AVISO|FALLO> <codigo> <detalle> [destino]
  [ -n "${ESTADO_FILE:-}" ] || return 0
  local ok_previo bytes_previo ahora
  ahora="$(date '+%Y-%m-%d %H:%M:%S')"
  ok_previo="$(estado_valor ULTIMO_OK)"
  bytes_previo="$(estado_valor ULTIMO_BYTES)"
  [ "$1" = "OK" ] && ok_previo="$ahora"
  [ "$1" != "FALLO" ] && [ -n "$ULTIMO_BYTES_NUEVO" ] && bytes_previo="$ULTIMO_BYTES_NUEVO"
  mkdir -p "$(dirname "$ESTADO_FILE")" 2>/dev/null
  {
    echo "ULTIMO_ESTADO=$1"
    echo "ULTIMO_CODIGO=$2"
    echo "ULTIMO_DETALLE=$3"
    echo "ULTIMO_FIN=$ahora"
    echo "ULTIMO_OK=$ok_previo"
    echo "ULTIMO_BYTES=$bytes_previo"
    echo "ULTIMO_DESTINO=${4:-}"
  } > "$ESTADO_FILE" 2>/dev/null
  chmod 640 "$ESTADO_FILE" 2>/dev/null
  return 0
}

# Unica salida del script: siempre deja escrito el estado.
salir() {   # salir <codigo> <OK|AVISO|FALLO> <detalle> [destino]
  estado_escribir "$2" "$1" "$3" "${4:-}"
  case "$2" in
    OK)    log "[OK] $3";;
    AVISO) log "[AVISO] $3";;
    *)     log "[ERROR] $3";;
  esac
  exit "$1"
}

# Suma en bytes de los archivos regulares de una carpeta. Se usa find y no
# 'du' porque el tamano que du atribuye a los directorios cambia entre un
# disco local y un recurso CIFS, y eso daria diferencias falsas.
bytes_de() { find "$1" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}'; }

# ---------------------------------------------------------------------
#  Verificacion del respaldo recien creado
#  Devuelve 0 correcto - 1 danado - 2 correcto pero con avisos
# ---------------------------------------------------------------------
verificar_respaldo() {   # verificar_respaldo <carpeta> <si|rapida|no>
  local dir="$1" nivel="${2:-si}" f tam hay_sql=0 aviso=0 previo ahora_b

  if [ "$nivel" = "no" ]; then
    log "[AVISO] La verificacion esta desactivada para este trabajo."
    ULTIMO_BYTES_NUEVO="$(bytes_de "$dir")"
    return 0
  fi

  # 1. El volcado de la base de datos es obligatorio: sin el, no hay respaldo.
  for f in "$dir"/*.sql.gz; do
    [ -e "$f" ] || continue
    hay_sql=1
    tam="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    if [ "$tam" -lt 10240 ]; then
      log "[ERROR] Verificacion: $(basename "$f") pesa solo ${tam} bytes."
      return 1
    fi
    # 1a. El contenedor gzip esta completo.
    if ! gzip -t "$f" 2>/dev/null; then
      log "[ERROR] Verificacion: $(basename "$f") esta corrupto (gzip no puede abrirlo)."
      return 1
    fi
    # 1b. Y el volcado llega hasta el final. Esto es lo que de verdad importa:
    #     si mysqldump muere a la mitad, gzip recibe fin de entrada y cierra
    #     un archivo .gz perfectamente valido que contiene un SQL incompleto.
    #     El unico rastro es que falte la marca de cierre.
    if ! gzip -dc "$f" 2>/dev/null | tail -c 4000 \
         | grep -qE -- "-- Dump completed|UNLOCK TABLES;|^COMMIT;"; then
      log "[ERROR] Verificacion: $(basename "$f") termina a la mitad."
      log "        El volcado quedo incompleto; no sirve para restaurar."
      return 1
    fi
  done
  if [ "$hay_sql" -eq 0 ]; then
    log "[ERROR] Verificacion: no hay ningun volcado .sql.gz en $dir"
    return 1
  fi

  # 2. Los archivos adjuntos, si se incluyeron.
  for f in "$dir"/*.tar; do
    [ -e "$f" ] || continue
    tam="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    if [ "$nivel" = "rapida" ] && [ "$tam" -gt 2147483648 ]; then
      # En modo rapido, sobre un tar enorme se comprueba solo el cierre
      # (un tar termina en bloques de ceros) en vez de recorrerlo entero.
      if [ "$(tail -c 1024 "$f" 2>/dev/null | tr -d '\0' | wc -c)" -ne 0 ]; then
        log "[ERROR] Verificacion: $(basename "$f") no termina correctamente (truncado)."
        return 1
      fi
    else
      if ! tar -tf "$f" >/dev/null 2>&1; then
        log "[ERROR] Verificacion: $(basename "$f") esta corrupto (tar no puede leerlo)."
        return 1
      fi
    fi
  done

  # 3. La configuracion del sitio que acompana al respaldo.
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    [ -s "$f" ] || { log "[ERROR] Verificacion: $(basename "$f") esta vacio."; return 1; }
  done

  # 4. Comparacion con el ultimo respaldo bueno. No invalida nada: avisa.
  #    Un respaldo que de pronto pesa la mitad suele significar que se
  #    perdieron datos en origen, no que la copia fallara.
  ahora_b="$(bytes_de "$dir")"
  ULTIMO_BYTES_NUEVO="$ahora_b"
  previo="$(estado_valor ULTIMO_BYTES)"
  if [ -n "$previo" ] && [ "$previo" -gt 0 ] 2>/dev/null; then
    if [ "$((ahora_b * 2))" -lt "$previo" ]; then
      log "[AVISO] Este respaldo pesa ${ahora_b} bytes; el anterior pesaba ${previo}."
      log "        Menos de la mitad. Revise que no se hayan perdido datos en el sitio."
      aviso=1
    fi
  fi

  log "[OK] Verificacion superada: el respaldo se puede abrir y esta completo."
  [ "$aviso" -eq 1 ] && return 2
  return 0
}

# Huella de cada archivo, para poder comprobar el respaldo el dia de la
# restauracion con:  sha256sum -c SHA256SUMS
escribir_huellas() {   # escribir_huellas <carpeta>
  ( cd "$1" 2>/dev/null || exit 0
    : > SHA256SUMS
    for f in *; do
      [ -f "$f" ] && [ "$f" != "SHA256SUMS" ] && sha256sum "$f" >> SHA256SUMS
    done ) 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------
#  Conexion con el NAS por rclone (sin montaje)
# ---------------------------------------------------------------------
RC="${RCLONE_BIN:-rclone}"
NAS="izonenas"
NAS_RAIZ="${RECURSO}${SUBCARPETA:+/${SUBCARPETA}}"
RCLONE_LOG="${RCLONE_LOG:-/var/log/izone-backup/${JOB_NOMBRE}-rclone.log}"
DIR_TRABAJO="${DIR_TRABAJO:-/var/tmp/izone-backup/${JOB_NOMBRE}}"
EN_CURSO="${DIR_TRABAJO}/en-curso"
SUFIJO=".subiendo.${JOB_NOMBRE}"
GUARDADO=""
# RC_RED para enviar y comprobar; RC_RAPIDO para consultas que no deben colgarse.
RC_RED=(--contimeout 30s --timeout 5m --retries 3 --low-level-retries 10)
RC_RAPIDO=(--contimeout 20s --timeout 2m --retries 2 --low-level-retries 3)

# La contrasena vive solo en el .cred. La conexion se arma en variables de
# entorno de este proceso; no queda escrita en ningun archivo de rclone.
nas_preparar() {
  local u p d
  [ -r "${CRED_FILE:-}" ] || return 1
  u="$(sed -n 's/^username=//p' "$CRED_FILE" | head -n 1)"
  p="$(sed -n 's/^password=//p' "$CRED_FILE" | head -n 1)"
  d="$(sed -n 's/^domain=//p'   "$CRED_FILE" | head -n 1)"
  [ -n "$u" ] && [ -n "$p" ] || return 1
  export RCLONE_CONFIG_IZONENAS_TYPE="smb"
  export RCLONE_CONFIG_IZONENAS_HOST="$SERVIDOR"
  export RCLONE_CONFIG_IZONENAS_PORT="${SMB_PORT:-445}"
  export RCLONE_CONFIG_IZONENAS_USER="$u"
  export RCLONE_CONFIG_IZONENAS_DOMAIN="${d:-WORKGROUP}"
  RCLONE_CONFIG_IZONENAS_PASS="$(printf '%s' "$p" | "$RC" obscure - 2>/dev/null)"
  export RCLONE_CONFIG_IZONENAS_PASS
  [ -n "$RCLONE_CONFIG_IZONENAS_PASS" ]
}

# rclone con su salida en el log propio del trabajo
rcl() { "$RC" "$@" >>"$RCLONE_LOG" 2>&1; }

# 0 si en la carpeta caben <kb> y aun queda libre una reserva para que el
# sistema y la base de datos sigan trabajando. Detalle en ESPACIO_MSG.
espacio_suficiente() {   # espacio_suficiente <carpeta> <kb necesarios>
  local libre total reserva
  libre="$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}')"
  total="$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $2}')"
  if ! [[ "$libre" =~ ^[0-9]+$ ]] || ! [[ "$total" =~ ^[0-9]+$ ]]; then
    ESPACIO_MSG="no se pudo medir el espacio libre en $1"; return 1
  fi
  # 5% del disco, nunca menos de 2 GB ni mas de 10 GB
  reserva=$(( total / 20 ))
  [ "$reserva" -lt 2097152 ] && reserva=2097152
  [ "$reserva" -gt 10485760 ] && reserva=10485760
  ESPACIO_MSG="en $1 hay $(( libre / 1024 )) MB libres, el respaldo necesita unos $(( $2 / 1024 )) MB y se reservan $(( reserva / 1024 )) MB para que el servidor siga funcionando"
  [ $(( libre - $2 )) -ge "$reserva" ]
}

# Guarda la copia local de una ejecucion fallida y descarta las de fallos
# anteriores del mismo tipo. Queda solo la mas reciente: una racha de
# fallos no puede llenar el disco del servidor.
conservar_local() {   # conservar_local <pendiente|danado>
  local d
  for d in "${DIR_TRABAJO}/$1-"*; do
    [ -d "$d" ] && rm -rf "$d"
  done
  GUARDADO="${DIR_TRABAJO}/$1-${SELLO}"
  mv "$EN_CURSO" "$GUARDADO" 2>/dev/null || GUARDADO="$EN_CURSO"
}

# bench se lanza como root, pero antes de escribir cambia al usuario del
# bench (frappe_user). La carpeta de esta ejecucion tiene que ser suya; se
# comprueba de verdad que pueda escribir en ella.
preparar_carpeta_bench() {
  local u g base
  u="$(sed -n 's/.*"frappe_user"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
         "${BENCH_PATH}/sites/common_site_config.json" 2>/dev/null | head -n 1)"
  [ -n "$u" ] || u="$(stat -c '%U' "$BENCH_PATH" 2>/dev/null)"
  { [ -n "$u" ] && [ "$u" != "root" ]; } || return 0
  g="$(id -gn "$u" 2>/dev/null)" || return 1
  base="$(dirname "$DIR_TRABAJO")"
  # La carpeta comun del gestor solo deja pasar, no listar.
  [ "$(basename "$base")" = "izone-backup" ] && chmod 711 "$base" 2>/dev/null
  { chgrp "$g" "$DIR_TRABAJO" && chmod 750 "$DIR_TRABAJO" \
    && chown "${u}:${g}" "$EN_CURSO" && chmod 750 "$EN_CURSO"; } 2>/dev/null || return 1
  if [ "$(id -un)" = "$u" ]; then
    [ -w "$EN_CURSO" ] && [ -x "$EN_CURSO" ]
  else
    runuser -u "$u" -- test -w "$EN_CURSO" -a -x "$EN_CURSO" 2>/dev/null
  fi
}

# Relee desde el NAS cada archivo enviado y lo compara byte a byte con el
# respaldo verificado. El NAS no da huellas, asi que no hay atajo posible.
comprobar_en_nas() {   # comprobar_en_nas <carpeta en el NAS>
  local salida est l
  salida="$("$RC" check "$EN_CURSO" "$1" --one-way --download "${RC_RED[@]}" 2>&1)"; est=$?
  printf '%s\n' "$salida" >> "$RCLONE_LOG" 2>/dev/null
  if [ "$est" -ne 0 ]; then
    printf '%s\n' "$salida" | grep -Ei "differ|missing|not in|error" | head -n 5 \
      | while IFS= read -r l; do log "        $l"; done
    return 1
  fi
  return 0
}

# Retencion por niveles sobre <NAS>/<dd-mes-aaaa>. Nunca toca la carpeta
# de hoy ni las subidas en curso. Si el NAS no responde al listar, no se
# borra nada: una lista vacia no significa "no hay respaldos".
retencion_niveles_nas() {
  local dias="$1" mensual="$2" meses="$3"
  [ "${dias:-0}" -gt 0 ] 2>/dev/null || return 0
  local ahora ym_hoy nombre ts ym edad dif listado dirs=()
  declare -A pri_ts pri_dir
  if ! listado="$("$RC" lsf "${NAS}:${NAS_RAIZ}" --dirs-only "${RC_RAPIDO[@]}" 2>>"$RCLONE_LOG")"; then
    log "[AVISO] Retencion: no se pudo listar el NAS. No se borro nada."
    return 0
  fi
  ahora="$(date +%s)"
  ym_hoy=$(( $(date +%Y) * 12 + 10#$(date +%m) ))
  mapfile -t dirs < <(printf '%s\n' "$listado" | sed 's:/$::' | grep -v '^$')

  for nombre in "${dirs[@]}"; do
    ts="$(LC_ALL=C date -d "${nombre//-/ }" +%s 2>/dev/null)" || continue
    [ -n "$ts" ] || continue
    ym="$(date -d "@$ts" +%Y-%m)"
    if [ -z "${pri_ts[$ym]:-}" ] || [ "$ts" -lt "${pri_ts[$ym]}" ]; then
      pri_ts[$ym]="$ts"; pri_dir[$ym]="$nombre"
    fi
  done

  for nombre in "${dirs[@]}"; do
    [ "$nombre" = "$FECHA" ] && continue
    ts="$(LC_ALL=C date -d "${nombre//-/ }" +%s 2>/dev/null)" || continue
    [ -n "$ts" ] || continue
    edad=$(( (ahora - ts) / 86400 ))
    [ "$edad" -le "$dias" ] && continue
    if [ "$mensual" = "si" ]; then
      ym="$(date -d "@$ts" +%Y-%m)"
      if [ "${pri_dir[$ym]:-}" = "$nombre" ]; then
        [ "${meses:-0}" -eq 0 ] && continue
        dif=$(( ym_hoy - ( $(date -d "@$ts" +%Y) * 12 + 10#$(date -d "@$ts" +%m) ) ))
        [ "$dif" -lt "$meses" ] && continue
      fi
    fi
    rcl purge "${NAS}:${NAS_RAIZ}/${nombre}" "${RC_RED[@]}" && log "[INFO] Retencion: eliminado $nombre"
  done
}

# El nombre del mes siempre en ingles, igual en cron que en una ejecucion
# manual: la retencion lo lee con LC_ALL=C.
FECHA="$(LC_ALL=C date +'%d-%B-%Y' | tr '[:upper:]' '[:lower:]')"
HORA="$(date +'%H-%M')"
SELLO="${FECHA}_${HORA}"

# ---- 0. Una sola ejecucion a la vez ----------------------------------
# Si cron dispara mientras sigue la anterior, o mientras corre una manual,
# la segunda no se ejecuta: dos respaldos cruzados se pisarian.
CANDADO="/run/lock/izone-backup-${JOB_NOMBRE}.lock"
{ [ -d /run/lock ] && [ -w /run/lock ]; } || CANDADO="/tmp/izone-backup-${JOB_NOMBRE}.lock"
exec 9>"$CANDADO" || { log "[ERROR] No se pudo crear el candado ${CANDADO}"; exit 1; }
if ! flock -n 9; then
  log "[AVISO] Otra ejecucion de este trabajo sigue en curso. Esta se omite."
  exit 7
fi

log "[INFO] Inicio del respaldo de '${SITE}' hacia //${SERVIDOR}/${NAS_RAIZ} (rclone, sin montaje)"
touch "$RCLONE_LOG" 2>/dev/null

# ---- 1. Comprobaciones previas: si algo no esta listo, no se crea nada --
"$RC" help backends 2>/dev/null | awk '{print $1}' | grep -qx smb || \
  salir 1 FALLO "rclone (${RC}) no esta disponible o no trae soporte SMB. No se creo ningun respaldo."
nas_preparar || \
  salir 1 FALLO "No se pudieron leer las credenciales (${CRED_FILE:-sin archivo}). No se creo ningun respaldo."
rcl mkdir "${NAS}:${NAS_RAIZ}" "${RC_RAPIDO[@]}"
"$RC" lsf "${NAS}:${NAS_RAIZ}" --max-depth 1 "${RC_RAPIDO[@]}" >/dev/null 2>>"$RCLONE_LOG" || \
  salir 1 FALLO "No se alcanza el NAS en //${SERVIDOR}/${NAS_RAIZ}. No se creo ningun respaldo."
cd "$BENCH_PATH" 2>/dev/null || salir 1 FALLO "No existe el bench: $BENCH_PATH"
mkdir -p "$DIR_TRABAJO" 2>/dev/null || salir 1 FALLO "No se pudo crear ${DIR_TRABAJO}"
chmod 750 "$DIR_TRABAJO" 2>/dev/null

# Restos de una ejecucion que se corto a la mitad (apagon, kill): no se
# sabe en que estado quedaron, asi que no se usan para nada.
if [ -e "$EN_CURSO" ]; then
  log "[AVISO] Quedaron restos de una ejecucion interrumpida; se eliminan."
  rm -rf "${EN_CURSO:?}"
fi

# Cuanto ocupara el respaldo: lo que peso el ultimo bueno, con margen. La
# primera vez se estima por los adjuntos mas 1 GB para la base de datos.
PREVIO_B="$(estado_valor ULTIMO_BYTES)"
if [ -n "$PREVIO_B" ] && [ "$PREVIO_B" -gt 0 ] 2>/dev/null; then
  NECESARIO_KB=$(( PREVIO_B / 1024 * 13 / 10 ))
else
  NECESARIO_KB=1048576
  if [ "${WITH_FILES:-si}" = "si" ]; then
    ADJ_KB="$(du -sk "${BENCH_PATH}/sites/${SITE}/public/files" \
                     "${BENCH_PATH}/sites/${SITE}/private/files" 2>/dev/null \
              | awk '{s+=$1} END {print s+0}')"
    NECESARIO_KB=$(( NECESARIO_KB + ${ADJ_KB:-0} ))
  fi
fi

# Si el disco no alcanza, bench no se ejecuta: un disco lleno si dejaria
# sin servicio al servidor de produccion.
espacio_suficiente "$DIR_TRABAJO" "$NECESARIO_KB" || \
  salir 1 FALLO "Espacio insuficiente: ${ESPACIO_MSG}. No se ejecuto bench."

NAS_LIBRE="$("$RC" about "${NAS}:${RECURSO}" --json "${RC_RAPIDO[@]}" 2>>"$RCLONE_LOG" \
  | sed -n 's/^[[:space:]]*"free":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
if [ -n "$NAS_LIBRE" ]; then
  [ "$NAS_LIBRE" -ge $(( NECESARIO_KB * 1024 )) ] || \
    salir 1 FALLO "El NAS tiene $(( NAS_LIBRE / 1048576 )) MB libres y el respaldo necesita unos $(( NECESARIO_KB / 1024 )) MB. No se ejecuto bench."
else
  log "[INFO] El NAS no informo su espacio libre; la subida lo confirmara."
fi

# ---- 2. Envios de ESTE trabajo que quedaron a medias -------------------
# Llevan el sufijo .subiendo.<trabajo>: nunca se confunden con un respaldo
# bueno, ni con carpetas de otro trabajo u otro servidor.
while IFS= read -r RESTO; do
  RESTO="${RESTO%/}"
  case "$RESTO" in */*"${SUFIJO}") ;; *) continue;; esac
  log "[AVISO] Se elimina un envio que quedo a medias: ${RESTO}"
  rcl purge "${NAS}:${NAS_RAIZ}/${RESTO}" "${RC_RED[@]}"
  rcl rmdir "${NAS}:${NAS_RAIZ}/${RESTO%/*}" "${RC_RAPIDO[@]}"   # la fecha, solo si quedo vacia
done < <("$RC" lsf "${NAS}:${NAS_RAIZ}" --dirs-only -R --max-depth 2 "${RC_RAPIDO[@]}" 2>>"$RCLONE_LOG")

# ---- 3. Crear el respaldo, con el sitio en linea ---------------------
# bench backup no detiene el sitio ni bloquea a los usuarios. Se ejecuta
# con prioridad baja de CPU y disco para competir lo menos posible.
# shellcheck disable=SC1091
. env/bin/activate
mkdir -p "$EN_CURSO" || salir 1 FALLO "No se pudo crear ${EN_CURSO}"
RUTA_PROPIA="${BENCH_RUTA_PROPIA:-no}"
if [ "$RUTA_PROPIA" = "si" ] && ! preparar_carpeta_bench; then
  log "[AVISO] El usuario del bench no puede escribir en ${EN_CURSO}; se usa la carpeta de respaldos del sitio."
  RUTA_PROPIA="no"
fi
if [ "$RUTA_PROPIA" != "si" ]; then
  # Sin carpeta propia, bench escribe primero en la carpeta del sitio.
  mkdir -p "$BACKUP_ORIGEN" 2>/dev/null
  if ! espacio_suficiente "$BACKUP_ORIGEN" "$NECESARIO_KB"; then
    rm -rf "${EN_CURSO:?}"
    salir 1 FALLO "Espacio insuficiente: ${ESPACIO_MSG}. No se ejecuto bench."
  fi
fi
PRIO=(nice -n 10)
command -v ionice >/dev/null 2>&1 && PRIO+=(ionice -c2 -n7 -t)
BENCH_ARGS=(--site "$SITE" backup)
[ "${WITH_FILES:-si}" = "si" ] && BENCH_ARGS+=(--with-files)
if [ "$RUTA_PROPIA" = "si" ]; then
  BENCH_ARGS+=(--backup-path "$EN_CURSO")
else
  # Se toman SOLO los archivos que aparezcan desde este momento; lo que ya
  # hubiera en la carpeta del sitio pertenece a otros y no se toca.
  MARCA="${DIR_TRABAJO}/.inicio"
  touch -d "@$(( $(date +%s) - 2 ))" "$MARCA"
fi
log "[INFO] Ejecutando bench backup con prioridad baja (el sitio sigue en linea)..."
SALIDA_BENCH="$("${PRIO[@]}" bench "${BENCH_ARGS[@]}" 2>&1)" || {
  printf '%s\n' "$SALIDA_BENCH" | tail -n 15
  rm -rf "${EN_CURSO:?}"
  salir 2 FALLO "'bench backup' fallo para $SITE"
}
if [ "$RUTA_PROPIA" != "si" ]; then
  find "$BACKUP_ORIGEN" -maxdepth 1 -type f -newer "$MARCA" -exec mv -t "$EN_CURSO" {} + 2>/dev/null
  rm -f "$MARCA"
fi

# Que bench devuelva 0 no garantiza que dejara archivos.
if [ -z "$(ls -A "$EN_CURSO" 2>/dev/null)" ]; then
  rm -rf "${EN_CURSO:?}"
  salir 5 FALLO "bench no dejo ningun archivo del respaldo."
fi

# ---- 4. Verificar ANTES de enviar nada -------------------------------
verificar_respaldo "$EN_CURSO" si; VERIF=$?
if [ "$VERIF" -eq 1 ]; then
  conservar_local danado
  salir 6 FALLO "El respaldo recien creado esta danado. No se envio nada al NAS y la retencion no se aplico. Se conserva para revision en ${GUARDADO}."
fi
escribir_huellas "$EN_CURSO"
N_ARCH="$(find "$EN_CURSO" -maxdepth 1 -type f ! -name SHA256SUMS | wc -l)"
N_HUELLAS="$(grep -c . "${EN_CURSO}/SHA256SUMS" 2>/dev/null)"
if [ "$N_ARCH" -eq 0 ] || [ "$N_ARCH" != "${N_HUELLAS:-0}" ]; then
  conservar_local danado
  salir 6 FALLO "No se pudo calcular la huella de todos los archivos (${N_HUELLAS:-0} de ${N_ARCH}). No se envio nada."
fi

# ---- 5. Enviar a una carpeta provisional y releerla byte a byte --------
# Mientras se envia y se comprueba, la carpeta lleva el sufijo .subiendo:
# nadie puede confundirla con un respaldo bueno. Solo recibe su nombre
# definitivo despues de releerla entera desde el NAS.
existe_en_nas() { "$RC" lsf "${NAS}:${NAS_RAIZ}/${FECHA}" --dirs-only "${RC_RAPIDO[@]}" 2>/dev/null | grep -qx "$1/"; }
if existe_en_nas "$HORA"; then
  HORA="$(date +'%H-%M-%S')"
  N=1
  while existe_en_nas "$HORA" && [ "$N" -lt 9 ]; do
    N=$((N+1)); HORA="$(date +'%H-%M-%S')-${N}"
  done
  if existe_en_nas "$HORA"; then
    conservar_local pendiente
    salir 3 FALLO "Ya existe ${FECHA}/${HORA} en el NAS y no se sobrescribe. El respaldo verificado se conserva en ${GUARDADO}."
  fi
fi
FINAL="${NAS}:${NAS_RAIZ}/${FECHA}/${HORA}"
PROVISIONAL="${FINAL}${SUFIJO}"
RUTA_FINAL="//${SERVIDOR}/${NAS_RAIZ}/${FECHA}/${HORA}"

INTENTO=1
while :; do
  log "[INFO] Enviando al NAS (intento ${INTENTO} de 2)..."
  if "$RC" copy "$EN_CURSO" "$PROVISIONAL" "${RC_RED[@]}" \
       --log-file="$RCLONE_LOG" --log-level INFO; then
    log "[INFO] Releyendo desde el NAS y comparando byte a byte..."
    comprobar_en_nas "$PROVISIONAL" && break
    log "[AVISO] Lo que quedo en el NAS no coincide con lo que se envio."
  else
    log "[AVISO] El envio al NAS fallo."
  fi
  rcl purge "$PROVISIONAL" "${RC_RED[@]}"
  if [ "$INTENTO" -ge 2 ]; then
    rcl rmdir "${NAS}:${NAS_RAIZ}/${FECHA}" "${RC_RAPIDO[@]}"
    conservar_local pendiente
    salir 3 FALLO "No se logro dejar en el NAS una copia identica, ni al reintentar. Se borro lo enviado; el respaldo verificado se conserva en ${GUARDADO}."
  fi
  log "[AVISO] Se borra lo enviado y se intenta una vez mas."
  INTENTO=2
done
log "[OK] Comprobado byte a byte: lo que esta en el NAS es identico al respaldo verificado."

# ---- 6. Nombre definitivo --------------------------------------------
# El NAS renombra la carpeta por su cuenta, sin volver a copiar nada. Luego
# se confirma que el nombre definitivo tenga todos los archivos.
if ! rcl moveto "$PROVISIONAL" "$FINAL" "${RC_RED[@]}" \
   || ! rcl check "$EN_CURSO" "$FINAL" --one-way --size-only "${RC_RAPIDO[@]}"; then
  rcl purge "$FINAL" "${RC_RED[@]}"
  rcl purge "$PROVISIONAL" "${RC_RED[@]}"
  rcl rmdir "${NAS}:${NAS_RAIZ}/${FECHA}" "${RC_RAPIDO[@]}"
  conservar_local pendiente
  salir 3 FALLO "No se pudo dar el nombre definitivo en el NAS. Se borro lo enviado; el respaldo verificado se conserva en ${GUARDADO}."
fi
log "[OK] Respaldo guardado en ${RUTA_FINAL} (${N_ARCH} archivos y SHA256SUMS)"

# ---- 7. Recien ahora se libera el disco local ------------------------
rm -rf "${EN_CURSO:?}"
for D in "${DIR_TRABAJO}"/pendiente-* "${DIR_TRABAJO}"/danado-*; do
  [ -d "$D" ] || continue
  rm -rf "$D" && log "[INFO] Se descarta la copia local de un fallo anterior: $(basename "$D")"
done

# ---- 8. Retencion: solo despues de un respaldo bueno -----------------
retencion_niveles_nas "${RETENCION_DIAS:-0}" "${MENSUAL_CONSERVAR:-no}" "${MENSUAL_MESES:-0}"

if [ "$VERIF" -eq 2 ]; then
  salir 0 AVISO "Respaldo correcto en ${RUTA_FINAL}, pero mucho mas pequeno que el anterior." "$RUTA_FINAL"
fi
salir 0 OK "Respaldo verificado byte a byte en ${RUTA_FINAL}" "$RUTA_FINAL"
EOF
  chmod 750 "$2"
}

# ====================== CREAR TRABAJO: RED ===========================
# Los asistentes son maquinas de pasos: cada paso puede devolver
#   0 = continuar   2 = volver al paso anterior   3 = cancelar el asistente
# En cualquier pregunta se puede escribir 'v' para volver o 'x' para cancelar.

aviso_navegacion() {
  say "  ${C_DIM}En cualquier pregunta: ${C_B}v${C_R}${C_DIM} = volver al paso anterior · ${C_B}x${C_R}${C_DIM} = cancelar${C_R}"
  echo
}

crear_trabajo_red() {
  local ETIQUETA="" JOB="" CONF="" SCRIPT="" CRED_FILE="" LOG_FILE=""
  local SRV="" SMB_PORT="445" CIFS_USER="" CIFS_PASS="" CIFS_DOM="" SHARE="" SUB="" UNC=""
  local SMB_VERS="" MOUNT_POINT="" MOUNT_OPTS=""
  local BENCH_PATH="" SITE="" BACKUP_ORIGEN="" WITH_FILES="" VERIFICAR="si" ESTADO_FILE=""
  local VERIFICAR_DESTINO="basico" TIPO_TRABAJO="red"
  local METODO_RED="cifs" ENTORNO_DESC="" ENTORNO_MOTIVO="" RCLONE_BIN="" RCLONE_LOG=""
  local DIR_TRABAJO="" BENCH_RUTA_PROPIA="no"
  local RETENCION_DIAS="" MENSUAL_CONSERVAR="no" MENSUAL_MESES="0" HORARIOS="" DIAS_CRON=""
  local paso=1 estado NAV_ON=1 volver_resumen=0

  while :; do
    case "$paso" in
      1) red_paso_etiqueta;;
      2) red_paso_servidor;;
      3) red_paso_credenciales;;
      4) red_paso_recurso;;
      5) red_paso_subcarpeta;;
      6) red_paso_conexion;;
      7) red_paso_frappe;;
      8) red_paso_retencion;;
      9) red_paso_programacion;;
      10) red_paso_resumen;;
      *) break;;
    esac
    estado=$?
    case "$estado" in
      0) if [ "$volver_resumen" = "1" ]; then paso=10; volver_resumen=0
         else paso=$((paso+1)); fi;;
      2) volver_resumen=0; paso=$((paso-1))
         [ "$paso" -lt 1 ] && { red_cancelar; return 0; };;
      3) red_cancelar; return 0;;
      4) volver_resumen=1;;   # el resumen fijo el paso a corregir
      9) break;;              # creado
    esac
  done
  return 0
}

red_cancelar() {
  [ -n "$CRED_FILE" ] && [ -f "$CRED_FILE" ] && [ ! -f "$CONF" ] && rm -f "$CRED_FILE"
  pantalla "NUEVO TRABAJO  >  Cancelado"
  warn "No se creo ningun trabajo."
  enter
}

red_paso_etiqueta() {
  pantalla "NUEVO TRABAJO  >  Unidad de Red   [1 de 10]"
  # El entorno decide el camino. Montar por CIFS es el primero; si este
  # servidor no puede montar, ni se intenta: se usa rclone sin montaje.
  if entorno_puede_montar; then
    METODO_RED="cifs"
    if ! command -v mount.cifs >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
      info "Verificando dependencias..."
      asegurar_paquete cifs-utils mount.cifs || {
        err "Sin cifs-utils el servidor no puede montar carpetas de red."
        enter; return 3; }
      asegurar_paquete rsync rsync || { enter; return 3; }
      echo
    fi
  else
    METODO_RED="rclone"
    info "Entorno detectado: ${C_B}${ENTORNO_DESC}${C_R}"
    say "  ${C_DIM}Aqui el sistema no permite montar carpetas de red. Los respaldos se${C_R}"
    say "  ${C_DIM}enviaran al NAS con rclone, sin montar nada, y cada uno se relee${C_R}"
    say "  ${C_DIM}desde el NAS byte a byte antes de darlo por bueno.${C_R}"
    echo
  fi
  aviso_navegacion
  pedir_etiqueta || return $?
  CONF="${APP_DIR}/${JOB}.conf"; SCRIPT="${BIN_DIR}/${JOB}.sh"
  CRED_FILE="${APP_DIR}/${JOB}.cred"; LOG_FILE="${LOG_DIR}/${JOB}.log"
  ESTADO_FILE="${APP_DIR}/${JOB}.estado"; RCLONE_LOG="${LOG_DIR}/${JOB}-rclone.log"
  return 0
}

red_paso_servidor() {
  local op preguntar=1
  while true; do
    if [ "$preguntar" = "1" ]; then
      pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 10] Servidor de archivos"
      aviso_navegacion
      say "  ${C_DIM}Direccion del NAS o servidor, no la de este servidor Linux.${C_R}"
      pedir SRV "Direccion IP o nombre del servidor" "$SRV" || return $?
    fi
    preguntar=1
    SMB_PORT="${SMB_PORT:-445}"
    info "Comprobando ${SRV}:${SMB_PORT}..."
    if puerto_abierto "$SRV" "$SMB_PORT"; then
      ok "El servidor responde en el puerto ${SMB_PORT}."; sleep 1; return 0
    fi
    err "No hay respuesta en ${SRV}:${SMB_PORT}."
    if [ "$SMB_PORT" = "445" ]; then
      say "    ${C_DIM}El 445 es el puerto de las carpetas compartidas. Causas habituales:${C_R}"
      say "    ${C_DIM}- la IP no corresponde a ese NAS${C_R}"
      say "    ${C_DIM}- el servicio SMB esta desactivado en el NAS${C_R}"
      say "    ${C_DIM}- el servidor y el NAS estan en redes distintas, o hay un firewall${C_R}"
      say "    ${C_DIM}Que el NAS abra su interfaz web (5001 en Synology) no implica que${C_R}"
      say "    ${C_DIM}el 445 este disponible: son servicios distintos.${C_R}"
    fi
    echo
    say "   1) Corregir la direccion"
    say "   2) Continuar de todos modos"
    say "   3) SMB llega por otro puerto (NAT o tunel)"
    say "   v) Volver al paso anterior     x) Cancelar"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "${op,,}" in
      1) continue;;
      2) return 0;;
      3) pedir SMB_PORT "Puerto por el que llega SMB" "$SMB_PORT" || return $?
         if ! [[ "$SMB_PORT" =~ ^[0-9]+$ ]] || [ "$SMB_PORT" -lt 1 ] || [ "$SMB_PORT" -gt 65535 ]; then
           err "Puerto invalido."; SMB_PORT=445; sleep 1
         fi
         preguntar=0;;
      v) return 2;;
      x) return 3;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

red_paso_credenciales() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [3 de 10] Credenciales del recurso"
  aviso_navegacion
  say "  ${C_DIM}Usuario creado EN ESE SERVIDOR con permiso de lectura y escritura.${C_R}"
  pedir CIFS_USER "Usuario" "$CIFS_USER" || return $?
  say "  ${C_DIM}No se muestra mientras escribe. Sin comillas.${C_R}"
  pedir_secreto CIFS_PASS "Contrasena" || return $?
  say "  ${C_DIM}Deje WORKGROUP si la red no tiene Active Directory.${C_R}"
  pedir CIFS_DOM "Dominio o grupo de trabajo" "${CIFS_DOM:-WORKGROUP}" || return $?
  mkdir -p "$APP_DIR" "$LOG_DIR"; chmod 750 "$APP_DIR"
  { echo "username=${CIFS_USER}"; echo "password=${CIFS_PASS}"; echo "domain=${CIFS_DOM}"; } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  ok "Credenciales guardadas."
  sleep 1
  return 0
}

red_paso_recurso() {
  local recursos=() i opcion
  pantalla "TRABAJO '${ETIQUETA}'  >  [4 de 10] Carpeta compartida"
  aviso_navegacion
  command -v smbclient >/dev/null 2>&1 || asegurar_paquete smbclient smbclient
  if command -v smbclient >/dev/null 2>&1; then
    info "Consultando las carpetas compartidas de ${SRV}..."
    mapfile -t recursos < <(descubrir_recursos "$SRV" "$CIFS_USER" "$CIFS_PASS" "$CIFS_DOM" "$SMB_PORT")
  fi
  if [ "${#recursos[@]}" -gt 0 ]; then
    ok "El servidor publica estas carpetas compartidas:"
    for i in "${!recursos[@]}"; do say "    $((i+1))) ${recursos[$i]}"; done
    say "    0) Escribir el nombre manualmente"
    echo
    while true; do
      read -rp "  Seleccione la carpeta compartida: " opcion || fin_entrada
      _nav_check "$opcion" && : || return $?
      if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "${#recursos[@]}" ]; then
        SHARE="${recursos[$((opcion-1))]}"; return 0
      elif [ "$opcion" = "0" ]; then
        pedir SHARE "Nombre exacto de la carpeta compartida" "$SHARE" || return $?
        normalizar_recurso; return 0
      else err "Opcion invalida."; fi
    done
  else
    warn "No se pudo obtener la lista de carpetas compartidas."
    say "  ${C_DIM}Revise las credenciales, o escriba el nombre del recurso a mano.${C_R}"
    say "  ${C_DIM}Solo el nombre del recurso, sin // ni la IP. Ejemplo: Informatica${C_R}"
    pedir SHARE "Nombre exacto de la carpeta compartida" "$SHARE" || return $?
    normalizar_recurso; return 0
  fi
}

# Limpia barras y separa "Recurso/sub/carpeta" en recurso + subcarpeta
normalizar_recurso() {
  SHARE="${SHARE//\\//}"
  SHARE="$(printf '%s' "$SHARE" | sed -e 's#^/*##' -e 's#/*$##' -e 's#//*#/#g')"
  if [[ "$SHARE" == */* ]]; then
    local resto="${SHARE#*/}"
    SHARE="${SHARE%%/*}"
    SUB="${resto}${SUB:+/$SUB}"
    echo
    info "Se interpreta asi:"
    say "    recurso compartido : ${C_B}${SHARE}${C_R}"
    say "    subcarpeta         : ${C_B}${SUB}${C_R}"
    sleep 2
  fi
}

red_paso_subcarpeta() {
  local subs=() i opcion r
  pantalla "TRABAJO '${ETIQUETA}'  >  [5 de 10] Subcarpeta"
  aviso_navegacion
  say "  Recurso elegido: ${C_B}//${SRV}/${SHARE}${C_R}"
  echo
  if [ -n "$SUB" ]; then
    say "  Subcarpeta ya indicada: ${C_B}${SUB}${C_R}"
    si_no_nav "Usar esa subcarpeta?"; r=$?
    case "$r" in
      0) UNC="//${SRV}/${SHARE}/${SUB}"; return 0;;
      2|3) return "$r";;
      1) SUB="";;
    esac
    echo
  fi
  si_no_nav "Los respaldos van dentro de una subcarpeta de '${SHARE}'?"; r=$?
  case "$r" in
    1) SUB=""; UNC="//${SRV}/${SHARE}"; return 0;;
    2|3) return "$r";;
  esac
  command -v smbclient >/dev/null 2>&1 && \
    mapfile -t subs < <(descubrir_subcarpetas "$SRV" "$SHARE" "$CIFS_USER" "$CIFS_PASS" "$CIFS_DOM" "$SMB_PORT")
  if [ "${#subs[@]}" -gt 0 ]; then
    say "  Subcarpetas encontradas:"
    for i in "${!subs[@]}"; do say "    $((i+1))) ${subs[$i]}"; done
    say "    0) Escribir la ruta manualmente"
    while true; do
      read -rp "  Seleccione la subcarpeta: " opcion || fin_entrada
      _nav_check "$opcion" && : || return $?
      if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "${#subs[@]}" ]; then
        SUB="${subs[$((opcion-1))]}"; break
      elif [ "$opcion" = "0" ]; then
        pedir SUB "Ruta dentro del recurso" "$SUB" || return $?; break
      else err "Opcion invalida."; fi
    done
  else
    warn "No se pudieron listar las subcarpetas."
    pedir SUB "Ruta dentro del recurso" "$SUB" || return $?
  fi
  SUB="${SUB//\\//}"
  SUB="$(printf '%s' "$SUB" | sed -e 's#^/*##' -e 's#/*$##' -e 's#//*#/#g')"
  UNC="//${SRV}/${SHARE}${SUB:+/$SUB}"
  return 0
}

red_paso_conexion() {
  local d salida r
  pantalla "TRABAJO '${ETIQUETA}'  >  [6 de 10] Prueba de conexion"
  aviso_navegacion
  say "  Recurso: ${C_B}${UNC}${C_R}"
  echo
  if [ "$METODO_RED" = "rclone" ]; then
    red_conexion_rclone; return $?
  fi
  info "Probando versiones del protocolo SMB..."
  SMB_VERS="$(probar_version_smb "$UNC" "$CRED_FILE" "$SMB_PORT")"
  if [ -n "$SMB_VERS" ]; then
    ok "Conexion correcta usando SMB ${SMB_VERS}."
  else
    err "Ninguna version de SMB logro conectar."
    d="$(mktemp -d)"
    salida="$(mount -t cifs "$UNC" "$d" -o "credentials=${CRED_FILE},vers=3.0,sec=ntlmssp,iocharset=utf8,nounix,noserverino$([ "$SMB_PORT" != "445" ] && echo ",port=${SMB_PORT}")" 2>&1)"
    rmdir "$d" 2>/dev/null
    echo; explicar_error_mount "$salida"; echo
    case "$salida" in
      *"error(1)"*)
        # Usuario, contrasena y ruta pueden estar bien: es el sistema el que
        # no deja montar. Se pasa al segundo camino, que no necesita montar,
        # y su propia prueba confirma si de verdad funciona.
        METODO_RED="rclone"
        ENTORNO_MOTIVO="el sistema rechazo el montaje (mount error 1)"
        info "Se usara el segundo camino: rclone, sin montaje."
        echo
        red_conexion_rclone; return $?;;
    esac
    say "  ${C_DIM}Con 'v' vuelve atras para corregir la ruta o las credenciales.${C_R}"
    si_no_nav "Guardar la configuracion de todas formas?"; r=$?
    case "$r" in
      1) return 2;;
      2|3) return "$r";;
    esac
    pedir SMB_VERS "Version SMB a registrar" "3.0" || return $?
  fi
  echo
  pedir MOUNT_POINT "Punto de montaje local" "${MOUNT_POINT:-/mnt/${JOB}}" || return $?
  mkdir -p "$MOUNT_POINT"
  MOUNT_OPTS="_netdev,nofail,credentials=${CRED_FILE},vers=${SMB_VERS},sec=ntlmssp,iocharset=utf8,nounix,noserverino"
  [ "$SMB_PORT" != "445" ] && MOUNT_OPTS="${MOUNT_OPTS},port=${SMB_PORT}"
  return 0
}

# Segundo camino: rclone habla SMB con el NAS sin montar nada. El trabajo
# no se crea hasta que la prueba completa del canal salga perfecta.
red_conexion_rclone() {
  local op
  say "  ${C_B}Camino: rclone, sin montaje${C_R}"
  [ -n "$ENTORNO_MOTIVO" ] && say "  ${C_DIM}Motivo: ${ENTORNO_MOTIVO}.${C_R}"
  echo
  red_asegurar_rclone || return $?
  echo
  nas_usar "$SRV" "$SMB_PORT" "$CRED_FILE" "$RCLONE_BIN"
  while ! nas_probar_canal "${SHARE}${SUB:+/$SUB}"; do
    echo
    say "  ${C_DIM}El trabajo no se crea hasta que esta prueba salga perfecta.${C_R}"
    say "   r) Reintentar la prueba"
    say "   v) Volver para corregir la ruta o las credenciales"
    say "   x) Cancelar"
    while true; do
      read -rp "  Opcion [r]: " op || fin_entrada
      case "${op,,}" in
        ""|r) break;;
        v) return 2;;
        x) return 3;;
        *) err "Opcion invalida.";;
      esac
    done
    echo
  done
  echo
  pedir_dir_trabajo || return $?
  SMB_VERS=""; MOUNT_POINT=""; MOUNT_OPTS=""
  sleep 1
  return 0
}

red_paso_frappe() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [7 de 10] Que se respalda"
  aviso_navegacion
  pedir_frappe || return $?
  return 0
}

red_paso_retencion() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [8 de 10] Retencion"
  aviso_navegacion
  pedir_retencion || return $?
  return 0
}

red_paso_programacion() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [9 de 10] Programacion"
  aviso_navegacion
  pedir_horarios || return $?
  pedir_dias || return $?
  return 0
}

red_paso_resumen() {
  local op salida2
  while true; do
    pantalla "TRABAJO '${ETIQUETA}'  >  [10 de 10] Revision final"
    say "   ${C_B}1${C_R}) Etiqueta      : ${ETIQUETA}"
    say "   ${C_B}2${C_R}) Servidor      : ${SRV}$([ "$SMB_PORT" != "445" ] && echo "   puerto SMB: ${SMB_PORT}")"
    say "   ${C_B}3${C_R}) Usuario       : ${CIFS_USER}   dominio: ${CIFS_DOM}"
    say "   ${C_B}4${C_R}) Recurso       : ${SHARE}"
    say "   ${C_B}5${C_R}) Subcarpeta    : ${SUB:-(ninguna)}"
    if [ "$METODO_RED" = "rclone" ]; then
      say "   ${C_B}6${C_R}) Conexion      : ${UNC}   por rclone, sin montaje"
      say "       ${C_DIM}entorno: ${ENTORNO_DESC}   carpeta local: ${DIR_TRABAJO}${C_R}"
    else
      say "   ${C_B}6${C_R}) Conexion      : ${UNC}   SMB ${SMB_VERS}   en ${MOUNT_POINT}"
    fi
    say "   ${C_B}7${C_R}) Sitio         : ${SITE}   adjuntos: ${WITH_FILES}   verificacion: $(describir_verificacion "$VERIFICAR")"
    say "       ${C_DIM}destino comprobado: $(describir_verificacion_destino "$VERIFICAR_DESTINO")${C_R}"
    say "   ${C_B}8${C_R}) Retencion     : $(describir_retencion "$RETENCION_DIAS" "$MENSUAL_CONSERVAR" "$MENSUAL_MESES")"
    say "   ${C_B}9${C_R}) Programacion  : ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))"
    echo
    say "   ${C_B}s${C_R}) Crear el trabajo con estos datos"
    say "   ${C_B}x${C_R}) Cancelar sin crear nada"
    echo
    say "  ${C_DIM}Escriba el numero del dato que quiera corregir.${C_R}"
    read -rp "  Opcion: " op || fin_entrada
    case "${op,,}" in
      s|si) break;;
      x|cancelar) return 3;;
      v) return 2;;
      [1-9]) paso="$op"; return 4;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done

  pantalla "TRABAJO '${ETIQUETA}'  >  Resultado"
  if [ "$METODO_RED" = "rclone" ]; then
    mkdir -p "$DIR_TRABAJO"; chmod 750 "$DIR_TRABAJO"
    ok "Sin montaje: no se modifico /etc/fstab ni se monto nada."
  else
    fstab_escribir "$JOB" "$UNC" "$MOUNT_POINT" "$MOUNT_OPTS"
    umount "$MOUNT_POINT" >/dev/null 2>&1
    salida2="$(mount "$MOUNT_POINT" 2>&1)"
    if mountpoint -q "$MOUNT_POINT"; then
      ok "Recurso montado en $MOUNT_POINT"
      df -h "$MOUNT_POINT" | tail -n 1 | sed 's/^/    /'
      if touch "${MOUNT_POINT}/.izone_test" 2>/dev/null; then
        rm -f "${MOUNT_POINT}/.izone_test"; ok "Permisos de escritura confirmados."
      else
        warn "Se monto pero NO permite escritura con ese usuario."
      fi
    else
      explicar_error_mount "$salida2"
      warn "Se guardo la configuracion; corrijala desde el trabajo."
    fi
  fi

  local extra=()
  [ "$METODO_RED" = "rclone" ] && extra=(
    "RCLONE_BIN=${RCLONE_BIN}" "RCLONE_LOG=${RCLONE_LOG}" "DIR_TRABAJO=${DIR_TRABAJO}"
    "BENCH_RUTA_PROPIA=${BENCH_RUTA_PROPIA}")
  guardar_conf "$CONF" \
    "JOB_TIPO=red" "JOB_NOMBRE=${JOB}" "ETIQUETA=${ETIQUETA}" \
    "METODO_RED=${METODO_RED}" "ENTORNO=${ENTORNO_DESC}" \
    "SERVIDOR=${SRV}" "SMB_PORT=${SMB_PORT}" "RECURSO=${SHARE}" "SUBCARPETA=${SUB}" \
    "UNC=${UNC}" "MOUNT_POINT=${MOUNT_POINT}" "CRED_FILE=${CRED_FILE}" \
    "SMB_VERS=${SMB_VERS}" "MOUNT_OPTS=${MOUNT_OPTS}" \
    "BENCH_PATH=${BENCH_PATH}" "SITE=${SITE}" "BACKUP_ORIGEN=${BACKUP_ORIGEN}" \
    "WITH_FILES=${WITH_FILES}" "VERIFICAR=${VERIFICAR}" "VERIFICAR_DESTINO=${VERIFICAR_DESTINO}" \
    "RETENCION_DIAS=${RETENCION_DIAS}" \
    "MENSUAL_CONSERVAR=${MENSUAL_CONSERVAR}" "MENSUAL_MESES=${MENSUAL_MESES}" \
    "HORARIOS=${HORARIOS}" "DIAS_CRON=${DIAS_CRON}" "LOG_FILE=${LOG_FILE}" \
    "ESTADO_FILE=${ESTADO_FILE}" ${extra[@]+"${extra[@]}"} "GEN_VERSION=${GEN_VERSION_ACTUAL}"

  local gen="generar_script_red"
  [ "$METODO_RED" = "rclone" ] && gen="generar_script_red_rclone"
  if ! instalar_script "$gen" "$CONF" "$SCRIPT"; then
    err "No se pudo generar el script ${SCRIPT}. No se programo nada."
    say "    ${C_DIM}La configuracion quedo en ${CONF}.${C_R}"
    enter; return 9
  fi
  touch "$LOG_FILE"; chmod 640 "$LOG_FILE"
  if [ "$METODO_RED" = "rclone" ]; then touch "$RCLONE_LOG"; chmod 640 "$RCLONE_LOG"; fi
  reprogramar "$CONF"

  echo; hr
  ok "Trabajo '${JOB}' creado."
  say "    script : ${SCRIPT}"
  say "    config : ${CONF}"
  say "    log    : ${LOG_FILE}"
  say "    horario: ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))"
  if [ "$METODO_RED" = "rclone" ]; then
    echo
    say "  ${C_DIM}Recomendado: entre al trabajo y use '1) Ejecutar respaldo ahora' en${C_R}"
    say "  ${C_DIM}un horario de poco uso, y luego 'c) Comprobar un respaldo ya guardado'.${C_R}"
  fi
  enter
  return 9
}

# ==================== CREAR TRABAJO: DRIVE ===========================
crear_trabajo_drive() {
  command -v rclone >/dev/null 2>&1 || { pantalla "NUEVO TRABAJO > Google Drive"; asegurar_paquete rclone rclone || { enter; return 1; }; }
  local remotes
  remotes="$(rclone listremotes 2>/dev/null | sed 's/:$//')"
  if [ -z "$remotes" ]; then
    pantalla "NUEVO TRABAJO  >  Google Drive"
    warn "No hay ninguna cuenta de Google Drive conectada."
    say "  Use primero el menu 'Cuentas de Google Drive' para conectar una."
    enter; return 1
  fi

  local ETIQUETA="" JOB="" CONF="" SCRIPT="" LOG_FILE="" RCLONE_LOG="" ESTADO_FILE=""
  local RCLONE_REMOTE="" DEST_PATH="" TEMP_LOCAL="" VERIFICAR="si"
  local VERIFICAR_DESTINO="hash" TIPO_TRABAJO="drive" METODO_RED=""
  local BENCH_PATH="" SITE="" BACKUP_ORIGEN="" WITH_FILES="" BORRAR_ORIGEN="si"
  local RETENCION_DIAS="" MENSUAL_CONSERVAR="no" MENSUAL_MESES="0" HORARIOS="" DIAS_CRON=""
  local paso=1 estado NAV_ON=1 volver_resumen=0

  while :; do
    case "$paso" in
      1) drv_paso_etiqueta;;
      2) drv_paso_cuenta;;
      3) drv_paso_carpeta;;
      4) drv_paso_temporal;;
      5) drv_paso_frappe;;
      6) drv_paso_borrar;;
      7) drv_paso_retencion;;
      8) drv_paso_programacion;;
      9) drv_paso_resumen;;
      *) break;;
    esac
    estado=$?
    case "$estado" in
      0) if [ "$volver_resumen" = "1" ]; then paso=9; volver_resumen=0
         else paso=$((paso+1)); fi;;
      2) volver_resumen=0; paso=$((paso-1))
         [ "$paso" -lt 1 ] && { drv_cancelar; return 0; };;
      3) drv_cancelar; return 0;;
      4) volver_resumen=1;;
      9) break;;
    esac
  done
  return 0
}

drv_cancelar() {
  pantalla "NUEVO TRABAJO  >  Cancelado"
  warn "No se creo ningun trabajo."
  enter
}

drv_paso_etiqueta() {
  pantalla "NUEVO TRABAJO  >  Google Drive   [1 de 9]"
  aviso_navegacion
  pedir_etiqueta || return $?
  CONF="${APP_DIR}/${JOB}.conf"; SCRIPT="${BIN_DIR}/${JOB}.sh"
  LOG_FILE="${LOG_DIR}/${JOB}.log"; RCLONE_LOG="${LOG_DIR}/${JOB}-rclone.log"
  ESTADO_FILE="${APP_DIR}/${JOB}.estado"
  return 0
}

drv_paso_cuenta() {
  local arr=() i opcion
  pantalla "TRABAJO '${ETIQUETA}'  >  [2 de 9] Cuenta de Google Drive"
  aviso_navegacion
  mapfile -t arr <<< "$(rclone listremotes 2>/dev/null | sed 's/:$//')"
  if [ "${#arr[@]}" -eq 1 ]; then
    RCLONE_REMOTE="${arr[0]}"
    ok "Solo hay una cuenta conectada: ${RCLONE_REMOTE}"
  else
    say "  Cuentas conectadas:"
    for i in "${!arr[@]}"; do say "    $((i+1))) ${arr[$i]}"; done
    echo
    while true; do
      read -rp "  Seleccione la cuenta: " opcion || fin_entrada
      _nav_check "$opcion" && : || return $?
      if [[ "$opcion" =~ ^[0-9]+$ ]] && [ "$opcion" -ge 1 ] && [ "$opcion" -le "${#arr[@]}" ]; then
        RCLONE_REMOTE="${arr[$((opcion-1))]}"; break
      fi
      err "Opcion invalida."
    done
  fi
  info "Verificando el acceso..."
  rc lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1 && ok "Acceso confirmado." \
    || warn "No se pudo listar la cuenta; revisela con el diagnostico."
  sleep 1
  return 0
}

drv_paso_carpeta() {
  drive_elegir_carpeta "$RCLONE_REMOTE" || return $?
  DEST_PATH="${DEST_PATH#/}"; DEST_PATH="${DEST_PATH%/}"
  local tf
  pantalla "TRABAJO '${ETIQUETA}'  >  [3 de 9] Destino confirmado"
  ok "Los respaldos se subiran a:"
  say "    ${C_B}${RCLONE_REMOTE}:${DEST_PATH}/<fecha>/<hora>/${C_R}"
  echo
  info "Probando escritura..."
  tf="$(mktemp)"
  if rc copyto "$tf" "${RCLONE_REMOTE}:${DEST_PATH}/.izone_test" >/dev/null 2>&1; then
    rc deletefile "${RCLONE_REMOTE}:${DEST_PATH}/.izone_test" >/dev/null 2>&1
    ok "Escritura confirmada."
  else
    warn "No se pudo escribir en esa carpeta."
  fi
  rm -f "$tf"
  sleep 2
  return 0
}

drv_paso_temporal() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [4 de 9] Carpeta temporal"
  aviso_navegacion
  say "  ${C_DIM}Aqui se arma el paquete antes de subirlo. Se vacia al terminar.${C_R}"
  pedir TEMP_LOCAL "Carpeta temporal de trabajo" "${TEMP_LOCAL:-/tmp/${JOB}}" || return $?
  return 0
}

drv_paso_frappe() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [5 de 9] Que se respalda"
  aviso_navegacion
  pedir_frappe || return $?
  return 0
}

drv_paso_borrar() {
  local r
  pantalla "TRABAJO '${ETIQUETA}'  >  [6 de 9] Respaldos locales"
  aviso_navegacion
  say "  ${C_DIM}Si se borran, el disco del servidor no se llena. Solo se borran${C_R}"
  say "  ${C_DIM}cuando la subida a Drive termino correctamente.${C_R}"
  echo
  si_no_nav "Borrar los respaldos locales despues de subirlos?"; r=$?
  case "$r" in
    0) BORRAR_ORIGEN="si"; return 0;;
    1) BORRAR_ORIGEN="no"; return 0;;
    *) return "$r";;
  esac
}

drv_paso_retencion() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [7 de 9] Retencion"
  aviso_navegacion
  pedir_retencion || return $?
  return 0
}

drv_paso_programacion() {
  pantalla "TRABAJO '${ETIQUETA}'  >  [8 de 9] Programacion"
  aviso_navegacion
  pedir_horarios || return $?
  pedir_dias || return $?
  return 0
}

drv_paso_resumen() {
  local op
  while true; do
    pantalla "TRABAJO '${ETIQUETA}'  >  [9 de 9] Revision final"
    say "   ${C_B}1${C_R}) Etiqueta      : ${ETIQUETA}"
    say "   ${C_B}2${C_R}) Cuenta        : ${RCLONE_REMOTE}"
    say "   ${C_B}3${C_R}) Carpeta       : ${RCLONE_REMOTE}:${DEST_PATH}"
    say "   ${C_B}4${C_R}) Temporal      : ${TEMP_LOCAL}"
    say "   ${C_B}5${C_R}) Sitio         : ${SITE}   adjuntos: ${WITH_FILES}   verificacion: $(describir_verificacion "$VERIFICAR")"
    say "       ${C_DIM}destino comprobado: $(describir_verificacion_destino "$VERIFICAR_DESTINO")${C_R}"
    say "   ${C_B}6${C_R}) Borrar local  : ${BORRAR_ORIGEN}"
    say "   ${C_B}7${C_R}) Retencion     : $(describir_retencion "$RETENCION_DIAS" "$MENSUAL_CONSERVAR" "$MENSUAL_MESES")"
    say "   ${C_B}8${C_R}) Programacion  : ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))"
    echo
    say "   ${C_B}s${C_R}) Crear el trabajo con estos datos"
    say "   ${C_B}x${C_R}) Cancelar sin crear nada"
    echo
    say "  ${C_DIM}Escriba el numero del dato que quiera corregir.${C_R}"
    read -rp "  Opcion: " op || fin_entrada
    case "${op,,}" in
      s|si) break;;
      x|cancelar) return 3;;
      v) return 2;;
      [1-8]) paso="$op"; return 4;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done

  mkdir -p "$APP_DIR" "$LOG_DIR" "$TEMP_LOCAL"; chmod 750 "$APP_DIR"
  guardar_conf "$CONF" \
    "JOB_TIPO=drive" "JOB_NOMBRE=${JOB}" "ETIQUETA=${ETIQUETA}" \
    "RCLONE_REMOTE=${RCLONE_REMOTE}" "DEST_PATH=${DEST_PATH}" \
    "RCLONE_CONFIG=/root/.config/rclone/rclone.conf" "TEMP_LOCAL=${TEMP_LOCAL}" \
    "BENCH_PATH=${BENCH_PATH}" "SITE=${SITE}" "BACKUP_ORIGEN=${BACKUP_ORIGEN}" \
    "WITH_FILES=${WITH_FILES}" "VERIFICAR=${VERIFICAR}" "VERIFICAR_DESTINO=${VERIFICAR_DESTINO}" \
    "BORRAR_ORIGEN=${BORRAR_ORIGEN}" \
    "RETENCION_DIAS=${RETENCION_DIAS}" \
    "MENSUAL_CONSERVAR=${MENSUAL_CONSERVAR}" "MENSUAL_MESES=${MENSUAL_MESES}" \
    "HORARIOS=${HORARIOS}" "DIAS_CRON=${DIAS_CRON}" \
    "LOG_FILE=${LOG_FILE}" "RCLONE_LOG=${RCLONE_LOG}" "ESTADO_FILE=${ESTADO_FILE}" \
    "GEN_VERSION=${GEN_VERSION_ACTUAL}"

  if ! instalar_script generar_script_drive "$CONF" "$SCRIPT"; then
    pantalla "TRABAJO '${ETIQUETA}'  >  Resultado"
    err "No se pudo generar el script ${SCRIPT}. No se programo nada."
    enter; return 9
  fi
  touch "$LOG_FILE" "$RCLONE_LOG"; chmod 640 "$LOG_FILE" "$RCLONE_LOG"
  reprogramar "$CONF"

  pantalla "TRABAJO '${ETIQUETA}'  >  Resultado"
  ok "Trabajo '${JOB}' creado."
  say "    script : ${SCRIPT}"
  say "    config : ${CONF}"
  say "    destino: ${RCLONE_REMOTE}:${DEST_PATH}/<fecha>/<hora>"
  say "    horario: ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))"
  enter
  return 9
}
# ===================== HORARIOS DE UN TRABAJO ========================
menu_horarios() {
  local conf="$1" op i horas=() nueva lista quitar resto
  while true; do
    cargar_conf "$conf"
    pantalla "TRABAJO '${ETIQUETA}'  >  Horarios"
    mapfile -t horas < <(printf '%s\n' $HORARIOS)
    say "  Horas configuradas:"
    for i in "${!horas[@]}"; do say "    $((i+1))) ${horas[$i]}"; done
    say "  Dias: ${C_B}$(describir_dias "$DIAS_CRON")${C_R}"
    echo
    say "  ${C_DIM}Cron generado:${C_R}"; cron_mostrar "$JOB_NOMBRE"
    echo
    say "   1) Agregar una hora"
    say "   2) Quitar una hora"
    say "   3) Cambiar los dias"
    say "   4) Reemplazar toda la lista de horas"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) pedir nueva "Hora a agregar (HH:MM)"
         if ! hora_valida "$nueva"; then err "Hora invalida."; sleep 1; continue; fi
         nueva="$(normalizar_hora "$nueva")"
         if printf '%s\n' "${horas[@]}" | grep -qx "$nueva"; then
           warn "Esa hora ya estaba configurada."; sleep 1; continue
         fi
         lista="$(ordenar_horarios "$HORARIOS $nueva")"
         set_conf "$conf" HORARIOS "$lista"; reprogramar "$conf"
         ok "Agregada ${nueva}."; sleep 1;;
      2) if [ "${#horas[@]}" -le 1 ]; then
           err "Debe quedar al menos una hora. Use 'Reemplazar toda la lista'."; sleep 2; continue
         fi
         read -rp "  Numero de la hora a quitar: " i || fin_entrada
         if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "${#horas[@]}" ]; then
           quitar="${horas[$((i-1))]}"; resto=""
           for nueva in "${horas[@]}"; do [ "$nueva" = "$quitar" ] || resto="${resto}${resto:+ }${nueva}"; done
           set_conf "$conf" HORARIOS "$resto"; reprogramar "$conf"
           ok "Quitada ${quitar}."; sleep 1
         else err "Numero invalido."; sleep 1; fi;;
      3) pedir_dias
         set_conf "$conf" DIAS_CRON "$DIAS_CRON"; reprogramar "$conf"
         ok "Dias actualizados."; sleep 1;;
      4) pedir_horarios
         set_conf "$conf" HORARIOS "$HORARIOS"; reprogramar "$conf"
         ok "Horarios actualizados."; sleep 1;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

# ======================= MENU DE UN TRABAJO ==========================
# Trabajo de red que va por rclone, sin montaje (requiere cargar_conf).
es_red_rclone() { [ "${JOB_TIPO:-}" = "red" ] && [ "${METODO_RED:-cifs}" = "rclone" ]; }

# Carpeta del trabajo dentro del NAS: recurso/subcarpeta
nas_raiz_trabajo() { printf '%s' "${RECURSO}${SUBCARPETA:+/${SUBCARPETA}}"; }

nas_usar_trabajo() { nas_usar "$SERVIDOR" "${SMB_PORT:-445}" "$CRED_FILE" "${RCLONE_BIN:-rclone}"; }

ejecutar_trabajo() {
  cargar_conf "$1"
  pantalla "TRABAJO '${ETIQUETA}'  >  Ejecucion manual"
  local scr="${BIN_DIR}/${JOB_NOMBRE}.sh"
  [ -x "$scr" ] || { err "No existe el script $scr"; enter; return 1; }
  info "Ejecutando... puede tardar varios minutos."
  hr
  "$scr" 2>&1 | tee -a "$LOG_FILE" | sed 's/^/  /'
  local rc_est="${PIPESTATUS[0]}"
  hr
  [ "$rc_est" -eq 0 ] && ok "Finalizado correctamente." || err "Finalizo con codigo $rc_est."
  enter
}

eliminar_trabajo() {
  cargar_conf "$1"
  pantalla "TRABAJO '${ETIQUETA}'  >  Eliminar"
  warn "Se quitara la programacion y el script. Los respaldos ya enviados no se tocan."
  si_no "Confirma eliminar el trabajo '${JOB_NOMBRE}'?" || { enter; return 1; }
  cron_aplicar "$JOB_NOMBRE" ""
  rm -f "${BIN_DIR}/${JOB_NOMBRE}.sh"
  if es_red_rclone; then
    rm -f "$CRED_FILE"
    if [ -n "${DIR_TRABAJO:-}" ] && [ -d "$DIR_TRABAJO" ]; then
      rmdir "$DIR_TRABAJO" 2>/dev/null \
        || warn "Quedan copias locales en ${DIR_TRABAJO}; reviselas antes de borrarlas."
    fi
  elif [ "$JOB_TIPO" = "red" ]; then
    if si_no "Desmontar y quitar la linea de /etc/fstab?"; then
      umount "$MOUNT_POINT" >/dev/null 2>&1
      fstab_quitar "$JOB_NOMBRE" "$MOUNT_POINT"
    fi
    rm -f "$CRED_FILE"
  fi
  rm -f "$1"
  systemctl restart cron >/dev/null 2>&1
  ok "Trabajo eliminado."
  enter; return 0
}

menu_trabajo() {
  local conf="$1" op nuevo nmp nvers nopts sal nrem u p d sal2 sal3
  while true; do
    [ -f "$conf" ] || return 0
    cargar_conf "$conf"
    pantalla "TRABAJO: ${ETIQUETA}  [${JOB_TIPO}$(es_red_rclone && echo ' · rclone')]"
    if es_red_rclone; then
      say "  Destino : ${UNC}"
      say "  Camino  : rclone, sin montaje  ${C_DIM}(${ENTORNO:-entorno sin registrar})${C_R}"
    elif [ "$JOB_TIPO" = "red" ]; then
      say "  Destino : ${UNC}"
      mountpoint -q "$MOUNT_POINT" \
        && say "  Montaje : ${C_GR}activo${C_R} en ${MOUNT_POINT}" \
        || say "  Montaje : ${C_RD}inactivo${C_R} en ${MOUNT_POINT}"
    else
      say "  Destino : ${RCLONE_REMOTE}:${DEST_PATH}"
    fi
    say "  Sitio   : ${SITE}   adjuntos: ${WITH_FILES}"
    say "  Verificacion: $(describir_verificacion "${VERIFICAR:-si}")   destino: $(describir_verificacion_destino "${VERIFICAR_DESTINO:-}")"
    say "  Retencion: $(describir_retencion "${RETENCION_DIAS:-0}" "${MENSUAL_CONSERVAR:-no}" "${MENSUAL_MESES:-0}")"
    say "  Horario : ${HORARIOS}   ($(describir_dias "$DIAS_CRON"))"
    say "  Respaldo: $(estado_resumen "$conf")"
    echo
    say "   1) Ejecutar respaldo ahora"
    say "   2) Horarios y dias"
    say "   3) Destino"
    say "   4) Que se respalda (bench, sitio, adjuntos)"
    say "   5) Retencion"
    say "   6) Ver configuracion y log"
    say "   c) Comprobar un respaldo ya guardado"
    if es_red_rclone; then
      say "   7) Credenciales del recurso"
      say "   8) Probar la conexion con el NAS"
    elif [ "$JOB_TIPO" = "red" ]; then
      say "   7) Credenciales del recurso"
      say "   8) Montar ahora"
    fi
    say "   9) ${C_RD}Eliminar este trabajo${C_R}"
    say "   0) Volver"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) ejecutar_trabajo "$conf";;
      2) menu_horarios "$conf";;
      3) if es_red_rclone; then
           pantalla "TRABAJO '${ETIQUETA}'  >  Destino de red"
           say "  Actual: ${C_B}${UNC}${C_R}"
           while true; do
             pedir nuevo "Nueva cadena de conexion"
             nuevo="${nuevo//\\//}"; nuevo="${nuevo%/}"
             [[ "$nuevo" =~ ^//[^/]+/.+ ]] && break
             err "Formato invalido. Debe iniciar con // seguido del servidor y el recurso."
           done
           u="${nuevo#//}"; p="${u%%/*}"; u="${u#*/}"   # p = servidor, u = recurso[/sub]
           d=""; [[ "$u" == */* ]] && d="${u#*/}"
           u="${u%%/*}"
           nas_usar "$p" "${SMB_PORT:-445}" "$CRED_FILE" "${RCLONE_BIN:-rclone}"
           echo
           if nas_probar_canal "${u}${d:+/$d}"; then
             set_conf "$conf" UNC "$nuevo"; set_conf "$conf" SERVIDOR "$p"
             set_conf "$conf" RECURSO "$u"; set_conf "$conf" SUBCARPETA "$d"
             ok "Destino actualizado: ${nuevo}"
           else
             err "La prueba no salio perfecta. El destino NO se cambio."
           fi
         elif [ "$JOB_TIPO" = "red" ]; then
           pantalla "TRABAJO '${ETIQUETA}'  >  Destino de red"
           say "  Actual: ${C_B}${UNC}${C_R}"
           while true; do
             pedir nuevo "Nueva cadena de conexion"
             nuevo="${nuevo//\\//}"; nuevo="${nuevo%/}"
             [[ "$nuevo" =~ ^//[^/]+/.+ ]] && break
             err "Formato invalido. Debe iniciar con // seguido del servidor y el recurso."
           done
           pedir nmp "Punto de montaje" "$MOUNT_POINT"; mkdir -p "$nmp"
           pedir nvers "Version SMB" "$SMB_VERS"
           nopts="_netdev,nofail,credentials=${CRED_FILE},vers=${nvers},sec=ntlmssp,iocharset=utf8,nounix,noserverino"
           umount "$MOUNT_POINT" >/dev/null 2>&1; umount "$nmp" >/dev/null 2>&1
           fstab_escribir "$JOB_NOMBRE" "$nuevo" "$nmp" "$nopts" "$MOUNT_POINT"
           set_conf "$conf" UNC "$nuevo"; set_conf "$conf" MOUNT_POINT "$nmp"
           set_conf "$conf" SMB_VERS "$nvers"; set_conf "$conf" MOUNT_OPTS "$nopts"
           sal="$(mount "$nmp" 2>&1)"
           mountpoint -q "$nmp" && ok "Montado en $nmp" || explicar_error_mount "$sal"
         else
           pantalla "TRABAJO '${ETIQUETA}'  >  Destino en Drive"
           say "  Cuentas conectadas:"; rclone listremotes 2>/dev/null | sed 's/^/    - /'
           pedir nrem "Cuenta a usar" "$RCLONE_REMOTE"
           if ! rc lsd "${nrem}:" >/dev/null 2>&1; then err "No se pudo acceder a esa cuenta."; enter; continue; fi
           DEST_PATH=""; drive_elegir_carpeta "$nrem"
           set_conf "$conf" RCLONE_REMOTE "$nrem"; set_conf "$conf" DEST_PATH "$DEST_PATH"
           ok "Destino actualizado: ${nrem}:${DEST_PATH}"
         fi
         enter;;
      4) pantalla "TRABAJO '${ETIQUETA}'  >  Que se respalda"
         TIPO_TRABAJO="$JOB_TIPO"
         if pedir_frappe; then
           set_conf "$conf" BENCH_PATH "$BENCH_PATH"; set_conf "$conf" SITE "$SITE"
           set_conf "$conf" BACKUP_ORIGEN "$BACKUP_ORIGEN"; set_conf "$conf" WITH_FILES "$WITH_FILES"
           set_conf "$conf" VERIFICAR "$VERIFICAR"
           set_conf "$conf" VERIFICAR_DESTINO "$VERIFICAR_DESTINO"
           es_red_rclone && set_conf "$conf" BENCH_RUTA_PROPIA "$BENCH_RUTA_PROPIA"
           ok "Actualizado. Verificacion: $(describir_verificacion "$VERIFICAR")"
         fi; enter;;
      5) pantalla "TRABAJO '${ETIQUETA}'  >  Retencion"
         if pedir_retencion; then
           set_conf "$conf" RETENCION_DIAS "$RETENCION_DIAS"
           set_conf "$conf" MENSUAL_CONSERVAR "$MENSUAL_CONSERVAR"
           set_conf "$conf" MENSUAL_MESES "$MENSUAL_MESES"
           ok "Retencion: $(describir_retencion "$RETENCION_DIAS" "$MENSUAL_CONSERVAR" "$MENSUAL_MESES")"
         fi; enter;;
      6) pantalla "TRABAJO '${ETIQUETA}'  >  Configuracion"
         estado_detalle "$conf"; echo
         sed 's/^/    /' "$conf"; echo
         say "  ${C_B}Cron activo:${C_R}"; cron_mostrar "$JOB_NOMBRE"; echo
         say "  ${C_B}Ultimas lineas del log:${C_R}"
         tail -n 12 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || warn "Sin registros."
         enter;;
      7) if [ "$JOB_TIPO" != "red" ]; then err "Opcion invalida."; sleep 1; continue; fi
         pantalla "TRABAJO '${ETIQUETA}'  >  Credenciales"
         pedir u "Usuario del recurso compartido"
         pedir_secreto p "Contrasena"
         pedir d "Dominio o grupo de trabajo" "WORKGROUP"
         { echo "username=${u}"; echo "password=${p}"; echo "domain=${d}"; } > "$CRED_FILE"
         chmod 600 "$CRED_FILE"; ok "Credenciales actualizadas."
         if es_red_rclone; then
           echo; nas_usar_trabajo; nas_probar_canal "$(nas_raiz_trabajo)"
         else
           umount "$MOUNT_POINT" >/dev/null 2>&1
           sal2="$(mount "$MOUNT_POINT" 2>&1)"
           mountpoint -q "$MOUNT_POINT" && ok "Montaje validado." || explicar_error_mount "$sal2"
         fi
         enter;;
      8) if [ "$JOB_TIPO" != "red" ]; then err "Opcion invalida."; sleep 1; continue; fi
         if es_red_rclone; then
           pantalla "TRABAJO '${ETIQUETA}'  >  Probar la conexion"
           if rclone_con_smb "${RCLONE_BIN:-}"; then
             ok "rclone: ${RCLONE_BIN} ($(rclone_version_de "$RCLONE_BIN"))"
             nas_usar_trabajo; nas_probar_canal "$(nas_raiz_trabajo)"
           else
             err "No se encuentra un rclone con SMB en ${RCLONE_BIN:-(sin definir)}."
           fi
           enter; continue
         fi
         pantalla "TRABAJO '${ETIQUETA}'  >  Montar"
         systemctl daemon-reload >/dev/null 2>&1
         sal3="$(mount "$MOUNT_POINT" 2>&1)"
         if mountpoint -q "$MOUNT_POINT"; then
           ok "Montado."; df -h "$MOUNT_POINT" | tail -n1 | sed 's/^/    /'
         else explicar_error_mount "$sal3"; fi
         enter;;
      c|C) comprobar_respaldo_guardado "$conf";;
      9) eliminar_trabajo "$conf" && return 0;;
      0) return 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

# ====================== LISTA DE TRABAJOS ============================
menu_trabajos() {
  local op confs=() i
  while true; do
    pantalla "TRABAJOS DE RESPALDO"
    mapfile -t confs < <(listar_confs)
    if [ "${#confs[@]}" -eq 0 ]; then
      warn "No hay ningun trabajo configurado todavia."
      say "  ${C_DIM}Cada trabajo es un destino independiente con su propio horario.${C_R}"
      say "  ${C_DIM}Puede tener varios NAS y varias cuentas de Drive a la vez.${C_R}"
    else
      for i in "${!confs[@]}"; do
        ( cargar_conf "${confs[$i]}"
          local destino estado tipo="$JOB_TIPO"
          if es_red_rclone; then
            destino="$UNC"; tipo="red · rclone"; estado="${C_DIM}sin montaje${C_R}"
          elif [ "$JOB_TIPO" = "red" ]; then
            destino="$UNC"
            mountpoint -q "$MOUNT_POINT" && estado="${C_GR}montado${C_R}" || estado="${C_RD}sin montar${C_R}"
          else
            destino="${RCLONE_REMOTE}:${DEST_PATH}"; estado="${C_DIM}nube${C_R}"
          fi
          printf '%b\n' "   ${C_B}$((i+1))) ${ETIQUETA}${C_R}  ${C_DIM}[${tipo}]${C_R}  ${estado}"
          printf '%b\n' "       ${C_DIM}destino: ${destino}${C_R}"
          printf '%b\n' "       ${C_DIM}horario: ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))${C_R}"
          printf '%b\n' "       respaldo: $(estado_resumen "${confs[$i]}")"
        )
      done
    fi
    echo
    say "   ${C_B}r${C_R}) Nuevo trabajo hacia una Unidad de Red (NAS)"
    say "   ${C_B}g${C_R}) Nuevo trabajo hacia Google Drive"
    say "   ${C_B}0${C_R}) Volver"
    echo
    read -rp "  Numero del trabajo, o letra: " op || fin_entrada
    case "$op" in
      r|R) crear_trabajo_red;;
      g|G) crear_trabajo_drive;;
      0)   return 0;;
      *)   if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le "${#confs[@]}" ]; then
             menu_trabajo "${confs[$((op-1))]}"
           else err "Opcion invalida."; sleep 1; fi;;
    esac
  done
}

# ========================== DIAGNOSTICO ==============================
diag_frappe() {
  ( cargar_conf "$1"
    say "  ${C_B}Entorno Frappe${C_R}"
    [ -d "$BENCH_PATH" ] && ok "bench: $BENCH_PATH" || err "No existe el bench: $BENCH_PATH"
    [ -f "$BENCH_PATH/env/bin/activate" ] && ok "entorno virtual presente" || err "Falta env/bin/activate"
    [ -d "$BENCH_PATH/sites/$SITE" ] && ok "sitio: $SITE" || err "No existe el sitio: $SITE"
    if [ -d "$BACKUP_ORIGEN" ]; then
      ok "backups locales: $(ls -1 "$BACKUP_ORIGEN" 2>/dev/null | wc -l) archivos pendientes"
    else warn "aun no existe: $BACKUP_ORIGEN"; fi )
}

diagnostico() {
  local confs=() i
  mapfile -t confs < <(listar_confs)
  if [ "${#confs[@]}" -eq 0 ]; then
    pantalla "DIAGNOSTICO"; warn "No hay ningun trabajo configurado."; enter; return 0
  fi
  for i in "${!confs[@]}"; do
    pantalla "DIAGNOSTICO  ($((i+1)) de ${#confs[@]})"
    ( cargar_conf "${confs[$i]}"
      say "  ${C_B}${C_CY}== ${ETIQUETA}  [${JOB_TIPO}$(es_red_rclone && echo ' · rclone')] ==${C_R}"
      if es_red_rclone; then
        local base restos lib
        base="$(nas_raiz_trabajo)"
        say "  ${C_DIM}destino: ${UNC}   camino: rclone, sin montaje${C_R}"
        say "  ${C_DIM}entorno al crear el trabajo: ${ENTORNO:-sin registrar}${C_R}"
        if rclone_con_smb "${RCLONE_BIN:-}"; then
          ok "rclone: ${RCLONE_BIN} ($(rclone_version_de "$RCLONE_BIN"))"
        else
          err "no se encuentra un rclone con SMB en ${RCLONE_BIN:-(sin definir)}"
        fi
        [ -f "$CRED_FILE" ] && ok "credenciales: permisos $(stat -c '%a' "$CRED_FILE")" || err "faltan credenciales"
        nas_usar_trabajo
        if NAS_ESPERA=90 nas_rc lsf "izonenas:${base}" --max-depth 1 >/dev/null 2>&1; then
          ok "acceso a //${SERVIDOR}/${base}"
          say "  ${C_DIM}ultimas carpetas en el NAS:${C_R}"
          NAS_ESPERA=90 nas_rc lsf "izonenas:${base}" --dirs-only 2>/dev/null \
            | grep -v '\.subiendo\.' | tail -n 5 | sed 's/^/    /'
          restos="$(NAS_ESPERA=90 nas_rc lsf "izonenas:${base}" --dirs-only -R --max-depth 2 2>/dev/null \
            | grep -c "\.subiendo\.${JOB_NOMBRE}/$")"
          [ "${restos:-0}" -gt 0 ] && warn "${restos} envio(s) a medias en el NAS; se limpian en la proxima ejecucion."
        else err "sin acceso a //${SERVIDOR}/${base}"; fi
        if [ -d "${DIR_TRABAJO:-}" ]; then
          lib="$(df -h "$DIR_TRABAJO" 2>/dev/null | awk 'NR==2 {print $4}')"
          ok "carpeta local: ${DIR_TRABAJO}  (${lib} libres)"
          for d in "$DIR_TRABAJO"/pendiente-* "$DIR_TRABAJO"/danado-*; do
            [ -d "$d" ] && warn "copia local de un fallo: $(basename "$d")"
          done
        else warn "aun no existe la carpeta local ${DIR_TRABAJO:-}"; fi
      elif [ "$JOB_TIPO" = "red" ]; then
        say "  ${C_DIM}origen remoto: ${UNC}${C_R}"
        if mountpoint -q "$MOUNT_POINT"; then
          ok "montado en $MOUNT_POINT"
          df -h "$MOUNT_POINT" | tail -n1 | sed 's/^/    /'
          if touch "${MOUNT_POINT}/.izone_test" 2>/dev/null; then
            rm -f "${MOUNT_POINT}/.izone_test"; ok "escritura real: correcta"
          else err "escritura real: denegada"; fi
        else err "NO montado en $MOUNT_POINT"; fi
        [ -f "$CRED_FILE" ] && ok "credenciales: permisos $(stat -c '%a' "$CRED_FILE")" || err "faltan credenciales"
        grep -q "$MOUNT_POINT" /etc/fstab && ok "entrada en /etc/fstab presente" || err "sin entrada en /etc/fstab"
      else
        export RCLONE_CONFIG
        rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:" \
          && ok "cuenta '${RCLONE_REMOTE}' registrada" || err "cuenta '${RCLONE_REMOTE}' no existe"
        if rc lsd "${RCLONE_REMOTE}:${DEST_PATH}" >/dev/null 2>&1; then
          ok "acceso a ${RCLONE_REMOTE}:${DEST_PATH}"
          say "  ${C_DIM}ultimas carpetas subidas:${C_R}"
          rc lsf "${RCLONE_REMOTE}:${DEST_PATH}" --dirs-only 2>/dev/null | tail -n 5 | sed 's/^/    /'
        else err "sin acceso a ${RCLONE_REMOTE}:${DEST_PATH}"; fi
      fi )
    echo; diag_frappe "${confs[$i]}"
    echo; estado_detalle "${confs[$i]}"
    echo
    ( cargar_conf "${confs[$i]}"
      say "  ${C_B}Programacion y registro${C_R}"
      local b; b="$(cron_mostrar "$JOB_NOMBRE")"
      if [ -n "$b" ]; then ok "cron activo:"; printf '%s\n' "$b"
      else err "sin entradas de cron"; fi
      systemctl is-active --quiet cron && ok "servicio cron: activo" || err "servicio cron: inactivo"
      if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        say "  ${C_DIM}ultimas lineas del log:${C_R}"
        tail -n 6 "$LOG_FILE" | sed 's/^/    /'
      else warn "el log esta vacio: aun no se ha ejecutado ningun respaldo"; fi )
    enter
  done
}

# ============ COMPROBAR UN RESPALDO YA GUARDADO ======================
# Cada respaldo viaja con su SHA256SUMS. Esto permite auditar cualquiera
# de los que ya estan en el destino, sin esperar al dia de la
# restauracion para descubrir que uno no servia.
elegir_carpeta_respaldo() {   # elegir_carpeta_respaldo <lista por lineas>
  local items=() i op
  # Orden por fecha real: alfabeticamente "15-september" quedaria antes
  # que "08-october". Lo que no es una fecha va al final.
  mapfile -t items < <(printf '%s\n' "$1" | grep -v '^$' | while IFS= read -r i; do
      op="${i%%/*}"
      printf '%s\t%s\n' "$(LC_ALL=C date -d "${op//-/ }" +%s 2>/dev/null || echo 0)" "$i"
    done | sort -t $'\t' -k1,1nr -k2,2r | cut -f2-)
  if [ "${#items[@]}" -eq 0 ]; then
    warn "No se encontro ningun respaldo en el destino."; return 1
  fi
  say "  Respaldos disponibles (del mas reciente al mas antiguo):"
  for i in "${!items[@]}"; do
    [ "$i" -ge 20 ] && { say "    ${C_DIM}... y $(( ${#items[@]} - 20 )) mas${C_R}"; break; }
    say "    $((i+1))) ${items[$i]}"
  done
  echo
  read -rp "  Numero del respaldo a comprobar (0 = volver): " op || fin_entrada
  [ "$op" = "0" ] && return 1
  if [[ "$op" =~ ^[0-9]+$ ]] && [ "$op" -ge 1 ] && [ "$op" -le "${#items[@]}" ]; then
    CARPETA_ELEGIDA="${items[$((op-1))]}"; return 0
  fi
  err "Opcion invalida."; return 1
}

comprobar_respaldo_guardado() {   # comprobar_respaldo_guardado <archivo .conf>
  local conf="$1" lista ruta tmp res
  cargar_conf "$conf"
  pantalla "TRABAJO '${ETIQUETA}'  >  Comprobar un respaldo guardado"

  if es_red_rclone; then
    # Cada archivo se lee desde el NAS y se le calcula la huella al vuelo:
    # nada se descarga al disco de este servidor, sea cual sea el tamano.
    local base sums h f act
    base="$(nas_raiz_trabajo)"
    nas_usar_trabajo
    lista="$(NAS_ESPERA=120 nas_rc lsf "izonenas:${base}" --dirs-only -R --max-depth 2 2>/dev/null \
             | sed 's:/$::' | grep '/' | grep -v '\.subiendo\.')"
    elegir_carpeta_respaldo "$lista" || { enter; return 1; }
    ruta="izonenas:${base}/${CARPETA_ELEGIDA}"
    if ! sums="$(NAS_ESPERA=120 nas_rc cat "${ruta}/SHA256SUMS" 2>/dev/null)" || [ -z "$sums" ]; then
      warn "Ese respaldo no tiene SHA256SUMS, o no se pudo leer desde el NAS."
      enter; return 1
    fi
    echo; info "Leyendo cada archivo desde el NAS y recalculando su huella..."
    say "  ${C_DIM}No se guarda nada en este servidor. Puede tardar segun el tamano.${C_R}"; echo
    res=""
    while read -r h f; do
      [ -n "$h" ] || continue
      f="${f#\*}"
      if act="$(nas_rc cat "${ruta}/${f}" 2>/dev/null | sha256sum)" && [ "${act%% *}" = "$h" ]; then
        res+="${f}: OK"$'\n'
      else
        res+="${f}: FAILED"$'\n'
      fi
    done <<< "$sums"
    true
  elif [ "$JOB_TIPO" = "red" ]; then
    mountpoint -q "$MOUNT_POINT" || { err "El recurso no esta montado."; enter; return 1; }
    lista="$(find "$MOUNT_POINT" -mindepth 2 -maxdepth 2 -type d -printf '%P\n' 2>/dev/null)"
    elegir_carpeta_respaldo "$lista" || { enter; return 1; }
    ruta="${MOUNT_POINT}/${CARPETA_ELEGIDA}"
    if [ ! -f "${ruta}/SHA256SUMS" ]; then
      warn "Ese respaldo no tiene SHA256SUMS."
      say  "  ${C_DIM}Se creo con una version anterior a la 2.4.0; no se puede comprobar asi.${C_R}"
      enter; return 1
    fi
    echo; info "Leyendo el respaldo desde el destino y recalculando las huellas..."
    say "  ${C_DIM}Se lee por la red: puede tardar segun el tamano.${C_R}"; echo
    res="$( cd "$ruta" && sha256sum -c SHA256SUMS 2>&1 )"
  else
    lista="$(rc lsf "${RCLONE_REMOTE}:${DEST_PATH}" --dirs-only -R 2>/dev/null \
             | sed 's:/$::' | grep '/' )"
    elegir_carpeta_respaldo "$lista" || { enter; return 1; }
    ruta="${RCLONE_REMOTE}:${DEST_PATH}/${CARPETA_ELEGIDA}"
    echo
    warn "Para comprobarlo hay que descargarlo de vuelta desde Drive."
    si_no "Continuar?" || { enter; return 1; }
    tmp="$(mktemp -d)"
    info "Descargando..."
    if ! rclone copy "$ruta" "$tmp" --contimeout 30s --timeout 10m --retries 2 >/dev/null 2>&1; then
      err "No se pudo descargar el respaldo."; rm -rf "$tmp"; enter; return 1
    fi
    if [ ! -f "${tmp}/SHA256SUMS" ]; then
      warn "Ese respaldo no tiene SHA256SUMS (se creo con una version anterior)."
      rm -rf "$tmp"; enter; return 1
    fi
    res="$( cd "$tmp" && sha256sum -c SHA256SUMS 2>&1 )"
  fi

  local est=$?
  echo
  if printf '%s' "$res" | grep -q "FAILED\|FALL"; then
    err "El respaldo NO esta integro:"
    printf '%s\n' "$res" | grep -i "failed\|fall" | head -n 10 | sed 's/^/    /'
    echo
    say "  ${C_RD}No confie en este respaldo para restaurar.${C_R}"
  elif [ "$est" -ne 0 ] && [ -z "$res" ]; then
    err "No se pudo comprobar."
  else
    ok "Respaldo integro: todas las huellas coinciden."
    printf '%s\n' "$res" | tail -n 5 | sed 's/^/    /'
  fi
  [ -n "${tmp:-}" ] && rm -rf "$tmp"
  enter
  return 0
}

# ===================== MIGRACION DE TRABAJOS =========================
# Actualizar el gestor NO actualiza los scripts ya generados: siguen en
# disco tal como se escribieron. Sin esto, un trabajo creado con una
# version anterior seguiria respaldando sin verificar nada.
migrar_trabajos() {
  local c tipo job metodo gen n=0 fallos=0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    grep -q "^GEN_VERSION=\"${GEN_VERSION_ACTUAL}\"" "$c" 2>/dev/null && continue
    grep -q '^VERIFICAR='   "$c" 2>/dev/null || set_conf "$c" VERIFICAR "si"
    if ! grep -q '^VERIFICAR_DESTINO=' "$c" 2>/dev/null; then
      if grep -q '^JOB_TIPO="drive"' "$c" 2>/dev/null; then
        set_conf "$c" VERIFICAR_DESTINO "hash"
      else
        set_conf "$c" VERIFICAR_DESTINO "basico"
      fi
    fi
    grep -q '^ESTADO_FILE=' "$c" 2>/dev/null || set_conf "$c" ESTADO_FILE "${c%.conf}.estado"
    tipo="$(sed -n 's/^JOB_TIPO="\(.*\)"$/\1/p'      "$c" | tail -n 1)"
    job="$(sed  -n 's/^JOB_NOMBRE="\(.*\)"$/\1/p'    "$c" | tail -n 1)"
    metodo="$(sed -n 's/^METODO_RED="\(.*\)"$/\1/p'  "$c" | tail -n 1)"
    if [ -n "$job" ]; then
      # Cada trabajo con SU generador: un trabajo por rclone regenerado
      # como CIFS intentaria montar y dejaria de respaldar.
      if [ "$tipo" = "red" ] && [ "$metodo" = "rclone" ]; then gen="generar_script_red_rclone"
      elif [ "$tipo" = "red" ]; then gen="generar_script_red"
      else gen="generar_script_drive"; fi
      if ! instalar_script "$gen" "$c" "${BIN_DIR}/${job}.sh"; then
        fallos=$((fallos+1)); continue   # el script anterior sigue intacto
      fi
      n=$((n+1))
    fi
    set_conf "$c" GEN_VERSION "$GEN_VERSION_ACTUAL"
  done < <(listar_confs)

  if [ "$fallos" -gt 0 ]; then
    pantalla "ACTUALIZACION DE TRABAJOS"
    err "No se pudo actualizar el script de ${fallos} trabajo(s)."
    say "  ${C_DIM}Siguen funcionando con su script anterior, que no se toco.${C_R}"
    enter
  fi
  [ "$n" -eq 0 ] && return 0
  pantalla "ACTUALIZACION DE TRABAJOS"
  ok "Se actualizaron ${n} trabajo(s) a la version ${GEN_VERSION_ACTUAL}."
  echo
  say "  A partir de ahora, antes de dar un respaldo por bueno se comprueba que"
  say "  el volcado se pueda abrir y que no haya quedado a la mitad. Si la"
  say "  comprobacion falla, el respaldo local no se borra y la retencion no se"
  say "  aplica, para no perder un respaldo bueno por uno danado."
  echo
  say "  ${C_DIM}Los horarios, destinos y retenciones no cambiaron.${C_R}"
  say "  ${C_DIM}La verificacion quedo en 'completa'; se puede ajustar desde${C_R}"
  say "  ${C_DIM}cada trabajo, en 'Que se respalda'.${C_R}"
  enter
  return 0
}

# ========================= MENU PRINCIPAL ============================
menu_principal() {
  local op n_trabajos n_cuentas n_fallos
  while true; do
    pantalla "MENU PRINCIPAL"
    n_trabajos="$(listar_confs | wc -l)"
    n_cuentas="$(rclone listremotes 2>/dev/null | wc -l)"
    n_fallos="$(trabajos_fallidos)"
    if [ "$n_fallos" -gt 0 ]; then
      say "  ${C_RD}${C_B}  ATENCION: ${n_fallos} trabajo(s) con el ultimo respaldo FALLIDO.${C_R}"
      say "  ${C_DIM}  Entre en 'Trabajos de respaldo' para ver cual y por que.${C_R}"
      echo
    fi
    say "   1) Trabajos de respaldo      ${C_DIM}-${C_R} ${n_trabajos} configurado(s)"
    say "   2) Cuentas de Google Drive   ${C_DIM}-${C_R} ${n_cuentas} conectada(s)"
    say "   3) Diagnostico"
    say "   0) Salir"
    echo
    say "  ${C_DIM}Cada trabajo es un destino independiente con su propio horario:${C_R}"
    say "  ${C_DIM}varios NAS y varias cuentas de Drive pueden convivir y coincidir.${C_R}"
    echo
    read -rp "  Opcion: " op || fin_entrada
    case "$op" in
      1) menu_trabajos;;
      2) menu_cuentas_drive;;
      3) diagnostico;;
      0) clear; say "  ${C_CY}iZone Enterprise - Backups${C_R}. Hasta luego.\n"; exit 0;;
      *) err "Opcion invalida."; sleep 1;;
    esac
  done
}

requiere_root
mkdir -p "$APP_DIR" "$LOG_DIR"; chmod 750 "$APP_DIR"
migrar_trabajos
menu_principal