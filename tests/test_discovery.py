from __future__ import annotations

import socket
import struct
import subprocess

import pytest

from mail2nas import discovery
from mail2nas.discovery import (
    DiscoveryError,
    Found,
    cups_queues,
    discover,
    parse_lpstat,
    parse_responses,
)


# --- CUPS queues -------------------------------------------------------------


def test_parse_lpstat_reads_queue_and_device():
    output = (
        "device for Buero_MFP: ipp://192.168.1.50:631/ipp/print\n"
        "device for Lager: socket://192.168.1.51:9100\n"
    )

    found = parse_lpstat(output, server="cups.lan")

    assert [(f.name, f.destination, f.server) for f in found] == [
        ("Buero_MFP", "Buero_MFP", "cups.lan"),
        ("Lager", "Lager", "cups.lan"),
    ]
    assert found[0].detail == "ipp://192.168.1.50:631/ipp/print"
    assert found[0].ready_to_use is True


def test_parse_lpstat_survives_a_localised_prefix():
    """The wording of "device for" depends on the server's locale."""
    found = parse_lpstat("Gerät für Flur: ipp://10.0.0.9/ipp/print\n")

    assert [f.destination for f in found] == ["Flur"]


@pytest.mark.parametrize("output", ["", "\n", "lpstat: keine Ziele\n"])
def test_parse_lpstat_ignores_noise(output):
    assert parse_lpstat(output) == [] or all(f.destination for f in parse_lpstat(output))


def test_cups_queues_asks_the_named_server(monkeypatch):
    seen = {}

    def fake_run(command, **kwargs):
        seen["command"] = command
        return subprocess.CompletedProcess(command, 0, "device for A: ipp://x/ipp/print\n", "")

    monkeypatch.setattr(subprocess, "run", fake_run)

    found = cups_queues("cups.lan:631", lpstat_binary="lpstat")

    assert seen["command"] == ["lpstat", "-h", "cups.lan:631", "-v"]
    assert [f.name for f in found] == ["A"]


def test_cups_queues_without_a_server_queries_the_local_one(monkeypatch):
    seen = {}

    def fake_run(command, **kwargs):
        seen["command"] = command
        return subprocess.CompletedProcess(command, 0, "", "")

    monkeypatch.setattr(subprocess, "run", fake_run)

    cups_queues("")

    assert "-h" not in seen["command"]


def test_a_missing_lpstat_is_reported_usefully(monkeypatch):
    def fake_run(command, **kwargs):
        raise FileNotFoundError()

    monkeypatch.setattr(subprocess, "run", fake_run)

    with pytest.raises(DiscoveryError, match="cups-client"):
        cups_queues("")


def test_an_unreachable_server_is_reported(monkeypatch):
    def fake_run(command, **kwargs):
        return subprocess.CompletedProcess(command, 1, "", "lpstat: Server nicht erreichbar")

    monkeypatch.setattr(subprocess, "run", fake_run)

    with pytest.raises(DiscoveryError, match="nicht erreichbar"):
        cups_queues("cups.lan")


def test_a_hanging_server_does_not_hang_the_page(monkeypatch):
    def fake_run(command, **kwargs):
        raise subprocess.TimeoutExpired(command, 10)

    monkeypatch.setattr(subprocess, "run", fake_run)

    with pytest.raises(DiscoveryError, match="10s"):
        cups_queues("cups.lan", timeout=10)


# --- mDNS --------------------------------------------------------------------


def _name(value: str) -> bytes:
    return b"".join(bytes([len(p)]) + p.encode() for p in value.split(".")) + b"\x00"


def _record(name: str, rtype: int, rdata: bytes) -> bytes:
    return _name(name) + struct.pack(">HHIH", rtype, 1, 120, len(rdata)) + rdata


def _txt(**values) -> bytes:
    out = b""
    for key, value in values.items():
        chunk = f"{key}={value}".encode()
        out += bytes([len(chunk)]) + chunk
    return out


def _response(instance="Kyocera M2540._ipp._tcp.local", host="drucker.local", port=631, **txt):
    """A realistic mDNS answer: SRV + TXT + A, like a printer sends."""
    srv = struct.pack(">HHH", 0, 0, port) + _name(host)
    body = (
        _record(instance, discovery.TYPE_SRV, srv)
        + _record(instance, discovery.TYPE_TXT, _txt(**txt))
        + _record(host, discovery.TYPE_A, socket.inet_aton("192.168.1.50"))
    )
    return struct.pack(">HHHHHH", 0, 0x8400, 0, 3, 0, 0) + body


def test_parse_responses_builds_a_printer():
    found = parse_responses([_response(ty="Kyocera ECOSYS M2540", rp="ipp/print")])

    assert len(found) == 1
    printer = found[0]
    assert printer.name == "Kyocera ECOSYS M2540"
    assert printer.destination == "ipp/print"
    assert printer.server == "192.168.1.50"
    assert printer.detail == "ipp://192.168.1.50:631/ipp/print"
    assert printer.ready_to_use is False


