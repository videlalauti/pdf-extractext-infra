#!/bin/sh
# Traefik no combina configuración estática YAML y variables TRAEFIK_*.
# Se genera un YAML privado con token ACL, sin persistir el secreto en Git.
set -eu
: "${CONSUL_TRAEFIK_TOKEN:?Falta CONSUL_TRAEFIK_TOKEN}"

# Los tokens ACL de este proyecto son UUIDv4, validados antes de usarlos en sed.
case "$CONSUL_TRAEFIK_TOKEN" in
  *[!0-9a-fA-F-]*)
    echo "[TRAEFIK] Token ACL invalido: se espera UUID." >&2
    exit 1
    ;;
esac

template="/etc/traefik/traefik.template.yml"
runtime="/tmp/traefik.yml"
if ! grep -q '__CONSUL_TRAEFIK_TOKEN__' "$template"; then
  echo "[TRAEFIK] La plantilla no contiene el marcador de token." >&2
  exit 1
fi

umask 077
sed "s/__CONSUL_TRAEFIK_TOKEN__/$CONSUL_TRAEFIK_TOKEN/g" "$template" > "$runtime"
unset CONSUL_TRAEFIK_TOKEN

# Una única fuente de configuración estática: el archivo generado.
exec traefik --configFile="$runtime"
