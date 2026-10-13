# Image de base volontairement ancienne : elle sera corrigée plus tard dans le cours.
FROM python:3.9-slim-buster
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ARG VERSION=dev
ENV VERSION=$VERSION
EXPOSE 8080
USER 1000
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "app:creer_app()"]
