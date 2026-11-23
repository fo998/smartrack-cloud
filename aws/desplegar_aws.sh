#!/usr/bin/env bash
# =============================================================================
#  SMART RACK - Crear todo en AWS con un solo comando (CloudFormation)
#
#  Requisitos: AWS CLI con credenciales válidas.
#   - AWS Academy: usa la terminal del laboratorio (ya trae la CLI configurada), o
#     copia "AWS Details > AWS CLI" a ~/.aws/credentials en tu PC (cambian cada sesión).
#  Uso (desde la carpeta smartrack-cloud):
#     ./aws/desplegar_aws.sh            crea / actualiza la pila
#     ./aws/desplegar_aws.sh borrar     elimina todo (VPC, servidor, etc.)
#     ./aws/desplegar_aws.sh estado     muestra las URLs
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f config.env ]] || { echo "Falta config.env:  cp config.env.ejemplo config.env && nano config.env"; exit 1; }
# shellcheck source=/dev/null
source config.env
command -v aws >/dev/null || { echo "No encuentro la AWS CLI (comando 'aws')."; exit 1; }

PILA="${PILA_AWS:-smartrack}"
REGION="${REGION_AWS:-us-east-1}"
PLANTILLA="aws/smartrack-stack.yaml"

mostrar_salidas() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$PILA" \
    --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output table
}

case "${1:-crear}" in
  borrar)
    aws cloudformation delete-stack --region "$REGION" --stack-name "$PILA"
    echo "Borrando la pila '$PILA'..."
    aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$PILA"
    echo "✔ Pila eliminada."
    exit 0 ;;
  estado)
    mostrar_salidas; exit 0 ;;
  crear) ;;
  *) echo "Uso: $0 [crear|estado|borrar]"; exit 1 ;;
esac

: "${REPO_GIT:?Agrega REPO_GIT=https://github.com/tu_usuario/smartrack-cloud.git en config.env}"
for v in MQTT_CLAVE WEB_CLAVE NODERED_CLAVE; do
  [[ -n "${!v:-}" ]] || { echo "En config.env falta $v (para AWS debe estar escrita)."; exit 1; }
done

# Solo se envían los parámetros con valor (los vacíos usan el valor por defecto de la plantilla)
params=(
  "RepoGit=$REPO_GIT"
  "RamaGit=${RAMA_GIT:-main}"
  "UsuariosLinux=${USUARIOS_SO:-${USUARIO_SO:-smartrack}}"
  "MqttUsuario=$MQTT_USUARIO" "MqttClave=$MQTT_CLAVE"
  "WebUsuario=${WEB_USUARIO:-admin}" "WebClave=$WEB_CLAVE"
  "NodeRedUsuario=${NODERED_USUARIO:-admin}" "NodeRedClave=$NODERED_CLAVE"
  "CertbotPrueba=${CERTBOT_STAGING:-no}"
)
[[ -n "${CLAVE_USUARIOS_SO:-}" ]] && params+=("ClaveLinux=$CLAVE_USUARIOS_SO")
[[ -n "${DOMINIO:-}" ]]        && params+=("Dominio=$DOMINIO")
[[ -n "${DUCKDNS_TOKEN:-}" ]]  && params+=("DuckDnsToken=$DUCKDNS_TOKEN")
[[ -n "${EMAIL_CERTBOT:-}" ]]  && params+=("EmailCertbot=$EMAIL_CERTBOT")
[[ -n "${TIPO_INSTANCIA:-}" ]] && params+=("TipoInstancia=$TIPO_INSTANCIA")
[[ -n "${PAR_LLAVES+x}" ]]     && params+=("ParLlaves=$PAR_LLAVES")

echo "Creando / actualizando la pila '$PILA' en $REGION (unos 2-3 minutos)..."
aws cloudformation deploy --region "$REGION" --stack-name "$PILA" \
  --template-file "$PLANTILLA" --parameter-overrides "${params[@]}" --no-fail-on-empty-changeset

echo
mostrar_salidas
cat <<EOF

✔ Infraestructura lista. El servidor se está configurando solo (6-10 minutos).
  Puedes seguir el avance por SSH con:  sudo tail -f /var/log/smartrack-instalacion.log
  o en la consola EC2: instancia > Acciones > Supervisar y solucionar problemas > Obtener registro del sistema.
EOF
