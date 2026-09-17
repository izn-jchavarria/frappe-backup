#!/usr/bin/env bash
# =====================================================================
#  iZONE ENTERPRISE - BACKUPS
#  Gestor de respaldos para Frappe / ERPNext
#  Destinos soportados: Unidad de Red (CIFS) y Google Drive (rclone)
#  Version: 2.1.3
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

asegurar_paquete() {
  local pkg="$1" cmd="$2"
  command -v "$cmd" >/dev/null 2>&1 && { ok "'$pkg' ya esta instalado."; return 0; }
  info "Instalando '$pkg'..."
  apt-get update -qq && apt-get install -y "$pkg" >/dev/null 2>&1
  if command -v "$cmd" >/dev/null 2>&1; then ok "'$pkg' instalado."; return 0
  else err "No se pudo instalar '$pkg'."; return 1; fi
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
  return 0
}

pedir_retencion() {
  local v
  while true; do
    say "  ${C_DIM}Dias que se conservan los respaldos en el destino. 0 = no borrar nada.${C_R}"
    read -rp "  Dias de retencion: " v || fin_entrada
    _nav_check "$v"; local n=$?
    [ "$n" -ne 0 ] && return "$n"
    [[ "$v" =~ ^[0-9]+$ ]] && { RETENCION_DIAS="$v"; return 0; }
    err "Escriba un numero entero (0 o mayor)."
  done
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
generar_script_red() {
  cat > "$2" <<EOF
#!/usr/bin/env bash
# Generado por iZone ENTERPRISE - BACKUPS  -  destino: Unidad de Red (CIFS)
# La configuracion vive en el .conf; no edite valores aqui.
CONF="$1"
EOF
  cat >> "$2" <<'EOF'
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -r "$CONF" ] || { echo "[ERROR] No se encuentra la configuracion: $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FECHA="$(date +'%d-%B-%Y' | tr '[:upper:]' '[:lower:]')"
HORA="$(date +'%H-%M')"
DESTINO_FINAL="${MOUNT_POINT}/${FECHA}/${HORA}"

if ! mountpoint -q "$MOUNT_POINT"; then
  log "[AVISO] $MOUNT_POINT no esta montado. Intentando montar..."
  mount "$MOUNT_POINT" >/dev/null 2>&1
fi
mountpoint -q "$MOUNT_POINT" || { log "[ERROR] $MOUNT_POINT no esta montado. Abortando."; exit 1; }

mkdir -p "$DESTINO_FINAL" || { log "[ERROR] No se pudo crear $DESTINO_FINAL"; exit 1; }

cd "$BENCH_PATH" || { log "[ERROR] No existe $BENCH_PATH"; exit 1; }
# shellcheck disable=SC1091
. env/bin/activate
BENCH_ARGS=(--site "$SITE" backup)
[ "${WITH_FILES:-si}" = "si" ] && BENCH_ARGS+=(--with-files)
bench "${BENCH_ARGS[@]}" >/dev/null 2>&1 || { log "[ERROR] 'bench backup' fallo para $SITE"; exit 2; }

if rsync -a --remove-source-files "${BACKUP_ORIGEN}/" "${DESTINO_FINAL}/"; then
  log "[OK] Respaldo completado en $DESTINO_FINAL"
else
  log "[ERROR] Fallo la copia hacia $DESTINO_FINAL"; exit 3
fi
find "$BACKUP_ORIGEN" -mindepth 1 -type d -empty -delete 2>/dev/null

if [ "${RETENCION_DIAS:-0}" -gt 0 ] 2>/dev/null; then
  find "$MOUNT_POINT" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENCION_DIAS" -exec rm -rf {} + 2>/dev/null
  log "[INFO] Retencion aplicada: mas de ${RETENCION_DIAS} dias"
fi
exit 0
EOF
  chmod 750 "$2"
}

generar_script_drive() {
  cat > "$2" <<EOF
#!/usr/bin/env bash
# Generado por iZone ENTERPRISE - BACKUPS  -  destino: Google Drive (rclone)
# La configuracion vive en el .conf; no edite valores aqui.
CONF="$1"
EOF
  cat >> "$2" <<'EOF'
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
[ -r "$CONF" ] || { echo "[ERROR] No se encuentra la configuracion: $CONF"; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
export RCLONE_CONFIG="${RCLONE_CONFIG:-/root/.config/rclone/rclone.conf}"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

FECHA="$(date +'%d-%B-%Y' | tr '[:upper:]' '[:lower:]')"
HORA="$(date +'%H-%M')"
DESTINO="${RCLONE_REMOTE}:${DEST_PATH}/${FECHA}/${HORA}"

mkdir -p "$TEMP_LOCAL" || { log "[ERROR] No se pudo crear $TEMP_LOCAL"; exit 1; }
rm -rf "${TEMP_LOCAL:?}"/*

cd "$BENCH_PATH" || { log "[ERROR] No existe $BENCH_PATH"; exit 1; }
# shellcheck disable=SC1091
. env/bin/activate
BENCH_ARGS=(--site "$SITE" backup)
[ "${WITH_FILES:-si}" = "si" ] && BENCH_ARGS+=(--with-files)
bench "${BENCH_ARGS[@]}" >/dev/null 2>&1 || { log "[ERROR] 'bench backup' fallo para $SITE"; exit 2; }

if [ -d "$BACKUP_ORIGEN" ] && [ -n "$(ls -A "$BACKUP_ORIGEN" 2>/dev/null)" ]; then
  cp -r "$BACKUP_ORIGEN"/* "$TEMP_LOCAL"/ || { log "[ERROR] No se pudo copiar a $TEMP_LOCAL"; exit 3; }
  if rclone copy "$TEMP_LOCAL" "$DESTINO" \
       --contimeout 30s --timeout 5m --retries 3 --low-level-retries 10 \
       --log-file="$RCLONE_LOG" --log-level INFO; then
    log "[OK] Respaldo subido a $DESTINO"
    [ "${BORRAR_ORIGEN:-si}" = "si" ] && rm -rf "${BACKUP_ORIGEN:?}"/*
  else
    log "[ERROR] Fallo la subida hacia $DESTINO"
    rm -rf "${TEMP_LOCAL:?}"/*; exit 4
  fi
else
  log "[ERROR] No se encontraron archivos en $BACKUP_ORIGEN"; exit 5
fi
rm -rf "${TEMP_LOCAL:?}"/*

if [ "${RETENCION_DIAS:-0}" -gt 0 ] 2>/dev/null; then
  rclone delete "${RCLONE_REMOTE}:${DEST_PATH}" --min-age "${RETENCION_DIAS}d" \
    --log-file="$RCLONE_LOG" --log-level INFO
  rclone rmdirs "${RCLONE_REMOTE}:${DEST_PATH}" --leave-root \
    --log-file="$RCLONE_LOG" --log-level INFO
  log "[INFO] Retencion aplicada en Drive: mas de ${RETENCION_DIAS} dias"
fi
exit 0
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
  local BENCH_PATH="" SITE="" BACKUP_ORIGEN="" WITH_FILES=""
  local RETENCION_DIAS="" HORARIOS="" DIAS_CRON=""
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
  pantalla "NUEVO TRABAJO  >  Unidad de Red (CIFS)   [1 de 10]"
  if ! command -v mount.cifs >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
    info "Verificando dependencias..."
    asegurar_paquete cifs-utils mount.cifs || {
      err "Sin cifs-utils el servidor no puede montar carpetas de red."
      enter; return 3; }
    asegurar_paquete rsync rsync || { enter; return 3; }
    echo
  fi
  aviso_navegacion
  pedir_etiqueta || return $?
  CONF="${APP_DIR}/${JOB}.conf"; SCRIPT="${BIN_DIR}/${JOB}.sh"
  CRED_FILE="${APP_DIR}/${JOB}.cred"; LOG_FILE="${LOG_DIR}/${JOB}.log"
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
    say "   ${C_B}6${C_R}) Conexion      : ${UNC}   SMB ${SMB_VERS}   en ${MOUNT_POINT}"
    say "   ${C_B}7${C_R}) Sitio         : ${SITE}   adjuntos: ${WITH_FILES}"
    say "   ${C_B}8${C_R}) Retencion     : ${RETENCION_DIAS} dias"
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

  fstab_escribir "$JOB" "$UNC" "$MOUNT_POINT" "$MOUNT_OPTS"
  pantalla "TRABAJO '${ETIQUETA}'  >  Resultado"
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

  guardar_conf "$CONF" \
    "JOB_TIPO=red" "JOB_NOMBRE=${JOB}" "ETIQUETA=${ETIQUETA}" \
    "SERVIDOR=${SRV}" "SMB_PORT=${SMB_PORT}" "RECURSO=${SHARE}" "SUBCARPETA=${SUB}" \
    "UNC=${UNC}" "MOUNT_POINT=${MOUNT_POINT}" "CRED_FILE=${CRED_FILE}" \
    "SMB_VERS=${SMB_VERS}" "MOUNT_OPTS=${MOUNT_OPTS}" \
    "BENCH_PATH=${BENCH_PATH}" "SITE=${SITE}" "BACKUP_ORIGEN=${BACKUP_ORIGEN}" \
    "WITH_FILES=${WITH_FILES}" "RETENCION_DIAS=${RETENCION_DIAS}" \
    "HORARIOS=${HORARIOS}" "DIAS_CRON=${DIAS_CRON}" "LOG_FILE=${LOG_FILE}"

  generar_script_red "$CONF" "$SCRIPT"
  touch "$LOG_FILE"; chmod 640 "$LOG_FILE"
  reprogramar "$CONF"

  echo; hr
  ok "Trabajo '${JOB}' creado."
  say "    script : ${SCRIPT}"
  say "    config : ${CONF}"
  say "    log    : ${LOG_FILE}"
  say "    horario: ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))"
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

  local ETIQUETA="" JOB="" CONF="" SCRIPT="" LOG_FILE="" RCLONE_LOG=""
  local RCLONE_REMOTE="" DEST_PATH="" TEMP_LOCAL=""
  local BENCH_PATH="" SITE="" BACKUP_ORIGEN="" WITH_FILES="" BORRAR_ORIGEN="si"
  local RETENCION_DIAS="" HORARIOS="" DIAS_CRON=""
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
    say "   ${C_B}5${C_R}) Sitio         : ${SITE}   adjuntos: ${WITH_FILES}"
    say "   ${C_B}6${C_R}) Borrar local  : ${BORRAR_ORIGEN}"
    say "   ${C_B}7${C_R}) Retencion     : ${RETENCION_DIAS} dias"
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
    "WITH_FILES=${WITH_FILES}" "BORRAR_ORIGEN=${BORRAR_ORIGEN}" \
    "RETENCION_DIAS=${RETENCION_DIAS}" \
    "HORARIOS=${HORARIOS}" "DIAS_CRON=${DIAS_CRON}" \
    "LOG_FILE=${LOG_FILE}" "RCLONE_LOG=${RCLONE_LOG}"

  generar_script_drive "$CONF" "$SCRIPT"
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
  if [ "$JOB_TIPO" = "red" ]; then
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
    pantalla "TRABAJO: ${ETIQUETA}  [${JOB_TIPO}]"
    if [ "$JOB_TIPO" = "red" ]; then
      say "  Destino : ${UNC}"
      mountpoint -q "$MOUNT_POINT" \
        && say "  Montaje : ${C_GR}activo${C_R} en ${MOUNT_POINT}" \
        || say "  Montaje : ${C_RD}inactivo${C_R} en ${MOUNT_POINT}"
    else
      say "  Destino : ${RCLONE_REMOTE}:${DEST_PATH}"
    fi
    say "  Sitio   : ${SITE}   adjuntos: ${WITH_FILES}   retencion: ${RETENCION_DIAS} dias"
    say "  Horario : ${HORARIOS}   ($(describir_dias "$DIAS_CRON"))"
    echo
    say "   1) Ejecutar respaldo ahora"
    say "   2) Horarios y dias"
    say "   3) Destino"
    say "   4) Que se respalda (bench, sitio, adjuntos)"
    say "   5) Retencion"
    say "   6) Ver configuracion y log"
    if [ "$JOB_TIPO" = "red" ]; then
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
      3) if [ "$JOB_TIPO" = "red" ]; then
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
         if pedir_frappe; then
           set_conf "$conf" BENCH_PATH "$BENCH_PATH"; set_conf "$conf" SITE "$SITE"
           set_conf "$conf" BACKUP_ORIGEN "$BACKUP_ORIGEN"; set_conf "$conf" WITH_FILES "$WITH_FILES"
           ok "Actualizado."
         fi; enter;;
      5) pantalla "TRABAJO '${ETIQUETA}'  >  Retencion"
         pedir_retencion
         set_conf "$conf" RETENCION_DIAS "$RETENCION_DIAS"
         ok "Retencion actualizada a ${RETENCION_DIAS} dias."; enter;;
      6) pantalla "TRABAJO '${ETIQUETA}'  >  Configuracion"
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
         umount "$MOUNT_POINT" >/dev/null 2>&1
         sal2="$(mount "$MOUNT_POINT" 2>&1)"
         mountpoint -q "$MOUNT_POINT" && ok "Montaje validado." || explicar_error_mount "$sal2"
         enter;;
      8) if [ "$JOB_TIPO" != "red" ]; then err "Opcion invalida."; sleep 1; continue; fi
         pantalla "TRABAJO '${ETIQUETA}'  >  Montar"
         systemctl daemon-reload >/dev/null 2>&1
         sal3="$(mount "$MOUNT_POINT" 2>&1)"
         if mountpoint -q "$MOUNT_POINT"; then
           ok "Montado."; df -h "$MOUNT_POINT" | tail -n1 | sed 's/^/    /'
         else explicar_error_mount "$sal3"; fi
         enter;;
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
          local destino estado
          if [ "$JOB_TIPO" = "red" ]; then
            destino="$UNC"
            mountpoint -q "$MOUNT_POINT" && estado="${C_GR}montado${C_R}" || estado="${C_RD}sin montar${C_R}"
          else
            destino="${RCLONE_REMOTE}:${DEST_PATH}"; estado="${C_DIM}nube${C_R}"
          fi
          printf '%b\n' "   ${C_B}$((i+1))) ${ETIQUETA}${C_R}  ${C_DIM}[${JOB_TIPO}]${C_R}  ${estado}"
          printf '%b\n' "       ${C_DIM}destino: ${destino}${C_R}"
          printf '%b\n' "       ${C_DIM}horario: ${HORARIOS}  ($(describir_dias "$DIAS_CRON"))${C_R}"
        )
      done
    fi
    echo
    say "   ${C_B}r${C_R}) Nuevo trabajo hacia una Unidad de Red (CIFS)"
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
      say "  ${C_B}${C_CY}== ${ETIQUETA}  [${JOB_TIPO}] ==${C_R}"
      if [ "$JOB_TIPO" = "red" ]; then
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

# ========================= MENU PRINCIPAL ============================
menu_principal() {
  local op n_trabajos n_cuentas
  while true; do
    pantalla "MENU PRINCIPAL"
    n_trabajos="$(listar_confs | wc -l)"
    n_cuentas="$(rclone listremotes 2>/dev/null | wc -l)"
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
menu_principal
