"""Download build inputs, retrying transfers that drop or arrive truncated."""
import http.client
import re
import sys
import time
import urllib.error
import urllib.request

ATTEMPTS = 5
TIMEOUT = 120


def fetch(url):
    """Return a complete body, resuming interrupted transfers when supported.

    Callers still verify their pinned digest before consuming build archives.
    A server that ignores Range replaces the partial body instead of appending.
    """
    partial = bytearray()
    total = None
    validator = None
    for attempt in range(1, ATTEMPTS + 1):
        try:
            headers = {"Accept-Encoding": "identity"}
            if partial:
                headers["Range"] = f"bytes={len(partial)}-"
                if validator:
                    headers["If-Range"] = validator
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                if response.status == 206:
                    match = re.fullmatch(r"bytes (\d+)-(\d+)/(\d+)", response.headers.get("Content-Range", ""))
                    if not match:
                        partial.clear()
                        total = None
                        validator = None
                        raise http.client.HTTPException("Missing or invalid Content-Range")
                    start, end, size = map(int, match.groups())
                    if start != len(partial) or not start <= end < size or (total is not None and size != total):
                        partial.clear()
                        total = None
                        raise http.client.HTTPException("Content-Range does not match partial download")
                    total = size
                    expected = end - start + 1
                else:
                    partial.clear()
                    length = response.headers.get("Content-Length")
                    total = int(length) if length is not None else None
                    expected = total
                    validator = response.headers.get("ETag") or response.headers.get("Last-Modified")
                try:
                    chunk = response.read()
                except http.client.IncompleteRead as error:
                    partial.extend(error.partial)
                    raise
                if expected is not None and len(chunk) != expected:
                    partial.clear()
                    total = None
                    raise http.client.HTTPException("Response length does not match download range")
                partial.extend(chunk)
                if total is not None and len(partial) != total:
                    raise http.client.IncompleteRead(b"", total - len(partial))
                return bytes(partial)
        except urllib.error.HTTPError as error:
            if error.code == 416 and partial:
                # A changed resource may no longer have the requested offset.
                partial.clear()
                total = None
                validator = None
            # 4xx other than rate limiting will not change on retry.
            elif 400 <= error.code < 500 and error.code != 429:
                raise
            failure = error
        except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
            failure = error
        if attempt == ATTEMPTS:
            raise failure
        delay = 2 ** attempt
        print(f"Retrying {url} in {delay}s after attempt {attempt}/{ATTEMPTS} failed: {failure!r}", file=sys.stderr)
        time.sleep(delay)
