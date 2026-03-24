# =============================================================
# Patient Monitoring Service
# =============================================================
FROM python:3.12-slim AS base

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Test stage
FROM base AS test

ENV PYTHONPATH=/app

COPY requirements-test.txt .
RUN pip install --no-cache-dir -r requirements-test.txt
COPY . .
CMD ["pytest", "tests/", "-v"]

# Production stage
FROM base AS production
COPY . .
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
