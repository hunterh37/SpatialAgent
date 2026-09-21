from __future__ import annotations

from agentd.discovery import SERVICE_TYPE, Advertiser, local_ip, service_properties
from agentd.protocol import PROTOCOL_VERSION


def test_service_type_matches_the_clients_nsbonjourservices_entry() -> None:
    assert SERVICE_TYPE == "_spatialagent._tcp.local."


def test_properties_tell_the_client_where_to_connect() -> None:
    props = service_properties("ollama/llama3.2", PROTOCOL_VERSION)
    assert props["path"] == "/agent"
    assert props["protocolVersion"] == str(PROTOCOL_VERSION)


def test_local_ip_is_an_address() -> None:
    parts = local_ip().split(".")
    assert len(parts) == 4 and all(p.isdigit() for p in parts)


def test_advertiser_start_and_stop_is_safe() -> None:
    advertiser = Advertiser(8787, "echo", PROTOCOL_VERSION, name="agentd test")
    advertiser.start()
    advertiser.stop()
    advertiser.stop()
