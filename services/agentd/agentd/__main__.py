from __future__ import annotations

import argparse
import logging
import os

import uvicorn

from .discovery import Advertiser
from .protocol import PROTOCOL_VERSION
from .server import DEFAULT_MODEL, build_adapter, create_app


def main() -> None:
    parser = argparse.ArgumentParser(prog="agentd")
    # 0.0.0.0, not localhost: Vision Pro is a separate device on the LAN.
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--log-level", default="info")
    parser.add_argument("--model", help=f"overrides AGENTD_MODEL (default {DEFAULT_MODEL})")
    parser.add_argument("--backend", help="echo | ollama | lmstudio | llamacpp | vllm")
    parser.add_argument("--no-bonjour", action="store_true",
                        help="skip mDNS advertisement; the client connects by IP")
    args = parser.parse_args()

    logging.basicConfig(level=args.log_level.upper())

    # Flags are sugar over the environment, so a one-off run needs no export.
    if args.model:
        os.environ["AGENTD_MODEL"] = args.model
    if args.backend:
        os.environ["AGENTD_BACKEND"] = args.backend

    adapter = build_adapter()
    app = create_app(adapter)

    advertiser = None
    if not args.no_bonjour:
        advertiser = Advertiser(args.port, adapter.name, PROTOCOL_VERSION)
        advertiser.start()

    try:
        uvicorn.run(app, host=args.host, port=args.port, log_level=args.log_level)
    finally:
        if advertiser is not None:
            advertiser.stop()


if __name__ == "__main__":
    main()
