"""Diagnostico de Consul Catalog + Traefik. Nunca imprime secretos ACL.

Desde Infra: docker compose run --rm --no-deps consul-init python /diagnose.py
"""
import json
import os
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CONSUL = os.environ.get("CONSUL_HTTP_ADDR", "http://consul:8500")
TOKEN = os.environ.get("CONSUL_MANAGEMENT_TOKEN", "")
SERVICES = ("validation-service", "extraction-service", "persistence-service", "summary-service")


def fetch(base, path, token=None):
    headers = {"X-Consul-Token": token} if token else {}
    try:
        req = Request(base + path, headers=headers)
        with urlopen(req, timeout=8) as res:
            return json.load(res)
    except (HTTPError, URLError, TimeoutError) as err:
        code = getattr(err, "code", type(err).__name__)
        print(f"[DIAG] ERROR GET {path}: {code}")
        return None


def main():
    for name in SERVICES:
        items = fetch(CONSUL, f"/v1/health/service/{name}?passing=true", TOKEN)
        print(f"[DIAG] Consul {name}: instancias passing={len(items) if isinstance(items,list) else '?'}")
        if items:
            tags = items[0]["Service"].get("Tags", [])
            print(f"[DIAG]   habilitado para Traefik={('traefik.enable=true' in tags)}; tags={len(tags)}")
            status = [f"{check['CheckID']}:{check['Status']}" for check in items[0].get("Checks", [])]
            print(f"[DIAG]   checks={status}")
    catalog = fetch("http://reverse-proxy:8081", "/api/http/routers")
    if not isinstance(catalog, list):
        print("[DIAG] Traefik API privada no accesible")
        raise SystemExit(2)
    catalog_names = [router.get("name","") for router in catalog]
    names = [name for name in catalog_names if "@consulcatalog" in name]
    print(f"[DIAG] Routers desde Consul: {names}")
    for name in ("validation", "extraction", "persistence", "summary"):
        matched = any(router.startswith(name + "@") or router.startswith(name + "-health@") for router in names)
        print(f"[DIAG] Traefik publica {name}={matched}")
    if len(names) < 4:
        print("[DIAG] Faltan routers en Traefik; revisar permisos del token ConsulCatalog y tags")
        raise SystemExit(3)


if __name__ == "__main__":
    main()
