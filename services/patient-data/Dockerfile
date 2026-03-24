FROM python:3.12-slim AS base
WORKDIR /app
RUN apt-get update && apt-get install -y libpq-dev gcc curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM base AS test

ENV PYTHONPATH=/app

COPY requirements-test.txt* ./
RUN pip install --no-cache-dir pytest httpx pytest-mock || true
COPY . .
CMD ["pytest", "tests/", "-v"]

FROM base AS production
COPY . .
EXPOSE 8082
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -f http://localhost:8082/health || exit 1
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8082"]
