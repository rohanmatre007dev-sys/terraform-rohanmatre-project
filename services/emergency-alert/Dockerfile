FROM python:3.12-slim AS base
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM base AS test
COPY requirements-test.txt* ./
RUN pip install --no-cache-dir pytest httpx || true
COPY . .
CMD ["pytest", "tests/", "-v"]

FROM base AS production
COPY . .
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD curl -f http://localhost:8081/health || exit 1
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8081"]
