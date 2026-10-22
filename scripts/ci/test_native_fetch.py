"""Exercise interrupted build-input downloads without network access."""
import http.client
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error


SPEC = importlib.util.spec_from_file_location(
    "native_fetch", Path(__file__).with_name("native_fetch.py"))
fetcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fetcher)


class Response:
    def __init__(self, body, status=200, **headers):
        self.body, self.status, self.headers = body, status, headers

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        if isinstance(self.body, Exception):
            raise self.body
        return self.body


class NativeFetchTests(unittest.TestCase):
    def download(self, responses):
        with patch.object(fetcher.urllib.request, "urlopen", side_effect=responses) as opening, \
                patch.object(fetcher.time, "sleep"):
            result = fetcher.fetch("https://example.org/pinned.whl")
        return result, [call.args[0] for call in opening.call_args_list]

    def test_multiple_truncated_responses_resume_at_received_offset(self):
        result, requests = self.download([
            Response(http.client.IncompleteRead(b"abc", 5), **{"Content-Length": "8", "ETag": '"fixed"'}),
            Response(http.client.IncompleteRead(b"de", 3), 206, **{"Content-Range": "bytes 3-7/8"}),
            Response(b"fgh", 206, **{"Content-Range": "bytes 5-7/8"}),
        ])
        self.assertEqual(result, b"abcdefgh")
        self.assertIsNone(requests[0].get_header("Range"))
        self.assertEqual(requests[1].get_header("Range"), "bytes=3-")
        self.assertEqual(requests[2].get_header("Range"), "bytes=5-")
        self.assertEqual(requests[1].get_header("If-range"), '"fixed"')

    def test_server_ignoring_range_replaces_partial_body(self):
        result, _ = self.download([
            Response(http.client.IncompleteRead(b"old", 4), **{"Content-Length": "7"}),
            Response(b"new-body", **{"Content-Length": "8"}),
        ])
        self.assertEqual(result, b"new-body")

    def test_wrong_range_is_rejected_and_next_attempt_starts_over(self):
        result, requests = self.download([
            Response(http.client.IncompleteRead(b"abc", 5), **{"Content-Length": "8"}),
            Response(b"xxxxx", 206, **{"Content-Range": "bytes 2-6/8"}),
            Response(b"abcdefgh", **{"Content-Length": "8"}),
        ])
        self.assertEqual(result, b"abcdefgh")
        self.assertIsNone(requests[2].get_header("Range"))

    def test_range_rejection_restarts_whole_download(self):
        result, requests = self.download([
            Response(http.client.IncompleteRead(b"abc", 5), **{"Content-Length": "8"}),
            urllib.error.HTTPError("url", 416, "range", {}, None),
            Response(b"changed", **{"Content-Length": "7"}),
        ])
        self.assertEqual(result, b"changed")
        self.assertIsNone(requests[2].get_header("Range"))

    def test_bounded_range_response_continues_until_total_size(self):
        result, requests = self.download([
            Response(http.client.IncompleteRead(b"abc", 5), **{"Content-Length": "8"}),
            Response(b"de", 206, **{"Content-Range": "bytes 3-4/8"}),
            Response(b"fgh", 206, **{"Content-Range": "bytes 5-7/8"}),
        ])
        self.assertEqual(result, b"abcdefgh")
        self.assertEqual(requests[2].get_header("Range"), "bytes=5-")

    def test_exhausted_partial_transfer_never_returns_truncated_bytes(self):
        responses = [Response(http.client.IncompleteRead(b"a", 9), **{"Content-Length": "10"})]
        responses += [Response(http.client.IncompleteRead(b"a", 9 - i), 206,
                              **{"Content-Range": f"bytes {i}-9/10"}) for i in range(1, 5)]
        with self.assertRaises(http.client.IncompleteRead):
            self.download(responses)

    def test_nonretryable_http_error_stops_immediately(self):
        with patch.object(fetcher.urllib.request, "urlopen", side_effect=urllib.error.HTTPError("url", 404, "missing", {}, None)) as opening:
            with self.assertRaises(urllib.error.HTTPError):
                fetcher.fetch("https://example.org/pinned.whl")
            self.assertEqual(opening.call_count, 1)


if __name__ == "__main__":
    unittest.main()
