"""
Emergency Alert Service
Consumes alerts from SQS, notifies doctors/hospitals/responders
Receives cross-region SNS pushes via /alerts/receive
"""
import os
import json
import boto3
import logging
import threading
from datetime import datetime
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel
from typing import Optional

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Emergency Alert Service", version="1.0.0")

REGION      = os.environ["REGION"]
REGION_NAME = os.environ.get("REGION_NAME", "UNKNOWN")
SQS_URL     = os.environ["SQS_QUEUE_URL"]
SNS_TOPIC   = os.environ["SNS_TOPIC_ARN"]

sqs = boto3.client("sqs", region_name=REGION)
sns = boto3.client("sns", region_name=REGION)


class Alert(BaseModel):
    patient_id:  str
    alert_type:  str
    severity:    str
    metric:      str
    value:       float
    threshold:   dict
    region:      str
    timestamp:   str


class AlertAction(BaseModel):
    alert_id:    str
    action:      str   # ACKNOWLEDGED / DISPATCHED / RESOLVED
    responder:   str
    notes:       Optional[str] = None


# ── Alert routing rules ────────────────────────────────────────
def route_alert(alert: Alert) -> list[str]:
    """Determine who gets notified based on severity and metric"""
    recipients = []

    if alert.severity == "CRITICAL":
        recipients += ["emergency-team", "on-call-doctor", "hospital-admin"]
    elif alert.severity == "WARNING":
        recipients += ["on-call-doctor", "nurse-station"]

    if alert.metric == "oxygen_level" and alert.value < 85:
        recipients.append("icu-team")

    if alert.metric == "heart_rate" and (alert.value > 150 or alert.value < 35):
        recipients.append("cardiology-team")

    # Cross-region: CRITICAL alerts always go to all regions
    if alert.severity == "CRITICAL" and alert.region != REGION_NAME:
        recipients.append(f"regional-coordinator-{REGION_NAME.lower()}")

    return list(set(recipients))


def dispatch_notifications(alert: Alert, recipients: list[str]):
    """Send notifications — integrate with PagerDuty/Twilio/SES in production"""
    for recipient in recipients:
        logger.info(
            f"[ALERT] {alert.severity} | patient={alert.patient_id} | "
            f"metric={alert.metric}={alert.value} | to={recipient} | "
            f"origin={alert.region} | received_by={REGION_NAME}"
        )
        # Production: call PagerDuty API, send SMS via SNS, email via SES


def process_sqs_messages():
    """Background thread: poll SQS for alerts"""
    while True:
        try:
            resp = sqs.receive_message(
                QueueUrl            = SQS_URL,
                MaxNumberOfMessages = 10,
                WaitTimeSeconds     = 20,   # Long polling
                MessageAttributeNames = ["All"],
            )
            for msg in resp.get("Messages", []):
                try:
                    body = json.loads(msg["Body"])
                    # SNS wraps message in envelope
                    if "Message" in body:
                        body = json.loads(body["Message"])

                    alert = Alert(**body)
                    recipients = route_alert(alert)
                    dispatch_notifications(alert, recipients)

                    sqs.delete_message(
                        QueueUrl      = SQS_URL,
                        ReceiptHandle = msg["ReceiptHandle"],
                    )
                except Exception as e:
                    logger.error(f"Failed to process message: {e}")
        except Exception as e:
            logger.error(f"SQS polling error: {e}")


# Start background SQS consumer on startup
@app.on_event("startup")
def startup():
    t = threading.Thread(target=process_sqs_messages, daemon=True)
    t.start()
    logger.info(f"Emergency Alert Service started in {REGION_NAME}")


# ── Routes ─────────────────────────────────────────────────────
@app.get("/health")
def health():
    return {"status": "healthy", "region": REGION_NAME, "service": "emergency-alert"}


@app.post("/alerts/receive")
async def receive_cross_region_alert(request: Request):
    """
    Endpoint for cross-region SNS HTTPS subscriptions.
    India/Europe/USA push alerts here when their SNS fires.
    """
    body = await request.json()

    # Handle SNS subscription confirmation
    if body.get("Type") == "SubscriptionConfirmation":
        import urllib.request
        urllib.request.urlopen(body["SubscribeURL"])
        return {"status": "subscription confirmed"}

    if body.get("Type") == "Notification":
        try:
            alert_data = json.loads(body["Message"])
            alert = Alert(**alert_data)
            recipients = route_alert(alert)
            dispatch_notifications(alert, recipients)
            return {"status": "processed", "recipients": recipients}
        except Exception as e:
            logger.error(f"Cross-region alert processing failed: {e}")
            raise HTTPException(status_code=500, detail=str(e))

    return {"status": "ignored"}


@app.post("/alerts/{alert_id}/action")
def take_action(alert_id: str, action: AlertAction):
    """Record responder action on an alert"""
    logger.info(
        f"Action on alert {alert_id}: {action.action} by {action.responder} "
        f"in region {REGION_NAME}"
    )
    return {
        "alert_id":  alert_id,
        "action":    action.action,
        "responder": action.responder,
        "region":    REGION_NAME,
        "timestamp": datetime.utcnow().isoformat(),
    }


@app.get("/alerts/stats")
def alert_stats():
    """Get queue depth from SQS"""
    try:
        attrs = sqs.get_queue_attributes(
            QueueUrl       = SQS_URL,
            AttributeNames = ["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible"]
        )["Attributes"]
        return {
            "region":            REGION_NAME,
            "queued_alerts":     int(attrs["ApproximateNumberOfMessages"]),
            "in_flight_alerts":  int(attrs["ApproximateNumberOfMessagesNotVisible"]),
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
