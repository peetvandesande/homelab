"""Tiny render service for the job search pipelines.

POST /docx  {"markdown": str, "reference_docx_b64": str?}  -> .docx bytes
POST /pdf   same body                                     -> PDF bytes, via Gotenberg
POST /yaml  {"yaml": str}                                 -> the document as JSON
GET  /healthz                                             -> ok

/yaml exists because n8n's Code nodes have no YAML parser and the master
CVs are YAML. The reference document travels with the request, so each instance keeps its
own Word template in its repo and this image stays generic. Standard library
only; nothing here is reachable from outside the compose networks.
"""
import base64
import json
import os
import subprocess
import tempfile
import urllib.request
import uuid

import yaml
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

GOTENBERG = os.environ.get("GOTENBERG_URL", "http://gotenberg:3000")
MAX_BODY = 8 * 1024 * 1024


def to_docx(markdown, reference_b64):
    with tempfile.TemporaryDirectory() as d:
        src, out = os.path.join(d, "cv.md"), os.path.join(d, "cv.docx")
        with open(src, "w", encoding="utf-8") as f:
            f.write(markdown)
        cmd = ["pandoc", src, "-f", "markdown", "-t", "docx", "-o", out]
        if reference_b64:
            ref = os.path.join(d, "reference.docx")
            with open(ref, "wb") as f:
                f.write(base64.b64decode(reference_b64))
            cmd.append("--reference-doc=" + ref)
        subprocess.run(cmd, check=True, capture_output=True, timeout=60)
        with open(out, "rb") as f:
            return f.read()


def to_pdf(docx):
    boundary = uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="files"; filename="cv.docx"\r\n'
        "Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n\r\n"
    ).encode() + docx + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        GOTENBERG + "/forms/libreoffice/convert",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self._send(200, b"ok", "text/plain")
        else:
            self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path not in ("/docx", "/pdf", "/yaml"):
            return self._send(404, b"not found", "text/plain")
        n = int(self.headers.get("Content-Length") or 0)
        if not 0 < n <= MAX_BODY:
            return self._send(413, b"body missing or too large", "text/plain")
        try:
            req = json.loads(self.rfile.read(n))
            if self.path == "/yaml":
                doc = yaml.safe_load(req["yaml"])
                return self._send(200, json.dumps(doc, default=str).encode(), "application/json")
            docx = to_docx(req["markdown"], req.get("reference_docx_b64"))
            if self.path == "/docx":
                return self._send(200, docx, "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
            return self._send(200, to_pdf(docx), "application/pdf")
        except subprocess.CalledProcessError as e:
            self._send(422, e.stderr or b"pandoc failed", "text/plain")
        except (KeyError, ValueError, yaml.YAMLError) as e:
            self._send(400, f"bad request: {e}".encode(), "text/plain")
        except Exception as e:  # Gotenberg down, timeouts
            self._send(502, str(e).encode(), "text/plain")

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
