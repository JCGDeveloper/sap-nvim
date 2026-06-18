#!/usr/bin/env python3
# -*- coding: utf-8 -*-
#
# adt_daemon.py - Daemon de larga vida que mantiene UNA conexion HTTPS keep-alive
# contra la API ADT de SAP y la reutiliza para todas las peticiones (replica el
# mecanismo de `abap-adt-api` de la extension de VSCode).
#
# Idea clave: el handshake TLS y el login (CSRF + cookies) se hacen UNA sola vez
# al arrancar. Despues cada peticion ADT viaja por la MISMA conexion ya abierta,
# asi que no se paga handshake por llamada. Un hilo de keep-alive hace ping cada
# 120s a /sap/bc/adt/compatibility/graph para no perder la sesion del servidor.
#
# Protocolo: linea-a-linea por stdin/stdout, un objeto JSON por linea.
#   IN : {"id":int,"method":"GET|POST|PUT","path":"/sap/bc/adt/...",
#         "query":{k:v}?, "body":"..."?, "accept":"..."?, "content_type":"..."?,
#         "stateful":bool?}
#   OUT: {"id":int,"status":int,"body":"..."}
#
# Solo stdlib. El daemon NUNCA termina por una peticion fallida; solo termina si
# stdin se cierra (EOF).

import base64
import http.client
import json
import os
import ssl
import sys
import threading

# ── Endpoint usado para login y keep-alive (igual que abap-adt-api) ───────────
GRAPH_PATH = "/sap/bc/adt/compatibility/graph"
KEEPALIVE_SECS = 120


