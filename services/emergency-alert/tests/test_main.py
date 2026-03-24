"""Tests for Emergency Alert Service"""
import pytest
from unittest.mock import patch, MagicMock
import os

os.environ.setdefault("REGION", "ap-south-1")
os.environ.setdefault("REGION_NAME", "INDIA")
os.environ.setdefault("SNS_TOPIC_ARN", "arn:aws:sns:ap-south-1:123456789012:india-emergency-alerts")
os.environ.setdefault("SQS_QUEUE_URL", "https://sqs.ap-south-1.amazonaws.com/123456789012/india-alert-queue")

with patch("boto3.client"), patch("threading.Thread"):
    from main import app, route_alert, Alert
    from fastapi.testclient import TestClient

client = TestClient(app)


def make_alert(**kwargs):
    defaults = dict(
        patient_id="P001", alert_type="VITAL_SIGN_ABNORMAL",
        severity="WARNING", metric="heart_rate", value=130.0,
        threshold={"min": 40, "max": 120}, region="INDIA",
        timestamp="2024-01-01T00:00:00"
    )
    defaults.update(kwargs)
    return Alert(**defaults)


def test_health():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["service"] == "emergency-alert"


def test_critical_alert_routes_to_emergency_team():
    alert = make_alert(severity="CRITICAL")
    recipients = route_alert(alert)
    assert "emergency-team" in recipients
    assert "on-call-doctor" in recipients


def test_warning_alert_routes_to_doctor():
    alert = make_alert(severity="WARNING")
    recipients = route_alert(alert)
    assert "on-call-doctor" in recipients
    assert "emergency-team" not in recipients


def test_low_oxygen_routes_to_icu():
    alert = make_alert(metric="oxygen_level", value=82.0, severity="CRITICAL")
    recipients = route_alert(alert)
    assert "icu-team" in recipients


def test_cross_region_alert_adds_coordinator():
    alert = make_alert(severity="CRITICAL", region="EUROPE")
    recipients = route_alert(alert)
    assert "regional-coordinator-india" in recipients


def test_receive_sns_subscription_confirmation():
    with patch("urllib.request.urlopen") as mock_url:
        resp = client.post("/alerts/receive", json={
            "Type": "SubscriptionConfirmation",
            "SubscribeURL": "https://sns.aws.com/confirm/token123"
        })
        assert resp.status_code == 200
        mock_url.assert_called_once()
