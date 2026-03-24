"""
Patient Data Service
CRUD for patient records — PostgreSQL backend
Enforces region-based data residency
"""
import os
import json
import logging
import psycopg2
import psycopg2.extras
import boto3
from datetime import datetime
from fastapi import FastAPI, HTTPException, Depends
from pydantic import BaseModel
from typing import Optional, List
from contextlib import contextmanager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Patient Data Service", version="1.0.0")

REGION      = os.environ["REGION"]
REGION_NAME = os.environ.get("REGION_NAME", "UNKNOWN")
DB_SECRET   = os.environ["DB_SECRET_ARN"]

secretsmanager = boto3.client("secretsmanager", region_name=REGION)


def get_db_config():
    """Fetch DB credentials from Secrets Manager (cached after first call)"""
    if not hasattr(get_db_config, "_cache"):
        resp = secretsmanager.get_secret_value(SecretId=DB_SECRET)
        get_db_config._cache = json.loads(resp["SecretString"])
    return get_db_config._cache


@contextmanager
def get_connection():
    cfg = get_db_config()
    conn = psycopg2.connect(
        host     = cfg["host"],
        port     = cfg["port"],
        user     = cfg["username"],
        password = cfg["password"],
        dbname   = cfg["dbname"],
        sslmode  = "require",
    )
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# ── Schema bootstrap ───────────────────────────────────────────
SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS patients (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_code    VARCHAR(50) UNIQUE NOT NULL,
    full_name       VARCHAR(200) NOT NULL,
    date_of_birth   DATE NOT NULL,
    blood_type      VARCHAR(5),
    region          VARCHAR(20) NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT now(),
    updated_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS vitals_history (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      UUID NOT NULL REFERENCES patients(id),
    heart_rate      NUMERIC(5,1),
    oxygen_level    NUMERIC(5,1),
    systolic_bp     NUMERIC(5,1),
    diastolic_bp    NUMERIC(5,1),
    recorded_at     TIMESTAMPTZ DEFAULT now(),
    region          VARCHAR(20) NOT NULL,
    device_id       VARCHAR(100),
    alert_triggered BOOLEAN DEFAULT false
);

CREATE INDEX IF NOT EXISTS idx_vitals_patient ON vitals_history(patient_id);
CREATE INDEX IF NOT EXISTS idx_vitals_recorded ON vitals_history(recorded_at DESC);
"""


@app.on_event("startup")
def startup():
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(SCHEMA_SQL)
        logger.info(f"Patient Data Service started in {REGION_NAME}, schema ready")
    except Exception as e:
        logger.error(f"Schema bootstrap failed: {e}")


# ── Models ─────────────────────────────────────────────────────
class PatientCreate(BaseModel):
    patient_code:  str
    full_name:     str
    date_of_birth: str   # ISO format YYYY-MM-DD
    blood_type:    Optional[str] = None


class VitalRecord(BaseModel):
    patient_id:      str
    heart_rate:      Optional[float] = None
    oxygen_level:    Optional[float] = None
    systolic_bp:     Optional[float] = None
    diastolic_bp:    Optional[float] = None
    device_id:       Optional[str] = None
    alert_triggered: bool = False


# ── Routes ─────────────────────────────────────────────────────
@app.get("/health")
def health():
    try:
        with get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
        return {"status": "healthy", "region": REGION_NAME, "db": "connected"}
    except Exception:
        return {"status": "degraded", "region": REGION_NAME, "db": "disconnected"}


@app.post("/patients", status_code=201)
def create_patient(p: PatientCreate):
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            try:
                cur.execute(
                    """INSERT INTO patients (patient_code, full_name, date_of_birth, blood_type, region)
                       VALUES (%s, %s, %s, %s, %s) RETURNING *""",
                    (p.patient_code, p.full_name, p.date_of_birth, p.blood_type, REGION_NAME)
                )
                return dict(cur.fetchone())
            except psycopg2.errors.UniqueViolation:
                raise HTTPException(status_code=409, detail=f"Patient {p.patient_code} already exists")


@app.get("/patients/{patient_code}")
def get_patient(patient_code: str):
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT * FROM patients WHERE patient_code = %s", (patient_code,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Patient not found")
            return dict(row)


@app.post("/vitals")
def record_vitals(v: VitalRecord):
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            # Resolve patient_code → UUID
            cur.execute("SELECT id FROM patients WHERE patient_code = %s", (v.patient_id,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=404, detail="Patient not found")
            patient_uuid = row["id"]

            cur.execute(
                """INSERT INTO vitals_history
                     (patient_id, heart_rate, oxygen_level, systolic_bp, diastolic_bp,
                      device_id, alert_triggered, region)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s) RETURNING *""",
                (patient_uuid, v.heart_rate, v.oxygen_level, v.systolic_bp, v.diastolic_bp,
                 v.device_id, v.alert_triggered, REGION_NAME)
            )
            return dict(cur.fetchone())


@app.get("/patients/{patient_code}/vitals")
def get_vitals_history(patient_code: str, limit: int = 50):
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """SELECT vh.* FROM vitals_history vh
                   JOIN patients p ON p.id = vh.patient_id
                   WHERE p.patient_code = %s
                   ORDER BY vh.recorded_at DESC LIMIT %s""",
                (patient_code, limit)
            )
            return [dict(r) for r in cur.fetchall()]
