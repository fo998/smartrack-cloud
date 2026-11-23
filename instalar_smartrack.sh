#!/usr/bin/env bash
# =============================================================================
#  SMART RACK - Instalador del servidor en la nube
#  Automatiza el "Script de configuración VPS" del curso (versión 21/09/2026):
#    usuario + sudo, SSH sin root, herramientas, zona horaria, ufw, Mosquitto,
#    Node.js + Node-RED, nginx como reverse proxy, htpasswd, Let's Encrypt.
#  Además: dominio dinámico (DuckDNS) y el dashboard del SmartRack.
#
#  Probado en Ubuntu Server 24.04 LTS (AWS EC2). También sirve en Debian 12.
#
#  Uso:
#     sudo ./instalar_smartrack.sh                  # usa ./config.env o /etc/smartrack/config.env
#     sudo ./instalar_smartrack.sh /ruta/config.env
#
#  Es idempotente: si algo falla, corrige y vuelve a ejecutarlo.
#  Registro completo en /var/log/smartrack-instalacion.log
# =============================================================================
set -Eeuo pipefail
shopt -u patsub_replacement 2>/dev/null || true

DIR_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=/var/log/smartrack-instalacion.log
CONF_SISTEMA=/etc/smartrack/config.env
NODE_MAYOR=24          # Node-RED 5 necesita Node.js >= 22.9 (la guía usa 20, que ya no sirve)
NODERED_MAYOR=5

# ----------------------------------------------------------------- utilidades
VERDE=$'\e[32m'; AMARILLO=$'\e[33m'; ROJO=$'\e[31m'; NEGRITA=$'\e[1m'; NORMAL=$'\e[0m'
paso()  { echo; echo "${NEGRITA}==> $*${NORMAL}"; }
ok()    { echo "    ${VERDE}✔${NORMAL} $*"; }
aviso() { echo "    ${AMARILLO}⚠ $*${NORMAL}"; }
error() { echo "${ROJO}✖ ERROR: $*${NORMAL}" >&2; exit 1; }
trap 'echo "${ROJO}✖ Falló la línea $LINENO: ${BASH_COMMAND}${NORMAL}" >&2; echo "  Revisa $LOG, corrige y vuelve a ejecutar el instalador." >&2' ERR

[[ $EUID -eq 0 ]] || error "Ejecuta con sudo:  sudo $0"
[[ -r /etc/os-release ]] && . /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) error "Sistema no soportado (${ID:-desconocido}). Usa Ubuntu 24.04 o Debian 12." ;; esac

touch "$LOG"; chmod 600 "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "=================== $(date '+%F %T') - instalación SmartRack ==================="

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt_instalar() { apt-get "${APT_OPTS[@]}" install --no-install-recommends "$@"; }
# Kernel sin IPv6: el sitio por defecto de nginx (listen [::]:80) impide que arranque
nginx_sin_ipv6() {
  if [[ ! -f /proc/net/if_inet6 && -f /etc/nginx/sites-available/default ]]; then
    sed -i '/listen \[::\]:80/d' /etc/nginx/sites-available/default
  fi
}
clave_azar()   { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 16; }

# ------------------------------------------------------------- configuración
ARCHIVO_CONFIG="${1:-}"
if [[ -z "$ARCHIVO_CONFIG" ]]; then
  for c in "$DIR_REPO/config.env" "$CONF_SISTEMA"; do
    if [[ -f "$c" ]]; then ARCHIVO_CONFIG="$c"; break; fi
  done
fi
[[ -n "$ARCHIVO_CONFIG" && -f "$ARCHIVO_CONFIG" ]] || \
  error "No encontré config.env. Ejecuta:  cp config.env.ejemplo config.env && nano config.env"
# shellcheck source=/dev/null
source "$ARCHIVO_CONFIG"
PROVISTAS=" "                          # claves que el usuario escribió en su config.env
for v in WEB_CLAVE NODERED_CLAVE MQTT_CLAVE; do
  if [[ -n "${!v:-}" ]]; then PROVISTAS+="$v "; fi
