"""Private, durable identity and operator-controlled pairing state."""
import csv
import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import sqlite3
import ssl
import subprocess
import sys
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from .protocol import RemoteError, b64, encode, now, parse_date, timestamp


def private_directory(path):
    path = Path(path).expanduser().absolute()
    if path.is_symlink():
        raise RuntimeError("The companion state directory must not be a symbolic link.")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if sys.platform == "win32":
        result = subprocess.run(["whoami", "/user", "/fo", "csv", "/nh"], check=True, capture_output=True, text=True)
        sid = next(csv.reader(result.stdout.splitlines()))[1]
        subprocess.run(["icacls", str(path), "/reset", "/Q"], check=True, capture_output=True)
        subprocess.run(["icacls", str(path), "/inheritance:r", "/grant:r", f"*{sid}:(OI)(CI)F", "*S-1-5-18:(OI)(CI)F", "/Q"],
                       check=True, capture_output=True)
    else:
        if path.stat().st_uid != os.getuid():
            raise RuntimeError("The companion state directory must belong to the current user.")
        path.chmod(0o700)
    return path


def atomic_write(path, data):
    temporary = path.with_name(path.name + "." + secrets.token_hex(8) + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class State:
    def __init__(self, directory):
        self.directory = private_directory(directory)
        self.database = sqlite3.connect(self.directory / "companion.sqlite3", timeout=5)
        if sys.platform != "win32":
            (self.directory / "companion.sqlite3").chmod(0o600)
        self.database.row_factory = sqlite3.Row
        self.database.executescript("""
          CREATE TABLE IF NOT EXISTS peers(id TEXT PRIMARY KEY, name TEXT NOT NULL, public_key TEXT NOT NULL,
            platform TEXT NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS pairing(secret_hash TEXT PRIMARY KEY, expires TEXT NOT NULL, consumed INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE IF NOT EXISTS requests(id TEXT PRIMARY KEY, peer_id TEXT NOT NULL, name TEXT NOT NULL,
            public_key TEXT NOT NULL, platform TEXT NOT NULL, code TEXT NOT NULL, expires TEXT NOT NULL, decision TEXT);
          CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)

    def close(self):
        self.database.close()

    def setting(self, key):
        row = self.database.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else None

    def set_setting(self, key, value):
        with self.database:
            self.database.execute("INSERT OR REPLACE INTO settings VALUES (?, ?)", (key, json.dumps(value)))

    def peer(self, identifier):
        return self.database.execute("SELECT * FROM peers WHERE id=?", (identifier,)).fetchone()

    def revoke(self, identifier):
        with self.database:
            changed = self.database.execute("UPDATE peers SET revoked=1 WHERE id=?", (identifier,)).rowcount
        if not changed:
            raise RuntimeError("Unknown peer ID. Run 'vibewalkie peers' to list paired devices.")

    def new_pairing(self, metadata, fingerprint):
        secret = secrets.token_bytes(16)
        expiry = timestamp(now() + dt.timedelta(seconds=600))
        with self.database:
            self.database.execute("DELETE FROM pairing")
            self.database.execute("INSERT INTO pairing VALUES (?, ?, 0)", (hashlib.sha256(secret).hexdigest(), expiry))
            self.database.execute("DELETE FROM requests WHERE expires < ?", (timestamp(),))
        qr = {"v": 4, "m": metadata["hostName"], "p": metadata["hostPlatform"], "s": metadata["serviceName"],
              "f": fingerprint, "k": b64(secret), "e": expiry}
        if metadata.get("nomadEndpoint"):
            qr["n"] = metadata["nomadEndpoint"]
        return qr

    def request_pairing(self, payload, secret, fingerprint):
        identifier = str(uuid.uuid4()).upper()
        code_bytes = hashlib.sha256((fingerprint + b64(secret)).encode()).digest()
        code = f"{int.from_bytes(code_bytes[:4], 'big') % 1000000:06d}"
        expiry = timestamp(now() + dt.timedelta(seconds=60))
        with self.database:
            self.database.execute("BEGIN IMMEDIATE")
            row = self.database.execute("SELECT * FROM pairing WHERE secret_hash=?", (hashlib.sha256(secret).hexdigest(),)).fetchone()
            if row is None or row["consumed"] or parse_date(row["expires"]) <= now():
                raise RemoteError("not_paired", "Pairing code is expired or used. Generate a new QR on this computer.")
            self.database.execute("UPDATE pairing SET consumed=1 WHERE secret_hash=?", (row["secret_hash"],))
            self.database.execute("INSERT INTO requests VALUES (?, ?, ?, ?, ?, ?, ?, NULL)", (
                identifier, payload["deviceIdentifier"], payload["deviceName"], payload["publicKey"],
                payload["clientPlatform"], code, expiry))
        return {"requestID": identifier, "deviceName": payload["deviceName"], "confirmationCode": code, "expiresAt": expiry}

    def decision(self, identifier):
        return self.database.execute("SELECT decision FROM requests WHERE id=?", (identifier,)).fetchone()[0]

    def decide(self, identifier, code, allow):
        with self.database:
            self.database.execute("BEGIN IMMEDIATE")
            request = self.database.execute("SELECT * FROM requests WHERE id=?", (identifier,)).fetchone()
            if request is None or request["decision"] or parse_date(request["expires"]) <= now():
                raise RuntimeError("Pairing request is missing, expired or already handled. Scan a new QR.")
            if not hmac.compare_digest(request["code"], code):
                raise RuntimeError("The confirmation code does not match. Check the six digits on the iPhone.")
            if allow:
                self.database.execute("INSERT OR REPLACE INTO peers VALUES (?, ?, ?, ?, 0)", (
                    request["peer_id"], request["name"], request["public_key"], request["platform"]))
            self.database.execute("UPDATE requests SET decision=? WHERE id=?", ("approved" if allow else "denied", identifier))


class Identity:
    def __init__(self, directory):
        certificate = directory / "certificate.pem"
        keyfile = directory / "identity.pem"
        if certificate.exists() != keyfile.exists():
            raise RuntimeError("TLS identity is incomplete. Restore both identity.pem and certificate.pem from backup, or reset identity and re-pair every device.")
        if not certificate.exists():
            key = ec.generate_private_key(ec.SECP256R1())
            subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Vibe Walkie Companion")])
            cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(subject).public_key(key.public_key())
                    .serial_number(x509.random_serial_number()).not_valid_before(now() - dt.timedelta(days=1))
                    .not_valid_after(now() + dt.timedelta(days=1825))
                    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                    .sign(key, hashes.SHA256()))
            atomic_write(keyfile, key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            atomic_write(certificate, cert.public_bytes(serialization.Encoding.PEM))
        try:
            cert = x509.load_pem_x509_certificate(certificate.read_bytes())
            if cert.not_valid_after_utc <= now():
                raise RuntimeError("TLS certificate expired. Renew the identity locally and re-pair the iPhone.")
            self.fingerprint = b64(cert.fingerprint(hashes.SHA256()))
            self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            self.context.minimum_version = ssl.TLSVersion.TLSv1_3
            self.context.load_cert_chain(certificate, keyfile)
        except (ValueError, ssl.SSLError) as error:
            raise RuntimeError("Cannot load TLS identity. Restore its original certificate and private key; identities are never silently replaced.") from error
