"""
Patient Monitoring Service
Collects: heart rate, oxygen levels, blood pressure
Region-aware, publishes emergency alerts to SNS
"""
import os
import json
import boto3
import logging
from datetime import datetime
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from typing import Optional

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Patient Monitoring Service", version="1.0.0")

# ── AWS clients ────────────────────────────────────────────────
REGION      = os.environ["REGION"]
REGION_NAME = os.environ.get("REGION_NAME", "UNKNOWN")
SNS_TOPIC   = os.environ["SNS_TOPIC_ARN"]
SQS_URL     = os.environ["SQS_QUEUE_URL"]

sns = boto3.client("sns", region_name=REGION)
sqs = boto3.client("sqs", region_name=REGION)

# ── Thresholds ─────────────────────────────────────────────────
THRESHOLDS = {
    "heart_rate":   {"min": 40,  "max": 120},  # bpm
    "oxygen_level": {"min": 90,  "max": 100},  # SpO2 %
    "systolic_bp":  {"min": 80,  "max": 180},  # mmHg
    "diastolic_bp": {"min": 50,  "max": 110},  # mmHg
}


# ── Models ─────────────────────────────────────────────────────
class VitalSigns(BaseModel):
    patient_id:   str
    heart_rate:   float = Field(..., description="Heart rate in bpm")
    oxygen_level: float = Field(..., description="SpO2 percentage")
    systolic_bp:  float = Field(..., description="Systolic blood pressure mmHg")
    diastolic_bp: float = Field(..., description="Diastolic blood pressure mmHg")
    device_id:    Optional[str] = None
    timestamp:    Optional[str] = None


class AlertPayload(BaseModel):
    patient_id:  str
    alert_type:  str
    severity:    str   # CRITICAL / WARNING
    metric:      str
    value:       float
    threshold:   dict
    region:      str
    timestamp:   str


# ── Helpers ────────────────────────────────────────────────────
def check_vitals(data: VitalSigns) -> list[AlertPayload]:
    alerts = []
    now = datetime.utcnow().isoformat()

    checks = {
        "heart_rate":   data.heart_rate,
        "oxygen_level": data.oxygen_level,
        "systolic_bp":  data.systolic_bp,
        "diastolic_bp": data.diastolic_bp,
    }

    for metric, value in checks.items():
        t = THRESHOLDS[metric]
        if value < t["min"] or value > t["max"]:
            severity = "CRITICAL" if (value < t["min"] * 0.9 or value > t["max"] * 1.1) else "WARNING"
            alerts.append(AlertPayload(
                patient_id  = data.patient_id,
                alert_type  = "VITAL_SIGN_ABNORMAL",
                severity    = severity,
                metric      = metric,
                value       = value,
                threshold   = t,
                region      = REGION_NAME,
                timestamp   = now,
            ))
    return alerts


def publish_alert(alert: AlertPayload):
    """Publish to SNS → fan-out to SQS + cross-region subscriptions"""
    try:
        sns.publish(
            TopicArn = SNS_TOPIC,
            Message  = alert.model_dump_json(),
            Subject  = f"[{alert.severity}] {alert.alert_type} — Patient {alert.patient_id}",
            MessageAttributes={
                "severity": {"DataType": "String", "StringValue": alert.severity},
                "region":   {"DataType": "String", "StringValue": alert.region},
                "metric":   {"DataType": "String", "StringValue": alert.metric},
            }
        )
        logger.info(f"Alert published: patient={alert.patient_id} metric={alert.metric} region={alert.region}")
    except Exception as e:
        logger.error(f"Failed to publish alert: {e}")
        raise


# ── Routes ─────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "healthy", "region": REGION_NAME, "service": "patient-monitoring"}


@app.post("/vitals")
def ingest_vitals(data: VitalSigns):
    """Ingest vital signs and trigger alerts if thresholds exceeded"""
    data.timestamp = data.timestamp or datetime.utcnow().isoformat()

    alerts = check_vitals(data)
    published = []

    for alert in alerts:
        publish_alert(alert)
        published.append({"metric": alert.metric, "severity": alert.severity})

    return {
        "patient_id": data.patient_id,
        "region":     REGION_NAME,
        "timestamp":  data.timestamp,
        "alerts_raised": len(alerts),
        "alerts": published,
    }


@app.get("/patients/{patient_id}/status")
def patient_status(patient_id: str):
    """Get latest status for a patient (placeholder — integrate with patient-data service)"""
    return {
        "patient_id": patient_id,
        "region":     REGION_NAME,
        "status":     "monitored",
    }
