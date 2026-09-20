from __future__ import annotations

import argparse
import logging

import uvicorn

from .server import create_app


def main() -> None:
    parser = argparse.ArgumentParser(prog="agentd")
    # 0.0.0.0, not localhost: Vision Pro is a separate device on the LAN.
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--log-level", default="info")
    args = parser.parse_args()

    logging.basicConfig(level=args.log_level.upper())
    uvicorn.run(create_app(), host=args.host, port=args.port, log_level=args.log_level)


if __name__ == "__main__":
    main()
