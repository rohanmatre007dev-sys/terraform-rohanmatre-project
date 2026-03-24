"""Tests for Patient Monitoring Service"""
import pytest
from unittest.mock import patch, MagicMock
import os

os.environ.setdefault("REGION", "ap-south-1")
os.environ.setdefault("REGION_NAME", "INDIA")
os.environ.setdefault("SNS_TOPIC_ARN", "arn:aws:sns:ap-south-1:123456789012:india-emergency-alerts")
os.environ.setdefault("SQS_QUEUE_URL", "https://sqs.ap-south-1.amazonaws.com/123456789012/india-alert-queue")

from fastapi.testclient import TestClient

with patch("boto3.client"):
    from main import app, check_vitals, VitalSigns

client = TestClient(app)


def test_health_check():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "healthy"
    assert resp.json()["region"] == "INDIA"


def test_normal_vitals_no_alerts():
    vitals = VitalSigns(
        patient_id="P001",
        heart_rate=72,
        oxygen_level=98,
        systolic_bp=120,
        diastolic_bp=80,
    )
    alerts = check_vitals(vitals)
    assert len(alerts) == 0


def test_low_oxygen_triggers_critical():
    vitals = VitalSigns(
        patient_id="P002",
        heart_rate=72,
        oxygen_level=82,   # Below 90 threshold AND below 90*0.9=81 → WARNING
        systolic_bp=120,
        diastolic_bp=80,
    )
    alerts = check_vitals(vitals)
    oxygen_alerts = [a for a in alerts if a.metric == "oxygen_level"]
    assert len(oxygen_alerts) == 1
    assert oxygen_alerts[0].severity in ("WARNING", "CRITICAL")


def test_high_heart_rate_triggers_warning():
    vitals = VitalSigns(
        patient_id="P003",
        heart_rate=135,    # Above 120 but below 120*1.1=132 → CRITICAL
        oxygen_level=98,
        systolic_bp=120,
        diastolic_bp=80,
    )
    alerts = check_vitals(vitals)
    hr_alerts = [a for a in alerts if a.metric == "heart_rate"]
    assert len(hr_alerts) == 1


@patch("main.publish_alert")
def test_post_vitals_returns_alert_count(mock_publish):
    resp = client.post("/vitals", json={
        "patient_id": "P004",
        "heart_rate": 200,        # Critical
        "oxygen_level": 70,       # Critical
        "systolic_bp": 120,
        "diastolic_bp": 80,
    })
    assert resp.status_code == 200
    data = resp.json()
    assert data["alerts_raised"] == 2
    assert mock_publish.call_count == 2
