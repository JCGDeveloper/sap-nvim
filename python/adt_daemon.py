#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# adt_daemon.py - Daemon de larga vida que mantiene un POOL de conexiones HTTPS keep-alive
# contra la API ADT de SAP y las reutiliza, atendiendo peticiones EN PARALELO (como hace la
# extension de VSCode con axios/HTTP keep-alive multiplexado). Asi el completado NO espera en
# cola detras del syntax-check ni de otras peticiones -> instantaneo.
#
# Idea clave: login UNA vez (CSRF + cookies). Despues, varias conexiones calientes en un pool;
# cada peticion entrante se atiende en su propio hilo con una conexion del pool (sin pagar
# handshake). stdout se escribe bajo lock. Protocolo: JSON por linea en stdin/stdout.
#   IN : {"id":int,"method":..,"path":..,"query":{..}?,"body":..?,"accept":..?,"content_type":..?,"stateful":bool?}
#   OUT: {"id":int,"status":int,"body":".."}
#
# Lanzar con `python3 -u` (sin buffer) — el cliente Lua lo hace.

import base64
import http.client
import json
import os
import ssl
import sys
import threading
import time

GRAPH_PATH = "/sap/bc/adt/compatibility/graph"
KEEPALIVE_SECS = 120
POOL_MAX = 6  # nº máx de conexiones calientes simultáneas

_LOG = os.path.expanduser("~/.cache/nvim/sap-nvim/daemon.log")


def log(msg):
    try:
        os.makedirs(os.path.dirname(_LOG), exist_ok=True)
        with open(_LOG, "a") as f:
            f.write("%.3f %s\n" % (time.time(), msg))
    except Exception:
        pass