class AdtDaemon:
    def __init__(self):
        # Credenciales via entorno (las inyecta el cliente Lua).
        base = os.environ.get("ADT_BASE", "")
        self.client = os.environ.get("ADT_CLIENT", "")
        user = os.environ.get("ADT_USER", "")
        password = os.environ.get("ADT_PASS", "")

        # Parsear ADT_BASE -> host/port y si es https.
        self.host, self.port, self.is_https = self._parse_base(base)

        # Cabecera de autenticacion basica para TODAS las peticiones.
        token = base64.b64encode(("%s:%s" % (user, password)).encode("utf-8"))
        self.authorization = "Basic " + token.decode("ascii")

        # Contexto SSL que NO verifica el cert (el sistema usa self-signed).
        self.ctx = ssl._create_unverified_context()

        # Estado de la sesion.
        self.conn = None
        self.csrf = None
        self.cookies = None  # string ya listo para la cabecera Cookie

        # Un unico lock para serializar el uso de la conexion (peticiones y ping
        # no deben solaparse en la misma conexion HTTP).
        self.lock = threading.Lock()

    # ── Helpers ───────────────────────────────────────────────────────────────
    @staticmethod
    def _parse_base(base):
        """Devuelve (host, port, is_https) a partir de 'https://host:44310'."""
        is_https = True
        rest = base
        if rest.startswith("https://"):
            rest = rest[len("https://"):]
            is_https = True
        elif rest.startswith("http://"):
            rest = rest[len("http://"):]
            is_https = False
        # Quitar cualquier path sobrante.
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
            host = rest
            port = 443 if is_https else 80
        return host, port, is_https

    def _new_conn(self):
        """Crea una conexion nueva (https o http) segun ADT_BASE."""
        if self.is_https:
            return http.client.HTTPSConnection(self.host, self.port, context=self.ctx)
        return http.client.HTTPConnection(self.host, self.port)

    def _build_url(self, path, query):
        """Anade sap-client y query params al path."""
        url = path
        sep = "&" if ("?" in url) else "?"
        url = url + sep + "sap-client=" + self.client
        if query:
            for k, v in query.items():
                url = url + "&" + str(k) + "=" + str(v)
        return url

    def _store_cookies(self, resp):
        """Guarda las cookies de las cabeceras set-cookie de la respuesta."""
        pairs = []
        # getheaders() devuelve lista de tuplas; recogemos TODAS las set-cookie.
        for name, value in resp.getheaders():
            if name.lower() == "set-cookie":
                # Nos quedamos solo con la parte 'k=v' (antes del primer ';').
                cookie = value.split(";", 1)[0].strip()
                if cookie:
                    pairs.append(cookie)
        if pairs:
            self.cookies = "; ".join(pairs)

    def _store_csrf(self, resp):
        """Actualiza el token CSRF si el servidor manda uno nuevo."""
        for name, value in resp.getheaders():
            if name.lower() == "x-csrf-token":
                v = (value or "").strip()
                # El server puede mandar 'Required' o vacio; solo guardamos tokens reales.
                if v and v.lower() not in ("required", "fetch"):
                    self.csrf = v
                return

    # ── Login: abre conexion y obtiene CSRF + cookies ──────────────────────────
    def login(self):
        """Abre/reabre la conexion y hace el login (CSRF fetch + cookies)."""
        try:
            if self.conn is not None:
                try:
                    self.conn.close()
                except Exception:
                    pass
            self.conn = self._new_conn()
            self.csrf = None
            self.cookies = None
            url = self._build_url(GRAPH_PATH, None)
            headers = {
                "Authorization": self.authorization,
                "x-csrf-token": "fetch",
                "Accept": "application/*",
            }
            self.conn.request("GET", url, headers=headers)
            resp = self.conn.getresponse()
            self._store_csrf(resp)
            self._store_cookies(resp)
            resp.read()  # vaciar el body para reutilizar la conexion
            return True
        except Exception:
            return False

    # ── Una peticion HTTP sobre la conexion persistente ────────────────────────
    def _do_request(self, method, url, headers, body):
        """Lanza una peticion y devuelve (status, body_str). Puede lanzar excepcion."""
        self.conn.request(method, url, body=body, headers=headers)
        resp = self.conn.getresponse()
        raw = resp.read()
        # Actualizar estado de sesion desde la respuesta.
        self._store_cookies(resp)
        self._store_csrf(resp)
        text = raw.decode("utf-8", errors="replace")
        return resp.status, text

    def handle(self, req):
        """Procesa una peticion del cliente. Devuelve dict respuesta."""
        rid = req.get("id")
        method = (req.get("method") or "GET").upper()
        path = req.get("path") or "/"
        query = req.get("query")
        body = req.get("body")
        accept = req.get("accept")
        content_type = req.get("content_type")
        stateful = req.get("stateful")

        url = self._build_url(path, query)

        # Body a bytes (http.client lo prefiere asi).
        body_bytes = None
        if body is not None:
            body_bytes = body.encode("utf-8")

        def build_headers():
            headers = {"Authorization": self.authorization}
            if self.cookies:
                headers["Cookie"] = self.cookies
            # ADT EXIGE un Accept; curl manda '*/*' por defecto y por eso funcionaba.
            # http.client NO añade ninguno -> el server responde 400 "Accept header missing".
            headers["Accept"] = accept or "*/*"
            if content_type:
                headers["Content-Type"] = content_type
            if method != "GET" and self.csrf:
                headers["x-csrf-token"] = self.csrf
            if stateful:
                headers["X-sap-adt-sessiontype"] = "stateful"
            return headers

        with self.lock:
            # Asegurar que hay conexion (primer uso / tras caida).
            if self.conn is None:
                self.login()
            try:
                status, text = self._do_request(method, url, build_headers(), body_bytes)
                return {"id": rid, "status": status, "body": text}
            except (http.client.CannotSendRequest,
                    http.client.BadStatusLine,
                    http.client.ResponseNotReady,
                    ConnectionError,
                    OSError):
                # Conexion caida: reconectar + re-login y REINTENTAR una vez.
                try:
                    self.login()
                    status, text = self._do_request(method, url, build_headers(), body_bytes)
                    return {"id": rid, "status": status, "body": text}
                except Exception as e2:
                    return {"id": rid, "status": 0, "body": "reconnect failed: " + str(e2)}
            except Exception as e:
                return {"id": rid, "status": 0, "body": str(e)}

    # ── Hilo de keep-alive ─────────────────────────────────────────────────────
    def _keepalive_loop(self):
        """Ping periodico para no perder la sesion del servidor."""
        stop = threading.Event()
        url = self._build_url(GRAPH_PATH, None)
        while not stop.wait(KEEPALIVE_SECS):
            with self.lock:
                if self.conn is None:
                    continue
                try:
                    headers = {"Authorization": self.authorization}
                    if self.cookies:
                        headers["Cookie"] = self.cookies
                    headers["Accept"] = "application/*"
                    self.conn.request("GET", url, headers=headers)
                    resp = self.conn.getresponse()
                    self._store_cookies(resp)
                    self._store_csrf(resp)
                    resp.read()
                except Exception:
                    # Si el ping falla, intentamos reconectar para la proxima.
                    try:
                        self.login()
                    except Exception:
                        pass

    def start_keepalive(self):
        t = threading.Thread(target=self._keepalive_loop, name="adt-keepalive")
        t.daemon = True
        t.start()

    # ── Bucle principal ────────────────────────────────────────────────────────
    def run(self):
        # Login inicial (si falla, igualmente seguimos; cada peticion reintenta).
        try:
            self.login()
        except Exception:
            pass
        self.start_keepalive()

        # IMPORTANTE: usar readline() en bucle, NO `for line in sys.stdin` (este aplica
        # buffering de lectura adelantada y NO entrega cada linea al recibirla por un pipe
        # -> las respuestas no salian hasta acumular buffer/EOF). readline() entrega ya.
        while True:
            line = sys.stdin.readline()
            if not line:
                break  # EOF -> fin del daemon
            line = line.strip()
            if not line:
                continue
            try:
                req = json.loads(line)
            except Exception:
                # JSON invalido: respondemos sin morir. No tenemos id fiable.
                self._respond({"id": None, "status": 0, "body": "bad request"})
                continue
            try:
                resp = self.handle(req)
            except Exception as e:
                resp = {"id": req.get("id"), "status": 0, "body": str(e)}
            self._respond(resp)

    @staticmethod
    def _respond(obj):
        try:
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()
        except Exception:
            pass


def main():
    AdtDaemon().run()


if __name__ == "__main__":
    main()