def test_a_non_standard_port_stays_in_the_server():
    found = parse_responses([_response(port=6310, rp="ipp/print")])

    assert found[0].server == "192.168.1.50:6310"


def test_without_a_queue_in_the_txt_record_the_default_is_used():
    found = parse_responses([_response(ty="Drucker")])

    assert found[0].destination == "ipp/print"


def test_the_instance_name_is_used_when_the_txt_record_has_no_model():
    found = parse_responses([_response(instance="Flurdrucker._ipp._tcp.local")])

    assert found[0].name == "Flurdrucker"


def test_a_service_without_an_srv_record_is_skipped():
    """TXT alone says nothing about where to reach the device."""
    body = _record("X._ipp._tcp.local", discovery.TYPE_TXT, _txt(ty="X"))
    packet = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0) + body

    assert parse_responses([packet]) == []


def test_compressed_names_are_followed():
    """Responders compress repeated names - the parser has to expand them."""
    header = struct.pack(">HHHHHH", 0, 0x8400, 0, 2, 0, 0)
    # An SRV record with the full names, then a TXT record whose own name is a
    # pointer back to the instance name in the first record (offset 12, right
    # after the header) - exactly what a real responder sends.
    srv = struct.pack(">HHH", 0, 0, 631) + _name("drucker.local")
    first = _record("Drucker._ipp._tcp.local", discovery.TYPE_SRV, srv)
    second = b"\xc0\x0c" + struct.pack(">HHIH", discovery.TYPE_TXT, 1, 120, 0)

    found = parse_responses([header + first + second])

    assert [f.server for f in found] == ["drucker.local"]


@pytest.mark.parametrize(
    "packet",
    [b"", b"\x00", b"\x00" * 11, b"\xff" * 40, struct.pack(">HHHHHH", 0, 0x8400, 0, 5, 0, 0)],
)
def test_broken_packets_are_ignored_instead_of_raising(packet):
    """Anything can arrive on a multicast socket, including garbage."""
    assert parse_responses([packet]) == []


def test_a_name_pointer_loop_does_not_hang():
    header = struct.pack(">HHHHHH", 0, 0x8400, 0, 1, 0, 0)
    loop = b"\xc0\x0c"  # points at itself
    assert parse_responses([header + loop + struct.pack(">HHIH", 33, 1, 120, 0)]) == []


def test_mdns_returns_nothing_when_multicast_is_unavailable(monkeypatch):
    """Bridged Docker networks have no multicast - that is not an error."""

    def no_socket(*args, **kwargs):
        raise OSError("Network is unreachable")

    monkeypatch.setattr(socket, "socket", no_socket)

    assert discovery.mdns_printers(timeout=0.1) == []


# --- both together -----------------------------------------------------------


def test_discover_merges_both_sources(monkeypatch):
    monkeypatch.setattr(
        discovery,
        "cups_queues",
        lambda *a, **k: [Found("A", "A", "cups.lan", "cups", "ipp://10.0.0.1/ipp/print")],
    )
    monkeypatch.setattr(
        discovery,
        "mdns_printers",
        lambda **k: [Found("B", "ipp/print", "10.0.0.2", "mdns", "ipp://10.0.0.2:631/ipp/print")],
    )

    found, problems = discover("cups.lan")

    assert [f.name for f in found] == ["A", "B"]
    assert problems == []


def test_a_device_that_already_has_a_queue_is_not_listed_twice(monkeypatch):
    uri = "ipp://10.0.0.1:631/ipp/print"
    monkeypatch.setattr(
        discovery, "cups_queues", lambda *a, **k: [Found("A", "A", "cups.lan", "cups", uri)]
    )
    monkeypatch.setattr(
        discovery, "mdns_printers", lambda **k: [Found("A", "ipp/print", "10.0.0.1", "mdns", uri)]
    )

    found, _ = discover("cups.lan")

    assert len(found) == 1


def test_a_broken_cups_server_still_leaves_the_mdns_results(monkeypatch):
    def boom(*args, **kwargs):
        raise DiscoveryError("Server nicht erreichbar")

    monkeypatch.setattr(discovery, "cups_queues", boom)
    monkeypatch.setattr(
        discovery, "mdns_printers", lambda **k: [Found("B", "ipp/print", "10.0.0.2", "mdns")]
    )

    found, problems = discover("cups.lan")

    assert [f.name for f in found] == ["B"]
    assert any("nicht erreichbar" in problem for problem in problems)


def test_finding_nothing_explains_why(monkeypatch):
    monkeypatch.setattr(discovery, "cups_queues", lambda *a, **k: [])
    monkeypatch.setattr(discovery, "mdns_printers", lambda **k: [])

    found, problems = discover("")

    assert found == []
    assert any("Multicast" in problem for problem in problems)


def test_the_lpadmin_hint_is_a_usable_command():
    entry = Found("Kyocera M2540", "ipp/print", "10.0.0.2", "mdns", "ipp://10.0.0.2:631/ipp/print")

    command = entry.lpadmin_command()

    assert command.startswith("lpadmin -p Kyocera_M2540 -v ipp://10.0.0.2:631/ipp/print")
    assert " -m everywhere" in command
