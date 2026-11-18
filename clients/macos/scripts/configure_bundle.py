#!/usr/bin/env python3
"""Configure a staged app plist using only the Python standard library."""
import os
from pathlib import Path
import plistlib
import re
import sys
from urllib.parse import urlsplit, urlunsplit


def server_url():
    value = os.environ.get("VOICEPAD_SERVER_URL", "http://localhost:8791/")
    message = ("VOICEPAD_SERVER_URL must be HTTPS (HTTP only for localhost, 127.x.x.x or [::1]), "
               "without credentials, query, fragment, whitespace or malformed escapes.")
    try:
        if (not value or any(ord(c) <= 32 or ord(c) >= 127 for c in value)
                or "\\" in value or "?" in value or "#" in value
                or re.search(r"%(?![0-9A-Fa-f]{2})", value)):
            raise ValueError(message)
        parts = urlsplit(value)
        if (parts.scheme not in ("http", "https") or not parts.hostname
                or not value.startswith(parts.scheme + "://")
                or not re.fullmatch(r"(?:[A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(?::[0-9]+)?", parts.netloc)
                or (parts.port is not None and not 1 <= parts.port <= 65535)):
            raise ValueError(message)
        octets = parts.hostname.split(".")
        ipv4_loopback = (len(octets) == 4 and octets[0] == "127"
                         and all(s.isdigit() and str(int(s)) == s and 0 <= int(s) <= 255 for s in octets))
        loopback = parts.hostname in ("localhost", "::1") or ipv4_loopback
        if parts.scheme != "https" and not loopback:
            raise ValueError(message)
    except ValueError:
        raise ValueError(message) from None
    path = parts.path if parts.path.endswith("/") else parts.path + "/"
    return urlunsplit((parts.scheme, parts.netloc, path, "", ""))


def main():
    url = server_url()
    if len(sys.argv) == 1:
        print(url)
        return
    target = Path(sys.argv[1])
    info = plistlib.loads(target.read_bytes())
    info["VoicepadServerURL"] = url
    target.write_bytes(plistlib.dumps(info, sort_keys=False))


if __name__ == "__main__":
    try:
        main()
    except ValueError as error:
        sys.exit(str(error))
