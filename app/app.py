"""API de démonstration du cours DevOps avancé : métriques Prometheus et pannes simulées."""
import os
import random
import time

from flask import Flask, jsonify, request
from prometheus_client import (CONTENT_TYPE_LATEST, CollectorRegistry, Counter,
                               Histogram, generate_latest)

# Routes techniques : elles ne comptent ni dans les requêtes ni dans la latence.
NON_COMPTEES = ("/metrics", "/healthz", "/chaos")


def creer_app():
    app = Flask(__name__)
    registre = CollectorRegistry()
    requetes = Counter("http_requests_total", "Requêtes HTTP traitées",
                       ["status"], registry=registre)
    duree = Histogram("http_request_duration_seconds", "Durée des requêtes",
                      registry=registre)
    chaos = {"erreurs": 0.0, "latence_ms": 0}

    @app.before_request
    def demarrer():
        request.debut = time.perf_counter()

    @app.after_request
    def mesurer(reponse):
        if request.path not in NON_COMPTEES:
            requetes.labels(status=str(reponse.status_code)).inc()
            duree.observe(time.perf_counter() - request.debut)
        return reponse

    @app.get("/")
    def racine():
        time.sleep(chaos["latence_ms"] / 1000)
        if random.random() < chaos["erreurs"]:
            return jsonify(erreur="panne simulée"), 500
        return jsonify(service="api", version=os.environ.get("VERSION", "dev"),
                       jeton_present=bool(os.environ.get("JETON")))

    @app.get("/healthz")
    def healthz():
        return jsonify(etat="ok")

    @app.get("/chaos")
    def regler_chaos():
        erreurs = request.args.get("erreurs", default=chaos["erreurs"], type=float)
        latence = request.args.get("latence", default=chaos["latence_ms"], type=int)
        if not 0 <= erreurs <= 1 or not 0 <= latence <= 5000:
            return jsonify(erreur="erreurs entre 0 et 1, latence entre 0 et 5000 ms"), 400
        chaos.update(erreurs=erreurs, latence_ms=latence)
        return jsonify(chaos)

    @app.get("/metrics")
    def metrics():
        return generate_latest(registre), 200, {"Content-Type": CONTENT_TYPE_LATEST}

    return app


if __name__ == "__main__":
    creer_app().run(host="0.0.0.0", port=8080)