done
# Claves generadas al azar en una instalación anterior: se conservan (si no, el ESP32
# y los navegadores dejarían de funcionar al volver a ejecutar el instalador)
valor_previo() {
  # shellcheck source=/dev/null
  ( . "$CONF_SISTEMA" && printf '%s' "${!1:-}" )
}
if [[ -f "$CONF_SISTEMA" && "$ARCHIVO_CONFIG" != "$CONF_SISTEMA" ]]; then
  for v in NODERED_MQTT_CLAVE WEB_CLAVE NODERED_CLAVE MQTT_CLAVE CLAVES_GENERADAS; do
    if [[ -z "${!v:-}" ]]; then printf -v "$v" '%s' "$(valor_previo "$v")"; fi
  done
fi

: "${DOMINIO:=}" "${DUCKDNS_TOKEN:=}" "${EMAIL_CERTBOT:=}" "${CERTBOT_STAGING:=no}" "${CERTBOT_HSTS:=no}"
# Administradores (separados por espacio o coma). Compatibilidad: USUARIO_SO / CLAVE_USUARIO_SO
: "${USUARIOS_SO:=${USUARIO_SO:-smartrack}}" "${CLAVE_USUARIOS_SO:=${CLAVE_USUARIO_SO:-}}" "${SSH_CON_CLAVE:=si}"
USUARIOS_SO="$(echo "${USUARIOS_SO//,/ }" | xargs)"     # "a, b  c" -> "a b c"
read -r -a LISTA_USUARIOS <<< "$USUARIOS_SO"
: "${MQTT_USUARIO:=esp32}" "${MQTT_CLAVE:=}" "${MQTT_PERMITIR_ANONIMO:=no}"
: "${WEB_USUARIO:=admin}" "${WEB_CLAVE:=}" "${NODERED_USUARIO:=admin}" "${NODERED_CLAVE:=}"
: "${NODERED_MQTT_CLAVE:=}" "${ZONA_HORARIA:=America/Lima}" "${ACTUALIZAR_SO:=si}"
: "${FIREWALL_UFW:=si}" "${ACTUALIZAR_FLOWS:=no}"
DOMINIO="${DOMINIO,,}"; DOMINIO="${DOMINIO#http://}"; DOMINIO="${DOMINIO#https://}"; DOMINIO="${DOMINIO%%/*}"
if [[ "$DOMINIO" == "smartrack-grupo1.duckdns.org" && -z "$DUCKDNS_TOKEN" ]]; then
  error "DOMINIO sigue con el valor de ejemplo. Edita config.env."
fi

# Claves vacías -> se generan al azar y se recuerdan (CLAVES_GENERADAS) para mostrarlas al final
anteriores="${CLAVES_GENERADAS:-}"; CLAVES_GENERADAS=""
for v in WEB_CLAVE NODERED_CLAVE MQTT_CLAVE; do
  if [[ -z "${!v}" ]]; then
    printf -v "$v" '%s' "$(clave_azar)"
    CLAVES_GENERADAS+="$v "
  elif [[ " $anteriores " == *" $v "* && "$PROVISTAS" != *" $v "* ]]; then
    CLAVES_GENERADAS+="$v "           # generada en una instalación anterior
  fi
done
CLAVES_GENERADAS="${CLAVES_GENERADAS% }"
[[ -n "$NODERED_MQTT_CLAVE" ]] || NODERED_MQTT_CLAVE="$(clave_azar)"

re_usuario='^[a-z_][a-z0-9_-]{1,31}$'
re_clave='^[A-Za-z0-9_.@#%+=:,-]{6,64}$'
[[ ${#LISTA_USUARIOS[@]} -gt 0 ]] || error "USUARIOS_SO está vacío"
for u in "${LISTA_USUARIOS[@]}"; do
  [[ "$u" =~ $re_usuario ]] || error "Usuario inválido en USUARIOS_SO: '$u' (minúsculas, números, _ o -)"
  [[ "$u" != "root" && "$u" != "nodered" ]] || error "USUARIOS_SO no puede incluir '$u'"
done
[[ "$WEB_USUARIO" =~ $re_usuario ]]     || error "WEB_USUARIO inválido"
[[ "$NODERED_USUARIO" =~ $re_usuario ]] || error "NODERED_USUARIO inválido"
[[ "$MQTT_USUARIO" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || error "MQTT_USUARIO inválido"
for v in MQTT_CLAVE WEB_CLAVE NODERED_CLAVE; do
  [[ "${!v}" =~ $re_clave ]] || error "$v inválida: 6 a 64 caracteres; letras, números y _ . @ # % + = : , -"
done
[[ -z "$CLAVE_USUARIOS_SO" || "$CLAVE_USUARIOS_SO" =~ $re_clave ]] || error "CLAVE_USUARIOS_SO inválida"
if [[ -n "$DOMINIO" ]]; then
  [[ "$DOMINIO" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$ ]] || error "DOMINIO inválido: $DOMINIO"
fi

# Guardar la configuración final (con claves generadas) para las herramientas smartrack-*
guardar_config() {
  install -d -m 700 /etc/smartrack
  local tmp; tmp="$(mktemp /etc/smartrack/.config.XXXXXX)"
  {
    echo "# SmartRack - configuración efectiva ($(date '+%F %T')). Archivo solo para root."
    for v in DOMINIO DUCKDNS_TOKEN EMAIL_CERTBOT CERTBOT_STAGING CERTBOT_HSTS USUARIOS_SO \
             CLAVE_USUARIOS_SO SSH_CON_CLAVE \
             MQTT_USUARIO MQTT_CLAVE MQTT_PERMITIR_ANONIMO WEB_USUARIO WEB_CLAVE \
             NODERED_USUARIO NODERED_CLAVE NODERED_MQTT_CLAVE ZONA_HORARIA \
             ACTUALIZAR_SO FIREWALL_UFW ACTUALIZAR_FLOWS CLAVES_GENERADAS; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$CONF_SISTEMA"
}
guardar_config
ok "Configuración cargada desde $ARCHIVO_CONFIG (copia segura en $CONF_SISTEMA)"

# Node-RED corre con su propia cuenta de servicio (no depende de ninguna persona)
NR_HOME=/var/lib/nodered
NR_DIR="$NR_HOME/.node-red"

# =============================================================================
paso "1/10  Sistema base: actualizaciones, herramientas y zona horaria"
nginx_sin_ipv6
dpkg --configure -a          # termina instalaciones que quedaron a medias en un intento anterior
apt-get "${APT_OPTS[@]}" update
if [[ "$ACTUALIZAR_SO" == "si" ]]; then
  apt-get "${APT_OPTS[@]}" upgrade
fi
apt_instalar sudo tree wget nmap net-tools htop nano vim curl git jq ca-certificates gnupg \
             dnsutils openssl apache2-utils ufw cron logrotate
timedatectl set-timezone "$ZONA_HORARIA" 2>/dev/null || ln -sf "/usr/share/zoneinfo/$ZONA_HORARIA" /etc/localtime
ok "Paquetes instalados. Zona horaria: $ZONA_HORARIA ($(date '+%F %T %Z'))"

# =============================================================================
paso "2/10  Administradores con sudo y SSH sin root"
tmp_sudo="$(mktemp)"
echo "# SmartRack: administradores del servidor (guía: agregar usuario como root)" > "$tmp_sudo"
for u in "${LISTA_USUARIOS[@]}"; do
  nuevo=""
  if ! id "$u" &>/dev/null; then
    adduser --disabled-password --gecos "" "$u" >/dev/null
    nuevo=" (creado)"
  fi
  usermod -aG sudo "$u"
  if [[ -n "$CLAVE_USUARIOS_SO" ]]; then
    echo "$u:$CLAVE_USUARIOS_SO" | chpasswd
    echo "$u ALL=(ALL:ALL) ALL" >> "$tmp_sudo"            # sudo pide su contraseña
  else
    echo "$u ALL=(ALL:ALL) NOPASSWD:ALL" >> "$tmp_sudo"   # sin contraseña no habría cómo usar sudo
  fi
  # Misma llave SSH que el usuario por defecto de la imagen (en AWS Academy: labsuser.pem)
  for base in ubuntu admin debian; do
    if [[ "$base" != "$u" && -s "/home/$base/.ssh/authorized_keys" ]]; then
      install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh"
      touch "/home/$u/.ssh/authorized_keys"
      sort -u "/home/$base/.ssh/authorized_keys" "/home/$u/.ssh/authorized_keys" -o "/home/$u/.ssh/authorized_keys"
      chown "$u:$u" "/home/$u/.ssh/authorized_keys"
      chmod 600 "/home/$u/.ssh/authorized_keys"
      break
    fi
  done
  ok "$u$nuevo: administrador (sudo)"
done
install -m 440 "$tmp_sudo" /etc/sudoers.d/90-smartrack
rm -f "$tmp_sudo"
visudo -cf /etc/sudoers.d/90-smartrack >/dev/null

# root: sin login por SSH y sin contraseña (los administradores usan sudo)
passwd -l root >/dev/null
clave_ssh=no
if [[ "$SSH_CON_CLAVE" == "si" && -n "$CLAVE_USUARIOS_SO" ]]; then clave_ssh=yes; fi
install -d /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-smartrack.conf <<FIN_SSH
# SmartRack. Se lee antes que 50-cloud-init.conf y 60-cloudimg-settings.conf, así que manda.
# Bloqueo de acceso por root (guía del curso)
PermitRootLogin no
# Entrar con usuario + contraseña además de la llave .pem (protegido con fail2ban)
PasswordAuthentication $clave_ssh
FIN_SSH
install -d -m 755 /run/sshd
if command -v sshd >/dev/null && sshd -t; then
  systemctl try-reload-or-restart ssh 2>/dev/null || systemctl try-reload-or-restart sshd 2>/dev/null || true
  ok "SSH: PermitRootLogin no · PasswordAuthentication $clave_ssh · contraseña de root bloqueada"
fi

# =============================================================================
paso "3/10  Firewall (ufw) y fail2ban"
if [[ "$FIREWALL_UFW" == "si" ]]; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow OpenSSH >/dev/null
  ufw allow 80/tcp comment 'HTTP' >/dev/null
  ufw allow 443/tcp comment 'HTTPS' >/dev/null
  ufw allow 1883/tcp comment 'MQTT' >/dev/null
  ufw --force enable >/dev/null
  ok "ufw activo: 22, 80, 443, 1883 (Node-RED 1880 queda solo detrás de nginx)"
else
  aviso "ufw desactivado por configuración (solo protege el Security Group de AWS)"
fi
# fail2ban: bloquea 1 h la IP que falle 5 veces el login SSH en 10 min
apt_instalar fail2ban python3-systemd
cat > /etc/fail2ban/jail.d/smartrack.local <<'FIN_F2B'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
FIN_F2B
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2
if fail2ban-client status sshd >/dev/null 2>&1; then
  ok "fail2ban vigila SSH (5 intentos fallidos = 1 h bloqueado)"
else
  aviso "fail2ban no arrancó: revisa  sudo journalctl -u fail2ban -n 30"
fi

# =============================================================================
paso "4/10  Broker MQTT (Mosquitto)"
apt_instalar mosquitto mosquitto-clients
install -d -m 755 /etc/mosquitto/conf.d
anonimo=false; [[ "$MQTT_PERMITIR_ANONIMO" == "si" ]] && anonimo=true
cat > /etc/mosquitto/conf.d/smartrack.conf <<EOF
# SmartRack - generado por instalar_smartrack.sh
# (persistencia y log ya vienen en /etc/mosquitto/mosquitto.conf)

# MQTT normal: lo usa el ESP32 (y MQTT Explorer / MQTTX desde tu PC)
listener 1883 0.0.0.0

# MQTT sobre WebSocket, solo local. nginx lo publica como wss://DOMINIO/mqtt
listener 9001 127.0.0.1
protocol websockets

# Seguridad: con IP pública no conviene permitir usuarios anónimos
allow_anonymous $anonimo
password_file /etc/mosquitto/passwd
EOF
tmp_pw="$(mktemp)"
mosquitto_passwd -c -b "$tmp_pw" "$MQTT_USUARIO" "$MQTT_CLAVE"
mosquitto_passwd -b "$tmp_pw" nodered "$NODERED_MQTT_CLAVE"
if [[ "$WEB_USUARIO" != "$MQTT_USUARIO" ]]; then
  mosquitto_passwd -b "$tmp_pw" "$WEB_USUARIO" "$WEB_CLAVE"
fi
install -m 600 -o mosquitto -g mosquitto "$tmp_pw" /etc/mosquitto/passwd
rm -f "$tmp_pw"
systemctl enable mosquitto >/dev/null 2>&1
systemctl restart mosquitto
sleep 1
systemctl is-active --quiet mosquitto || { journalctl -u mosquitto -n 20 --no-pager; error "Mosquitto no arrancó"; }
ok "Mosquitto escuchando en 1883 (usuarios: $MQTT_USUARIO, nodered, $WEB_USUARIO)"

# =============================================================================
paso "5/10  Node.js $NODE_MAYOR"
version_node() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
if [[ "$(version_node)" -lt 22 ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAYOR}.x" -o /tmp/nodesource_setup.sh
  bash /tmp/nodesource_setup.sh
  apt_instalar nodejs
fi
[[ "$(version_node)" -ge 22 ]] || error "No se pudo instalar Node.js >= 22"
ok "Node.js $(node -v), npm $(npm -v)"

# =============================================================================
paso "6/10  Node-RED $NODERED_MAYOR (servicio systemd, en lugar de pm2)"
if ! command -v node-red >/dev/null || ! node-red --version 2>/dev/null | grep -q "Node-RED v${NODERED_MAYOR}\."; then
  npm install -g --unsafe-perm --no-audit --no-fund "node-red@${NODERED_MAYOR}"
fi
NR_BIN="$(command -v node-red)"
NR_MODULO="$(npm root -g)/node-red"
if ! id nodered &>/dev/null; then
  adduser --system --group --home "$NR_HOME" --shell /usr/sbin/nologin nodered >/dev/null
fi
install -d -m 750 -o nodered -g nodered "$NR_HOME" "$NR_DIR"

# Hash bcrypt de una clave (equivale a "node-red admin hash-pw" de la guía)
hash_nodered() {
  local h
  h="$(CLAVE="$1" node -e '
    const b = require(require.resolve("bcryptjs", { paths: [process.argv[1]] }));
    console.log(b.hashSync(process.env.CLAVE, 8));' "$NR_MODULO")"
  [[ "$h" == \$2* ]] || error "No se pudo generar el hash de una clave de Node-RED"
  echo "$h"
}
# Usuarios del editor: la cuenta NODERED_USUARIO + cada administrador de USUARIOS_SO
# con la contraseña de administradores (CLAVE_USUARIOS_SO)
linea_usuario() { printf "            { username: '%s', password: '%s', permissions: '*' }" "$1" "$2"; }
USUARIOS_EDITOR="$NODERED_USUARIO"; EDITOR_EXTRA=""
usuarios_js="$(linea_usuario "$NODERED_USUARIO" "$(hash_nodered "$NODERED_CLAVE")")"
if [[ -n "$CLAVE_USUARIOS_SO" ]]; then
  hash_admins="$(hash_nodered "$CLAVE_USUARIOS_SO")"
  for u in "${LISTA_USUARIOS[@]}"; do
    if [[ "$u" == "$NODERED_USUARIO" ]]; then continue; fi
    usuarios_js+=$',\n'"$(linea_usuario "$u" "$hash_admins")"
    USUARIOS_EDITOR+=", $u"; EDITOR_EXTRA+="${EDITOR_EXTRA:+, }$u"
  done
fi

settings="$(<"$DIR_REPO/nodered/settings.js")"
settings="${settings//__USUARIOS_EDITOR__/"$usuarios_js"}"
printf '%s\n' "$settings" > "$NR_DIR/settings.js"
node -e 'require(process.argv[1])' "$NR_DIR/settings.js" || error "settings.js de Node-RED quedó con errores"
ok "Usuarios del editor Node-RED: $USUARIOS_EDITOR"

if [[ ! -f "$NR_DIR/flows.json" ]]; then
  cp "$DIR_REPO/nodered/flows.json" "$NR_DIR/flows.json"
  ok "Flujos SmartRack instalados"
elif [[ "$ACTUALIZAR_FLOWS" == "si" ]]; then
  cp "$NR_DIR/flows.json" "$NR_DIR/flows.respaldo-$(date +%Y%m%d-%H%M%S).json"
  cp "$DIR_REPO/nodered/flows.json" "$NR_DIR/flows.json"
  ok "Flujos actualizados (respaldo guardado en $NR_DIR)"
else
  aviso "Se conservan tus flujos actuales (ACTUALIZAR_FLOWS=no)"
fi
# Credenciales del broker para el nodo MQTT (id fijo definido en flows.json)
jq -n --arg u nodered --arg p "$NODERED_MQTT_CLAVE" \
  '{"5a17c0de00000001": {user: $u, password: $p}}' > "$NR_DIR/flows_cred.json"
chown -R nodered:nodered "$NR_HOME"
chmod 600 "$NR_DIR/settings.js" "$NR_DIR/flows_cred.json"

cat > /etc/systemd/system/nodered.service <<EOF
[Unit]
Description=Node-RED (SmartRack)
After=network-online.target mosquitto.service
Wants=network-online.target

[Service]
Type=simple
User=nodered
Group=nodered
WorkingDirectory=$NR_HOME
Environment="NODE_OPTIONS=--max-old-space-size=384"
Environment="TZ=$ZONA_HORARIA"
ExecStart=$NR_BIN --userDir $NR_DIR
Restart=on-failure
RestartSec=5
KillSignal=SIGINT
SyslogIdentifier=node-red

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable nodered >/dev/null 2>&1
systemctl restart nodered
for _ in $(seq 1 60); do
  curl -fs -o /dev/null http://127.0.0.1:1880/api/estado && break
  sleep 2
done
curl -fs -o /dev/null http://127.0.0.1:1880/api/estado || {
  journalctl -u nodered -n 40 --no-pager; error "Node-RED no responde en 127.0.0.1:1880"; }
ok "Node-RED activo en 127.0.0.1:1880 (editor en /admin, API en /api)"

# =============================================================================
paso "7/10  Dashboard web"
install -d -m 755 /var/www/smartrack
install -m 644 "$DIR_REPO/dashboard/index.html" /var/www/smartrack/index.html
ok "Dashboard copiado a /var/www/smartrack"

# =============================================================================
paso "8/10  nginx (reverse proxy) + usuarios web (htpasswd)"
if ! apt_instalar nginx; then
  [[ -f /proc/net/if_inet6 ]] && error "No se pudo instalar nginx"
  nginx_sin_ipv6
  dpkg --configure -a
fi
# server_names_hash_bucket_size 64 (como indica la guía)
if grep -Eq '^\s*#\s*server_names_hash_bucket_size' /etc/nginx/nginx.conf; then
  sed -i -E 's/^(\s*)#\s*server_names_hash_bucket_size.*/\1server_names_hash_bucket_size 64;/' /etc/nginx/nginx.conf
elif ! grep -Eq '^\s*server_names_hash_bucket_size' /etc/nginx/nginx.conf; then
  echo 'server_names_hash_bucket_size 64;' > /etc/nginx/conf.d/00-hash-bucket.conf
fi
# Sin -c si ya existe: así no se borran usuarios extra que hayas agregado con htpasswd
if [[ -f /etc/nginx/lista_passwd ]]; then
  htpasswd -b /etc/nginx/lista_passwd "$WEB_USUARIO" "$WEB_CLAVE"
else
  htpasswd -c -b /etc/nginx/lista_passwd "$WEB_USUARIO" "$WEB_CLAVE"
fi
chown root:www-data /etc/nginx/lista_passwd; chmod 640 /etc/nginx/lista_passwd
rm -f /etc/nginx/sites-enabled/default

NOMBRE_SERVIDOR="${DOMINIO:-_}"
ESCUCHA_IPV6=""
if [[ -f /proc/net/if_inet6 ]]; then ESCUCHA_IPV6="listen [::]:80 default_server;"; fi
cat > /etc/nginx/conf.d/smartrack.conf <<EOF
# SmartRack - generado por instalar_smartrack.sh
# Certbot agrega aquí el bloque HTTPS (puerto 443) automáticamente.
map \$http_upgrade \$smartrack_connection {
    default upgrade;
    ''      close;
}

server {
    listen 80 default_server;
    $ESCUCHA_IPV6
    server_name $NOMBRE_SERVIDOR;

    root /var/www/smartrack;
    index index.html;
    access_log /var/log/nginx/smartrack_access.log;
    error_log  /var/log/nginx/smartrack_error.log;
    client_max_body_size 20M;

    gzip on;
    gzip_comp_level 5;
    gzip_proxied any;
    gzip_min_length 1100;
    gzip_types text/plain text/css application/javascript application/json text/csv image/svg+xml;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy same-origin always;

    # Comprobación rápida (sin login):  curl http://DOMINIO/salud
    location = /salud {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }

    # DASHBOARD del SmartRack (login con /etc/nginx/lista_passwd)
    location / {
        auth_basic "SmartRack - Acceso";
        auth_basic_user_file /etc/nginx/lista_passwd;
        expires -1;
        try_files \$uri \$uri/ =404;
    }

    # API que usa el dashboard -> flujos de Node-RED
    location /api/ {
        auth_basic "SmartRack - Acceso";
        auth_basic_user_file /etc/nginx/lista_passwd;
        proxy_pass http://127.0.0.1:1880/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Usuario \$remote_user;
    }

    # EDITOR de Node-RED (tiene su propio login)
    location = /admin { return 301 /admin/; }
    location /admin/ {
        proxy_pass http://127.0.0.1:1880/admin/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$smartrack_connection;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }

    # MQTT sobre WebSocket (MQTT Explorer, MQTTX web, apps móviles)
    location /mqtt {
        proxy_pass http://127.0.0.1:9001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
EOF
nginx -t
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
ok "nginx activo: / (dashboard), /api/ (Node-RED), /admin/ (editor), /mqtt (WebSocket)"

# =============================================================================
paso "9/10  Herramientas smartrack-* y dominio dinámico"
for h in smartrack-ip-publica smartrack-duckdns smartrack-https smartrack-estado smartrack-simular; do
  install -m 755 "$DIR_REPO/herramientas/$h" "/usr/local/bin/$h"
done
ok "Instaladas: smartrack-estado, smartrack-simular, smartrack-https, smartrack-duckdns"

if [[ -n "$DUCKDNS_TOKEN" && "$DOMINIO" == *.duckdns.org ]]; then
  cat > /etc/systemd/system/smartrack-duckdns.service <<'EOF'
[Unit]
Description=SmartRack - actualizar IP en DuckDNS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/smartrack-duckdns
EOF
  cat > /etc/systemd/system/smartrack-duckdns.timer <<'EOF'
[Unit]
Description=SmartRack - DuckDNS al arrancar y cada 5 minutos

[Timer]
OnBootSec=20s
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now smartrack-duckdns.timer >/dev/null 2>&1
  if /usr/local/bin/smartrack-duckdns; then
    ok "DuckDNS: $DOMINIO -> $(/usr/local/bin/smartrack-ip-publica || echo '?')"
  else
    aviso "DuckDNS no respondió OK. Revisa DUCKDNS_TOKEN y que el subdominio exista en duckdns.org"
  fi
elif [[ -n "$DOMINIO" ]]; then
  aviso "Dominio sin DuckDNS: apunta el registro A de $DOMINIO a $(/usr/local/bin/smartrack-ip-publica || echo 'la IP pública')"
fi

# =============================================================================
paso "10/10  HTTPS con Let's Encrypt"
if [[ -n "$DOMINIO" ]]; then
  apt_instalar certbot python3-certbot-nginx
  if /usr/local/bin/smartrack-https; then
    ok "HTTPS activo para $DOMINIO (renovación automática con certbot.timer)"
  else
    aviso "No se pudo obtener el certificado ahora. El sitio queda en HTTP."
    aviso "Cuando el dominio apunte a este servidor ejecuta:  sudo smartrack-https"
  fi
else
  aviso "Sin DOMINIO: se omite HTTPS. El dashboard queda en http://IP_PUBLICA/"
fi

# =============================================================================
IP_PUBLICA="$(/usr/local/bin/smartrack-ip-publica || echo 'IP_PUBLICA')"
if [[ -n "$DOMINIO" ]]; then HOST="$DOMINIO"; else HOST="$IP_PUBLICA"; fi
if [[ -n "$DOMINIO" && -d "/etc/letsencrypt/live/$DOMINIO" ]]; then ESQ=https; else ESQ=http; fi
mostrar_clave() {
  if [[ " $CLAVES_GENERADAS " == *" $1 "* ]]; then echo "${!1}  (generada al azar)"; else echo "(la de tu config.env)"; fi
}

LINEA_EDITOR_EXTRA=""
if [[ -n "$EDITOR_EXTRA" ]]; then
  LINEA_EDITOR_EXTRA=$'\n'"                      también: $EDITOR_EXTRA (contraseña de administradores)"
fi
cat <<EOF

${VERDE}${NEGRITA}=====================================================================
  SMART RACK listo  ($(date '+%F %T'))
=====================================================================${NORMAL}
  IP pública ........ $IP_PUBLICA
  Dashboard ......... $ESQ://$HOST/           usuario: $WEB_USUARIO   clave: $(mostrar_clave WEB_CLAVE)
  Editor Node-RED ... $ESQ://$HOST/admin/     usuario: $NODERED_USUARIO   clave: $(mostrar_clave NODERED_CLAVE)${LINEA_EDITOR_EXTRA}
  MQTT (ESP32) ...... $HOST : 1883             usuario: $MQTT_USUARIO   clave: $(mostrar_clave MQTT_CLAVE)
  MQTT WebSocket .... ${ESQ/http/ws}://$HOST/mqtt   (usuario/clave del dashboard)
  SSH ............... ssh ${LISTA_USUARIOS[0]}@$HOST   (o con llave: ssh -i labsuser.pem ${LISTA_USUARIOS[0]}@$HOST)
  Administradores ... ${USUARIOS_SO// /, }   (sudo · root bloqueado)

  En el ESP32:  MQTT_HOST = "$HOST";  MQTT_USER / MQTT_PASSWORD = los de MQTT arriba
  Comandos útiles:  smartrack-estado  |  sudo smartrack-simular  |  sudo smartrack-https
  Configuración guardada en $CONF_SISTEMA (solo root)
=====================================================================
EOF
