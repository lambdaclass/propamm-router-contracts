"""Shared TLS context backed by certifi's CA bundle.

The system cert store is empty on some Python builds (e.g. python.org installers
on macOS), which makes every TLS verification fail. Using certifi's bundled
Mozilla roots avoids depending on how Python was installed.
"""

from __future__ import annotations

import ssl
from functools import lru_cache

import certifi


@lru_cache(maxsize=1)
def ssl_context() -> ssl.SSLContext:
    """A default TLS context that verifies against certifi's CA bundle."""
    return ssl.create_default_context(cafile=certifi.where())
