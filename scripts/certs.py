#!/usr/bin/env python3
"""Genera certificados TLS autofirmados de desarrollo, sin dependencias Python."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CERTS_DIR = ROOT / "traefik" / "certs"


def find_openssl() -> str:
    command = shutil.which("openssl")
    if command:
        return command
    program_files = os.environ.get("ProgramFiles", r"C:\Program Files")
    candidate = Path(program_files) / "Git" / "usr" / "bin" / "openssl.exe"
    if candidate.is_file():
        return str(candidate)
    raise RuntimeError("OpenSSL no disponible. Git for Windows lo incluye.")


def generate_certs() -> None:
    openssl = find_openssl()
    CERTS_DIR.mkdir(parents=True, exist_ok=True)
    key = CERTS_DIR / "key.pem"
    cert = CERTS_DIR / "cert.pem"
    if key.is_file() and cert.is_file():
        print("[CERTS] Par de certificados existente. No se modifica.")
        return

    config = """[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = pdf.localhost

[ext]
subjectAltName = DNS:*.pdf.localhost,DNS:pdf.localhost,DNS:traefik.localhost
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
"""
    with tempfile.TemporaryDirectory(prefix="extractext-cert-") as temp:
        config_path = Path(temp) / "openssl.cnf"
        config_path.write_text(config, encoding="utf-8")
        result = subprocess.run([
            openssl, "req", "-x509", "-nodes", "-newkey", "rsa:2048",
            "-sha256", "-days", "825", "-keyout", str(key),
            "-out", str(cert), "-config", str(config_path)
        ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        key.unlink(missing_ok=True)
        cert.unlink(missing_ok=True)
        raise RuntimeError(f"OpenSSL fallo al generar certificados (exit {result.returncode}).")

    print("[CERTS] Generados en traefik/certs/ (autofirmados; no subir al repositorio).")


if __name__ == "__main__":
    try:
        generate_certs()
    except (OSError, RuntimeError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        sys.exit(1)