class AdtDaemon:
    def __init__(self):
        base = os.environ.get("ADT_BASE", "")
        self.client = os.environ.get("ADT_CLIENT", "")
        user = os.environ.get("ADT_USER", "")
        password = os.environ.get("ADT_PASS", "")
        self.host, self.port, self.is_https = self._parse_base(base)
        token = base64.b64encode(("%s:%s" % (user, password)).encode("utf-8"))
        self.authorization = "Basic " + token.decode("ascii")
        self.ctx = ssl._create_unverified_context()

        self.csrf = None
        self.cookies = None
        self.state_lock = threading.Lock()   # protege csrf/cookies
        self.pool = []                        # conexiones libres
        self.pool_lock = threading.Lock()
        self.out_lock = threading.Lock()      # serializa SOLO la escritura a stdout

    @staticmethod
    def _parse_base(base):
        is_https = True
        rest = base
        if rest.startswith("https://"):
            rest = rest[len("https://"):]
        elif rest.startswith("http://"):
            rest = rest[len("http://"):]; is_https = False
        slash = rest.find("/")
        if slash != -1:
            rest = rest[:slash]
        if ":" in rest:
            host, port_s = rest.rsplit(":", 1)
            try:
                port = int(port_s)
            except ValueError:
                port = 443 if is_https else 80
        else:
            host, port = rest, (443 if is_https else 80)
        return host, port, is_https

    def _new_conn(self):
        if self.is_https:
            return http.client.HTTPSConnection(self.host, self.port, context=self.ctx, timeout=30)
        return http.client.HTTPConnection(self.host, self.port, timeout=30)

    def _get_conn(self):
        with self.pool_lock:
            if self.pool:
                return self.pool.pop()
        return self._new_conn()

    def _release_conn(self, conn, ok):
        if not ok:
            try:
                conn.close()
            except Exception:
                pass
            return
        with self.pool_lock:
            if len(self.pool) < POOL_MAX:
                self.pool.append(conn)
            else:
                try:
                    conn.close()
                except Exception:
                    pass

    def _build_url(self, path, query):
        url = path
        sep = "&" if ("?" in url) else "?"
        url = url + sep + "sap-client=" + self.client
        if query:
            for k, v in query.items():
                url = url + "&" + str(k) + "=" + str(v)
        return url

    def _store_session(self, resp):
        with self.state_lock:
            pairs = []
            for name, value in resp.getheaders():
                ln = name.lower()
                if ln == "set-cookie":
                    c = value.split(";", 1)[0].strip()
                    if c:
                        pairs.append(c)
                elif ln == "x-csrf-token":
                    v = (value or "").strip()
                    if v and v.lower() not in ("required", "fetch"):
                        self.csrf = v
            if pairs:
                self.cookies = "; ".join(pairs)

    def login(self):
        conn = self._new_conn()
        with self.state_lock:
            self.csrf = None
            self.cookies = None
        url = self._build_url(GRAPH_PATH, None)
        conn.request("GET", url, headers={
            "Authorization": self.authorization, "x-csrf-token": "fetch", "Accept": "application/*",
        })
        resp = conn.getresponse()
        self._store_session(resp)
        resp.read()
        with self.pool_lock:
            self.pool.append(conn)
        return True

    def _headers(self, method, accept, content_type, stateful):
        with self.state_lock:
            csrf, cookies = self.csrf, self.cookies
        h = {"Authorization": self.authorization}
        if cookies:
            h["Cookie"] = cookies
        h["Accept"] = accept or "*/*"  # ADT exige Accept; curl manda */* por defecto.
        if content_type:
            h["Content-Type"] = content_type
        if method != "GET" and csrf:
            h["x-csrf-token"] = csrf
        if stateful:
            h["X-sap-adt-sessiontype"] = "stateful"
        return h

    def handle(self, req):
        rid = req.get("id")
        method = (req.get("method") or "GET").upper()
        url = self._build_url(req.get("path") or "/", req.get("query"))
        body = req.get("body")
        body_bytes = body.encode("utf-8") if body is not None else None
        headers = self._headers(method, req.get("accept"), req.get("content_type"), req.get("stateful"))

        last_err = None
        for attempt in (1, 2):  # reintento con conexión nueva si la del pool estaba muerta
            conn = self._get_conn()
            try:
                conn.request(method, url, body=body_bytes, headers=headers)
                resp = conn.getresponse()
                raw = resp.read()
                self._store_session(resp)
                self._release_conn(conn, True)
                return {"id": rid, "status": resp.status, "body": raw.decode("utf-8", errors="replace")}
            except Exception as e:
                last_err = e
                self._release_conn(conn, False)
                if attempt == 1:
                    continue
        return {"id": rid, "status": 0, "body": "request failed: " + str(last_err)}

    def _respond(self, obj):
        line = json.dumps(obj) + "\n"
        with self.out_lock:
            try:
                sys.stdout.write(line)
                sys.stdout.flush()
            except Exception:
                pass

    def _serve(self, req):
        try:
            resp = self.handle(req)
        except Exception as e:
            resp = {"id": req.get("id"), "status": 0, "body": str(e)}
            log("HANDLE EXC " + repr(e))
        self._respond(resp)

    def _keepalive_loop(self):
        while True:
            time.sleep(KEEPALIVE_SECS)
            try:
                conn = self._get_conn()
                conn.request("GET", self._build_url(GRAPH_PATH, None), headers=self._headers("GET", "application/*", None, None))
                r = conn.getresponse(); self._store_session(r); r.read()
                self._release_conn(conn, True)
            except Exception:
                pass  # se recupera en la próxima petición real

    def run(self):
        log("START host=%s port=%s pool=%d" % (self.host, self.port, POOL_MAX))
        try:
            t = time.time()
            self.login()
            log("LOGIN csrf=%s cookies=%s %.0fms" % (bool(self.csrf), bool(self.cookies), (time.time() - t) * 1000))
        except Exception as e:
            log("LOGIN EXC " + repr(e))
        threading.Thread(target=self._keepalive_loop, daemon=True).start()

        # Lee peticiones y atiende CADA UNA EN SU HILO (paralelo, como VSCode). readline()
        # entrega línea a línea (con `python3 -u`).
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception:
                self._respond({"id": None, "status": 0, "body": "bad request"})
                continue
            threading.Thread(target=self._serve, args=(req,), daemon=True).start()


def main():
    AdtDaemon().run()


if __name__ == "__main__":
    main()
