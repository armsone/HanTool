"""
Entry point of the frozen portable engine (PyInstaller, see scripts/build_portable_engine.py).

  htd-engine <engine command> ...      -> engine.main(): same protocol, argv and stdin hygiene as `python engine.py`
  htd-engine collect-sites <args...>   -> collector.main(args): the public evidence inventory collector (user-run)

Nothing is printed here; the parent/ready handshake and the stdout protection stay in engine.main().
"""

import os
import sys


def _setup_ca_bundle():
    """Frozen build only: TLS trust comes from the bundled certifi CA file (verification is never disabled).
    The Homebrew default CA path does not exist on a recipient Mac. Neither the path nor the contents are printed."""
    if not getattr(sys, "frozen", False):
        return
    ca = None
    try:
        import certifi
        ca = certifi.where()
    except Exception:
        pass
    if not ca or not os.path.isfile(ca) or os.path.getsize(ca) < 1024:
        sys.stderr.write("Error: bundled CA certificates are missing; the engine cannot start.\n")
        sys.exit(78)
    os.environ["SSL_CERT_FILE"] = ca
    os.environ["REQUESTS_CA_BUNDLE"] = ca


def run():
    _setup_ca_bundle()
    if len(sys.argv) > 1 and sys.argv[1] == "collect-sites":
        import collector
        return collector.main(sys.argv[2:])
    import engine
    return engine.main()


if __name__ == "__main__":
    sys.exit(run())
