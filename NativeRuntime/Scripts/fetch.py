"""Download build inputs, retrying transfers that drop or arrive truncated."""
import http.client
import sys
import time
import urllib.error
import urllib.request

ATTEMPTS = 5
TIMEOUT = 120


def fetch(url):
    """Return the complete body of url; a short read raises and is retried."""
    for attempt in range(1, ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=TIMEOUT) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            # 4xx other than rate limiting will not change on retry.
            if 400 <= error.code < 500 and error.code != 429:
                raise
            failure = error
        except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
            failure = error
        if attempt == ATTEMPTS:
            raise failure
        delay = 2 ** attempt
        print(f"Retrying {url} in {delay}s after attempt {attempt}/{ATTEMPTS} failed: {failure!r}", file=sys.stderr)
        time.sleep(delay)
