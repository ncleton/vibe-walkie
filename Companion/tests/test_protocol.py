import asyncio
import base64
import json
from pathlib import Path
import struct

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
import pytest

from vibewalkie.__main__ import validate_bind
from vibewalkie.protocol import (MAX_FRAME, RemoteError, b64, decode, default_configuration,
    encode, frame, read_envelope, unb64, validate_configuration)
from vibewalkie.state import Identity, State

FIXTURES = Path(__file__).resolve().parents[2] / "ProtocolFixtures/V4"


def test_swift_ed25519_fixture_verifies_with_openssl():
    fixture = json.loads((FIXTURES / "signature-ed25519.json").read_text())
    message = unb64(fixture["nonce"]) + fixture["deviceIdentifier"].encode() + unb64(fixture["pairingSecret"])
    key = Ed25519PrivateKey.from_private_bytes(unb64(fixture["privateKey"]))
    assert b64(message) == fixture["message"]
    # CryptoKit can randomize EdDSA nonces; signature bytes need not match.
    # The signed message and public key must interoperate in both directions.
    key.public_key().verify(unb64(fixture["signature"]), message)
    key.public_key().verify(key.sign(message), unb64(fixture["message"]))


def test_swift_envelope_is_canonical_json():
    data = (FIXTURES / "envelope-keypress.json").read_bytes().strip()
    assert encode(decode(data)) == data
    assert frame(decode(data))[4:] == data


@pytest.mark.parametrize("length", [0, MAX_FRAME + 1, 2**32 - 1])
def test_invalid_length_rejected_before_body_read(length):
    async def exercise():
        reader = asyncio.StreamReader()
        reader.feed_data(struct.pack(">I", length))
        with pytest.raises(RemoteError):
            await read_envelope(reader)
    asyncio.run(exercise())


@pytest.mark.parametrize("data", [b'{"x":NaN}', b'{"x":1,"x":2}', b'[]'])
def test_ambiguous_or_nonfinite_json_rejected(data):
    with pytest.raises(ValueError):
        decode(data)


@pytest.mark.parametrize("address", ["0.0.0.0", "8.8.8.8", "224.0.0.1", "::", "::1"])
def test_listener_cannot_be_public_or_wildcard(address):
    with pytest.raises(RuntimeError):
        validate_bind(address)


def test_private_routes_accepted():
    assert validate_bind("100.64.12.1")
    assert validate_bind("192.168.1.12")


def test_identity_persists_and_corruption_is_not_replaced(tmp_path):
    state = State(tmp_path)
    first = Identity(state.directory)
    assert Identity(state.directory).fingerprint == first.fingerprint
    certificate = (tmp_path / "certificate.pem").read_bytes()
    (tmp_path / "identity.pem").write_text("invalid")
    with pytest.raises(RuntimeError, match="Cannot load TLS identity"):
        Identity(state.directory)
    assert (tmp_path / "certificate.pem").read_bytes() == certificate
    state.close()


def test_configuration_rejects_hardware_actions_and_unknown_shortcut_ids():
    config = default_configuration()
    validate_configuration(config, set())
    config["buttons"][0]["action"] = {"type": "mac_shortcut", "keyCode": 4}
    with pytest.raises(RemoteError):
        validate_configuration(config, set())
    config["buttons"][0]["action"] = {"type": "host_shortcut", "shortcut": {"id": "unknown"}}
    with pytest.raises(RemoteError):
        validate_configuration(config, set())
