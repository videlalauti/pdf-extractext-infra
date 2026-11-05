#!/usr/bin/env python3
"""CLI de demostración de PDF ExtractExt (solo biblioteca estándar de Python).

Desde infra: python scripts/dev.py start|status|urls|upload|compass-on|compass-off|stop
No escribe credenciales en logs ni borra volúmenes de Docker.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import uuid

ROOT = Path(__file__).resolve().parent.parent
COMPOSE_FILE = ROOT / "docker-compose.yml"
COMPASS_FILE = ROOT / ".mongo-compass.generated.yml"
MONGO_PORT = 27017
HOSTS = {
    "validation": "validation.pdf.localhost",
    "extraction": "extraction.pdf.localhost",
    "persistence": "persistence.pdf.localhost",
    "summary": "summary.pdf.localhost",
}
COMPASS_OVERRIDE = """# Generado por scripts/dev.py; SOLO para desarrollo local.
# La red no interna es necesaria para publicar Mongo en Windows.
services:
  mongo:
    ports:
      - "127.0.0.1:27017:27017"
    networks:
      - mongo_net_interna
      - mongo_compass_net

networks:
  mongo_compass_net:
    driver: bridge
"""


class DemoError(RuntimeError):
    pass


def run(*args: str, check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
    command = list(args)
    try:
        return subprocess.run(
            command,
            cwd=ROOT,
            check=check,
            text=True,
            stdout=subprocess.DEVNULL if quiet else None,
            stderr=subprocess.DEVNULL if quiet else None,
        )
    except FileNotFoundError as exc:
        raise DemoError(f"No se encontro el ejecutable: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        raise DemoError(f"El comando fallo (exit {exc.returncode}): {' '.join(command)}") from exc


def compose(*args: str, compass: bool = False) -> subprocess.CompletedProcess:
    cmd = ["docker", "compose", "-f", str(COMPOSE_FILE)]
    if compass:
        cmd.extend(["-f", str(COMPASS_FILE)])
    return run(*cmd, *args)


def ensure_docker() -> None:
    run("docker", "info", quiet=True)


def ensure_network() -> None:
    if run("docker", "network", "inspect", "mired", check=False, quiet=True).returncode != 0:
        print("[INFO] Creando red Docker mired")
        run("docker", "network", "create", "mired")


def ensure_consul_tokens(env_file: Path) -> None:
    """Añade secretos ACL UUID solo si faltan; jamás los imprime o reemplaza."""
    current = env_file.read_text(encoding="utf-8")
    known = {
        line.split("=", 1)[0].strip()
        for line in current.splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    }
    missing = [
        name for name in (
            "CONSUL_MANAGEMENT_TOKEN",
            "CONSUL_APP_TOKEN",
            "CONSUL_TRAEFIK_TOKEN",
        )
        if name not in known
    ]
    if not missing:
        return
    import uuid as uuid_module
    suffix = "" if current.endswith("\\n") else "\\n"
    extra = "\\n".join(f"{name}={uuid_module.uuid4()}" for name in missing) + "\\n"
    with env_file.open("a", encoding="utf-8") as out:
        out.write(suffix + extra)
    if os.name != "nt":
        env_file.chmod(0o600)
    print("[INFO] Tokens Consul ACL UUID creados en .env (no se muestran).")


def ensure_configuration() -> None:
    env_file = ROOT / ".env"
    if not env_file.is_file():
        raise DemoError(
            "Falta infra/.env. Copia mongodb/.env-example a .env y configura "
            "MONGODB_ROOT_USERNAME y MONGODB_ROOT_PASSWORD."
        )
    data = env_file.read_text(encoding="utf-8")
    if "REEMPLAZAR_POR_" in data:
        raise DemoError("El archivo .env aun contiene credenciales de ejemplo.")
    ensure_consul_tokens(env_file)
    certs = ROOT / "traefik" / "certs"
    if all((certs / name).is_file() for name in ("cert.pem", "key.pem")):
        return
    print("[INFO] Generando certificados TLS autofirmados con Python y OpenSSL")
    run(sys.executable, str(ROOT / "scripts" / "certs.py"))


def start(args: argparse.Namespace) -> None:
    ensure_docker()
    ensure_configuration()
    ensure_network()
    compose("config", "--quiet")
    command = ["up", "-d"]
    if args.build:
        command.append("--build")
    compose(*command)
    compose("ps")
    print("\n[OK] Stack iniciado. Swagger: python scripts/dev.py urls")


def stop(args: argparse.Namespace) -> None:
    ensure_docker()
    if args.remove:
        compose("down")  # No usa -v: mantiene los datos.
    else:
        compose("stop")
    print("[OK] Contenedores detenidos; datos conservados.")


def status(_: argparse.Namespace) -> None:
    ensure_docker()
    compose("ps")


def urls(_: argparse.Namespace) -> None:
    for service, hostname in HOSTS.items():
        print(f"{service:12s} http://{hostname}/docs")
    print("Traefik      https://traefik.localhost/dashboard/")
    print("Consul       http://127.0.0.1:8500/ui/ (ACL requiere token de lectura)")
    print("MongoDB      mongodb://127.0.0.1:27017/ (solo despues de compass-on)")


def connection_available(host: str = "127.0.0.1", port: int = MONGO_PORT) -> bool:
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def compass_on(_: argparse.Namespace) -> None:
    ensure_docker()
    ensure_configuration()
    # El archivo es generado, separado de las modificaciones manuales del usuario.
    if COMPASS_FILE.exists() and COMPASS_FILE.read_text(encoding="utf-8") != COMPASS_OVERRIDE:
        raise DemoError(f"{COMPASS_FILE.name} ya existe con contenido distinto. No se sobrescribio.")
    COMPASS_FILE.write_text(COMPASS_OVERRIDE, encoding="utf-8")
    compose("config", "--quiet", compass=True)
    compose("up", "-d", "--no-deps", "--force-recreate", "mongo", compass=True)

    for _ in range(30):
        if connection_available():
            break
        time.sleep(1)

    if not connection_available():
        raise DemoError(
            "Mongo no escucha desde Windows en 127.0.0.1:27017. "
            "Comprueba: docker port mongo / docker compose ps mongo"
        )

    print("[OK] Puerto Mongo publicado SOLO en 127.0.0.1:27017")
    print("Compass URI: mongodb://127.0.0.1:27017/")
    print("Authentication: Username/Password del .env de Infra; authSource=admin")
    print("Base de datos: pdf_extractext  |  Coleccion: documents")
    print("Nunca compartas la contrasena en capturas ni commits.")


def compass_off(_: argparse.Namespace) -> None:
    ensure_docker()
    # Recrear desde el compose ORIGINAL cierra el puerto y retira la red adicional.
    compose("up", "-d", "--no-deps", "--force-recreate", "mongo")
    if connection_available():
        raise DemoError("El puerto 27017 sigue accesible; revisar docker port mongo antes de continuar.")
    if COMPASS_FILE.exists() and COMPASS_FILE.read_text(encoding="utf-8") == COMPASS_OVERRIDE:
        COMPASS_FILE.unlink()
    print("[OK] MongoDB vuelve a estar aislado; documentos conservados.")


def request_json(service: str, path: str, *, payload: bytes | None = None, content_type: str | None = None) -> tuple[int, dict]:
    headers = {"Host": HOSTS[service]}
    if content_type:
        headers["Content-Type"] = content_type
    request = Request(
        f"http://127.0.0.1{path}",
        data=payload,
        headers=headers,
        method="POST" if payload is not None else "GET",
    )
    try:
        with urlopen(request, timeout=90) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        detail = error.read(600).decode("utf-8", errors="replace")
        raise DemoError(f"{service} respondio HTTP {error.code}: {detail}") from error
    except (URLError, TimeoutError, ValueError) as error:
        raise DemoError(f"No se pudo consultar {service}: {error}") from error


def upload(args: argparse.Namespace) -> None:
    pdf = args.pdf.resolve()
    if not pdf.is_file() or pdf.suffix.lower() != ".pdf":
        raise DemoError("Indica un archivo PDF existente con --pdf.")
    data = pdf.read_bytes()
    if not data.startswith(b"%PDF-"):
        raise DemoError("El archivo no tiene cabecera PDF valida.")
    if args.unique:
        # Comentario al final del PDF: cambia SHA-256 sin alterar el texto.
        data += f"\n% pdf-extractext-demo-{uuid.uuid4().hex}\n".encode("ascii")
    boundary = "pdfextractext_" + secrets.token_hex(12)
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="demo.pdf"\r\n'
        "Content-Type: application/pdf\r\n\r\n"
    ).encode("ascii") + data + f"\r\n--{boundary}--\r\n".encode("ascii")

    code, extracted = request_json(
        "extraction", "/upload", payload=body,
        content_type=f"multipart/form-data; boundary={boundary}",
    )
    doc_id = extracted.get("id")
    if code != 200 or not isinstance(doc_id, str) or not doc_id:
        raise DemoError(f"Respuesta de /upload inesperada: {extracted}")
    from urllib.parse import quote
    status_code, document = request_json("persistence", f"/documents/{quote(doc_id, safe='')}")
    if status_code != 200 or document.get("id") != doc_id:
        raise DemoError("El documento no pudo recuperarse desde Persistence.")
    if document.get("checksum") != extracted.get("checksum") or document.get("content") != extracted.get("content"):
        raise DemoError("El documento recuperado no coincide con lo enviado.")

    print(f"[OK] PDF extraido y verificado mediante Persistence. ID: {doc_id}")
    print(f"Checksum: {document['checksum']}")
    print(f"Summary en Kafka: {extracted.get('summary_status', 'desconocido')}")
    print("Compass: pdf_extractext > documents > Documents")
    print(f'Filtro de Compass: {json.dumps({"_id": doc_id}, ensure_ascii=False)}')
    print("Schema: pestaña Schema > Analyze Schema; Indexes: checksum unico.")

    if args.wait_summary:
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            code, state = request_json("summary", f"/summary/{quote(doc_id, safe='')}")
            if code == 200:
                print(f"[OK] Resumen generado: {state.get('summary', '')}")
                return
            if code != 202:
                raise DemoError(f"Estado de summary inesperado: HTTP {code}: {state}")
            time.sleep(5)
        raise DemoError("El resumen sigue pendiente; revisa Kafka/Ollama y consulta /summary/{id}.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Atajos de desarrollo y demo de PDF ExtractExt")
    sub = parser.add_subparsers(dest="command", required=True)
    start_cmd = sub.add_parser("start", help="Levanta todos los servicios")
    start_cmd.add_argument("--build", action="store_true", help="Reconstruye imagenes")
    start_cmd.set_defaults(func=start)
    stop_cmd = sub.add_parser("stop", help="Detiene servicios sin borrar datos")
    stop_cmd.add_argument("--remove", action="store_true", help="Retira contenedores, conserva datos")
    stop_cmd.set_defaults(func=stop)
    sub.add_parser("prepare", help="Prepara .env y certificados sin iniciar Docker").set_defaults(
        func=lambda args: ensure_configuration()
    )
    sub.add_parser("status", help="Muestra estado de contenedores").set_defaults(func=status)
    sub.add_parser("urls", help="Enlaces de Swagger").set_defaults(func=urls)
    sub.add_parser("compass-on", help="Abre Mongo solo en 127.0.0.1").set_defaults(func=compass_on)
    sub.add_parser("compass-off", help="Cierra acceso desde Windows").set_defaults(func=compass_off)
    upload_cmd = sub.add_parser("upload", help="Sube PDF real y comprueba persistencia")
    upload_cmd.add_argument("--pdf", type=Path, default=ROOT / "scripts" / "test.pdf")
    upload_cmd.add_argument("--unique", action="store_true", help="Evita cache/deduplicacion en cada demo")
    upload_cmd.add_argument("--wait-summary", action="store_true", help="Consulta hasta obtener resumen")
    upload_cmd.add_argument("--timeout", type=int, default=300, help="Segundos maximos de espera del resumen")
    upload_cmd.set_defaults(func=upload)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        args.func(args)
    except (DemoError, OSError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
