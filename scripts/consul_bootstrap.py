#!/usr/bin/env python3
"""Provisionamiento inicial de Consul ACL y KV. Solo stdlib; no imprime tokens."""
from __future__ import annotations

import json
import os
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

BASE = os.environ.get("CONSUL_HTTP_ADDR", "http://consul:8500").rstrip("/")
ADMIN = os.environ["CONSUL_MANAGEMENT_TOKEN"]
APP = os.environ["CONSUL_APP_TOKEN"]
TRAEFIK = os.environ["CONSUL_TRAEFIK_TOKEN"]

SERVICES = ("validation-service", "extraction-service", "persistence-service", "summary-service")


def api(method: str, path: str, *, body: object | str | None = None, token: str = ADMIN):
    if isinstance(body, str):
        payload = body.encode("utf-8")
    else:
        payload = None if body is None else json.dumps(body).encode("utf-8")
    headers = {"X-Consul-Token": token}
    if payload is not None:
        headers["Content-Type"] = "application/json" if not isinstance(body, str) else "text/plain"
    req = Request(BASE + path, data=payload, headers=headers, method=method)
    try:
        with urlopen(req, timeout=10) as response:
            raw = response.read()
            if not raw:
                return None
            try:
                return json.loads(raw)
            except ValueError:
                return raw.decode("utf-8")
    except HTTPError as exc:
        # Mostrar código/método/ruta, nunca cuerpos potencialmente sensibles.
        raise RuntimeError(f"Consul {method} {path}: HTTP {exc.code}") from exc


def policy(name: str, rules: str) -> str:
    existing = next((p for p in api("GET", "/v1/acl/policies") if p["Name"] == name), None)
    if existing:
        item = api("PUT", f"/v1/acl/policy/{existing['ID']}", body={
            "ID": existing["ID"], "Name": name, "Rules": rules,
        })
    else:
        item = api("PUT", "/v1/acl/policy", body={"Name": name, "Rules": rules})
    return item["ID"]


def ensure_token(name: str, secret: str, policy_id: str) -> None:
    # Consulta mediante token de servicio: si existe, la llamada responde
    # con datos o 403. Evitar recrear tokens en cada 'docker compose up'.
    try:
        api("GET", "/v1/acl/token/self", token=secret)
        return
    except (RuntimeError, URLError):
        pass
    api("PUT", "/v1/acl/token", body={
        "Description": name,
        "SecretID": secret,
        "Local": True,
        "Policies": [{"ID": policy_id}],
    })


def main() -> None:
    for attempt in range(20):
        try:
            api("GET", "/v1/status/leader")
            break
        except (URLError, RuntimeError):
            if attempt == 19:
                raise
            time.sleep(2)

    # App no es root: permiso explícito de registro y lectura de configuración.
    app_rules = (
        'node_prefix "" { policy = "read" }\n'
        'service_prefix "" { policy = "write" }\n'
        'key_prefix "pdf-extractext/" { policy = "read" }\n'
    )
    # Traefik SOLO consulta el catálogo. No puede registrar servicios ni escribir KV.
    traefik_rules = (
        'node_prefix "" { policy = "read" }\n'
        'service_prefix "" { policy = "read" }\n'
    )
    app_id = policy("extractext-app-runtime", app_rules)
    traefik_id = policy("extractext-traefik-read", traefik_rules)
    ensure_token("extractext-app-runtime", APP, app_id)
    ensure_token("extractext-traefik-read", TRAEFIK, traefik_id)

    # Configuración por servicio, NO existe un "config microservice".
    # Los propios microservicios consultan estas claves por API con X-Consul-Token.
    configs = {
        "validation-service": {"role": "validation", "health_path": "/health"},
        "extraction-service": {"role": "extraction", "health_path": "/health", "validation_service": "validation-service", "persistence_service": "persistence-service", "gateway_service": "extractext-gateway"},
        "persistence-service": {"role": "persistence", "health_path": "/health", "database": "pdf_extractext"},
        "summary-service": {"role": "summary", "health_path": "/health", "persistence_service": "persistence-service", "gateway_service": "extractext-gateway"},
    }
    for service, cfg in configs.items():
        path = "/v1/kv/pdf-extractext/" + quote(service, safe="") + "/config"
        api("PUT", path, body=json.dumps(cfg))

    # El gateway se registra como servicio del Catalog; su check real permite
    # descubrirlo solo cuando Traefik responde. No se expone su :8081 al host.
    gateway = {
        "ID": "extractext-gateway",
        "Name": "extractext-gateway",
        "Address": "reverse-proxy",
        "Port": 8081,
        "Tags": [],
        "Check": {
            "HTTP": "http://reverse-proxy:8081/ping",
            "Interval": "5s",
            "Timeout": "2s",
            "DeregisterCriticalServiceAfter": "2m",
        },
    }
    api("PUT", "/v1/agent/service/register", body=gateway)
    print("[CONSUL] ACL, tokens y KV de cuatro microservicios provisionados.")
    print("[CONSUL] Gateway registrado: Traefik :8081. Tokenes no mostrados.")


if __name__ == "__main__":
    main()
