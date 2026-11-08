#!/usr/bin/env python3
"""Run the Zig client against an isolated S3 fixture that verifies SigV4."""
import hashlib
import hmac
import http.server
import os
import subprocess
import tempfile
import threading
import urllib.parse
from pathlib import Path

ACCESS = "storage-fixture-access"
SECRET = "storage-fixture-secret"
TOKEN = "storage-fixture-token"
ROOT = Path(__file__).resolve().parent.parent

class Fixture(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    objects = {}
    checked = 0
    fail_next_list = False
    failures = []

    def log_message(self, *_):
        pass

    def send(self, status, body):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def verify(self, body):
        url = urllib.parse.urlsplit(self.path)
        signed_query = urllib.parse.parse_qs(url.query)
        if "X-Amz-Signature" in signed_query:
            self.verify_presigned(url, signed_query)
            return
        auth = self.headers["Authorization"]
        assert auth.startswith("AWS4-HMAC-SHA256 "), "Missing SigV4 authorization"
        parts = dict(item.strip().split("=", 1) for item in auth.split(" ", 1)[1].split(","))
        access, scope = parts["Credential"].split("/", 1)
        assert access == ACCESS
        assert self.headers["x-amz-security-token"] == TOKEN
        date, region, service, terminal = scope.split("/")
        assert region == "us-east-1" and service == "s3" and terminal == "aws4_request"
        url = urllib.parse.urlsplit(self.path)
        query = "&".join(f"{urllib.parse.quote(k, safe='~')}={urllib.parse.quote(v, safe='~')}" for k, v in sorted(urllib.parse.parse_qsl(url.query, keep_blank_values=True)))
        names = parts["SignedHeaders"].split(";")
        assert names == sorted(names), "Signed header names must be sorted"
        headers = "".join(f"{name}:{' '.join(self.headers[name].split())}\n" for name in names)
        payload = self.headers.get("x-amz-content-sha256", hashlib.sha256(body).hexdigest())
        if payload != "UNSIGNED-PAYLOAD":
            assert payload == hashlib.sha256(body).hexdigest(), "Incorrect body hash"
        canonical = "\n".join((self.command, url.path, query, headers, parts["SignedHeaders"], payload))
        string_to_sign = "\n".join(("AWS4-HMAC-SHA256", self.headers["x-amz-date"], scope, hashlib.sha256(canonical.encode()).hexdigest()))
        key = ("AWS4" + SECRET).encode()
        for value in (date, region, service, terminal):
            key = hmac.new(key, value.encode(), hashlib.sha256).digest()
        expected = hmac.new(key, string_to_sign.encode(), hashlib.sha256).hexdigest()
        assert hmac.compare_digest(expected, parts["Signature"]), "Incorrect request signature"
        Fixture.checked += 1

    def verify_presigned(self, url, query):
        assert query["X-Amz-Algorithm"] == ["AWS4-HMAC-SHA256"]
        assert query["X-Amz-Security-Token"] == [TOKEN]
        access, scope = query["X-Amz-Credential"][0].split("/", 1)
        assert access == ACCESS
        date, region, service, terminal = scope.split("/")
        assert region == "us-east-1" and service == "s3"
        pairs = sorted((k, v) for k, v in urllib.parse.parse_qsl(url.query) if k != "X-Amz-Signature")
        canonical_query = "&".join(f"{urllib.parse.quote(k, safe='~')}={urllib.parse.quote(v, safe='~')}" for k, v in pairs)
        canonical = "\n".join((self.command, url.path, canonical_query, f"host:{self.headers['Host']}\n", "host", "UNSIGNED-PAYLOAD"))
        to_sign = "\n".join(("AWS4-HMAC-SHA256", query["X-Amz-Date"][0], scope, hashlib.sha256(canonical.encode()).hexdigest()))
        key = ("AWS4" + SECRET).encode()
        for value in (date, region, service, terminal):
            key = hmac.new(key, value.encode(), hashlib.sha256).digest()
        expected = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        assert hmac.compare_digest(expected, query["X-Amz-Signature"][0]), "Incorrect presigned URL"
        Fixture.checked += 1

    def head(self):
        try:
            self.verify(b"")
        except Exception as exc:
            Fixture.failures.append(str(exc)); self.send(403,b""); return
        key=urllib.parse.unquote(urllib.parse.urlsplit(self.path).path.removeprefix("/acme-test/"))
        if key not in Fixture.objects:
            self.send(404,b""); return
        self.send_response(200)
        self.send_header("Content-Length",str(len(Fixture.objects[key])))
        self.send_header("ETag",'"'+hashlib.md5(Fixture.objects[key]).hexdigest()+'"')
        self.end_headers()
    do_HEAD = head

    def handle_request(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        try:
            self.verify(body)
        except Exception as exc:
            Fixture.failures.append(str(exc))
            self.send(403, "<Error><Code>SignatureDoesNotMatch</Code></Error>")
            return
        url = urllib.parse.urlsplit(self.path)
        key = urllib.parse.unquote(url.path.removeprefix("/acme-test/"))
        query = urllib.parse.parse_qs(url.query)
        if self.command == "GET" and url.path == "/":
            self.send(200, "<ListAllMyBucketsResult><Buckets><Bucket><Name>acme-test</Name><BucketRegion>us-east-1</BucketRegion></Bucket></Buckets></ListAllMyBucketsResult>")
        elif self.command == "GET" and "list-type" in query:
            if query.get("prefix") == ["nested/"]:
                self.send(403, "<Error><Code>AccessDenied</Code></Error>")
                return
            if Fixture.fail_next_list:
                Fixture.fail_next_list = False
                self.send(503, "<Error><Code>ServiceUnavailable</Code></Error>")
                return
            if "continuation-token" not in query:
                self.send(200, "<ListBucketResult><EncodingType>url</EncodingType><CommonPrefixes><Prefix>nested%2F</Prefix></CommonPrefixes><Contents><Key>first.txt</Key><Size>17</Size><LastModified>2026-11-07T15:07:00Z</LastModified></Contents><IsTruncated>true</IsTruncated><NextContinuationToken>page&amp;two+</NextContinuationToken></ListBucketResult>")
            else:
                assert query["continuation-token"] == ["page&two+"]
                self.send(200, "<ListBucketResult><EncodingType>url</EncodingType><Contents><Key>second%20%2B%26.txt</Key><Size>9</Size></Contents><IsTruncated>false</IsTruncated></ListBucketResult>")
        elif self.command == "PUT":
            copy_source = self.headers.get("x-amz-copy-source")
            if copy_source:
                source = urllib.parse.unquote(copy_source.removeprefix("/acme-test/"))
                if source not in Fixture.objects:
                    self.send(404,"<Error><Code>NoSuchKey</Code></Error>")
                    return
                if key == "uncertain-copy.txt":
                    self.send(200,"<Error><Code>InternalError</Code></Error>")
                    return
                if key in Fixture.objects:
                    self.send(412,"<Error><Code>PreconditionFailed</Code></Error>")
                    return
                Fixture.objects[key] = Fixture.objects[source]
                etag = hashlib.md5(Fixture.objects[key]).hexdigest()
                self.send(200,f'<CopyObjectResult><ETag>"{etag}"</ETag></CopyObjectResult>')
                return
            if self.headers.get("If-None-Match") == "*" and key in Fixture.objects:
                self.send(412, "<Error><Code>PreconditionFailed</Code></Error>")
                return
            if key == "saved-but-refresh-fails/":
                Fixture.fail_next_list = True
            Fixture.objects[key] = body
            self.send(200, b"")
        elif self.command == "DELETE":
            Fixture.objects.pop(key, None)
            self.send(204, b"")
        elif self.command == "GET" and key == "denied":
            self.send(403, "<Error><Code>AccessDenied</Code></Error>")
        elif self.command == "GET" and key in Fixture.objects:
            self.send(200, Fixture.objects[key])
        else:
            self.send(404, "<Error><Code>NoSuchKey</Code></Error>")

    do_GET = do_PUT = do_DELETE = handle_request

with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        with tempfile.TemporaryDirectory(prefix="storage-s3-") as temp:
            env = {**os.environ, "AWS_ACCESS_KEY_ID": ACCESS, "AWS_SECRET_ACCESS_KEY": SECRET, "AWS_SESSION_TOKEN": TOKEN}
            result = subprocess.run([str(ROOT / "tools/zig"), "build", "test-s3", f"-Dendpoint=http://127.0.0.1:{server.server_port}", f"-Dfixture-dir={temp}"], cwd=ROOT, env=env)
            if result.returncode or Fixture.failures:
                raise SystemExit(f"S3 integration failed: {Fixture.failures}, exit {result.returncode}")
            assert Fixture.objects["new folder/"] == b""
            assert Fixture.objects["ui-folder/"] == b""
            assert "nested/café +%#.txt" not in Fixture.objects
            print(f"S3 integration passed: {Fixture.checked} signatures verified; listing, pagination, upload, download, mkdir, delete, STS, and UI completion checked.")
    finally:
        server.shutdown()
        worker.join()
