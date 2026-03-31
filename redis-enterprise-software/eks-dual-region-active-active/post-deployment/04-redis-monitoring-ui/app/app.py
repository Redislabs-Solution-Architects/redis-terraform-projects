#!/usr/bin/env python3
"""
Redis Enterprise Active-Active monitoring UI with a redis-py failover demo.
"""

import base64
import http.client
import json
import os
import socket
import ssl
import subprocess
import threading
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from functools import lru_cache

import redis
import requests
import yaml
from flask import Flask, jsonify, render_template
from kubernetes import client as k8s_client
from kubernetes import config as kube_config
from redis.backoff import ExponentialWithJitterBackoff
from redis.event import EventDispatcher, EventListenerInterface
from redis.exceptions import ConnectionError as RedisConnectionError
from redis.multidb.client import MultiDBClient
from redis.multidb.config import DatabaseConfig, InitialHealthCheck, MultiDbConfig
from redis.multidb.healthcheck import HealthCheckPolicies
from redis.multidb.event import ActiveDatabaseChanged
from redis.retry import Retry
from urllib3.exceptions import InsecureRequestWarning

try:
    from redis.multidb.healthcheck import LagAwareHealthCheck
except ImportError:  # pragma: no cover - depends on redis-py preview internals
    LagAwareHealthCheck = None


requests.packages.urllib3.disable_warnings(category=InsecureRequestWarning)

try:
    kube_config.load_incluster_config()
except Exception:
    try:
        kube_config.load_kube_config()
    except Exception:
        print("Warning: Could not load Kubernetes configuration")


app = Flask(__name__)
app.config["TEMPLATES_AUTO_RELOAD"] = True
app.config["SEND_FILE_MAX_AGE_DEFAULT"] = 0

CONFIG_PATH = os.getenv("CONFIG_PATH", "/app/config/config.yaml")
with open(CONFIG_PATH, "r", encoding="utf-8") as config_file:
    APP_CONFIG = yaml.safe_load(config_file)


def utc_now():
    return datetime.now(timezone.utc).isoformat()


class InfrastructureOutageController:
    def __init__(self, demo_config):
        self.config = demo_config.get("infrastructure_outage", {}) or {}
        self.enabled = bool(self.config.get("enabled", False))
        self.aws_profile = str(self.config.get("aws_profile", "")).strip()
        self.current_public_ip = ""
        self.prepared = False
        self.region1_outage_active = False
        self.last_action = ""
        self.last_error = ""
        self.last_command = ""

    def _region_config(self, region_key):
        return self.config.get(region_key, {}) or {}

    def _run_aws(self, args):
        self.last_command = self._command_string(args)
        env = os.environ.copy()
        if self.aws_profile:
            env["AWS_PROFILE"] = self.aws_profile
        result = subprocess.run(
            ["aws", *args],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "AWS CLI command failed")
        return result.stdout.strip()

    def _command_string(self, args):
        profile_prefix = f"AWS_PROFILE={self.aws_profile} " if self.aws_profile else ""
        return profile_prefix + "aws " + " ".join(json.dumps(str(arg)) for arg in args)

    def detect_public_ip(self):
        response = requests.get("https://checkip.amazonaws.com", timeout=5)
        response.raise_for_status()
        ip = response.text.strip()
        if not ip:
            raise RuntimeError("Could not determine current public IP")
        self.current_public_ip = ip
        return ip

    def _describe_nacl(self, region_key):
        region = self._region_config(region_key).get("region", "")
        nacl_id = self._region_config(region_key).get("network_acl_id", "")
        payload = self._run_aws(
            [
                "ec2",
                "describe-network-acls",
                "--network-acl-ids",
                nacl_id,
                "--region",
                region,
                "--output",
                "json",
            ]
        )
        return json.loads(payload)["NetworkAcls"][0]

    def _find_entry(self, region_key, rule_number, egress):
        entries = self._describe_nacl(region_key).get("Entries", [])
        for entry in entries:
            if entry.get("RuleNumber") == int(rule_number) and entry.get("Egress") == bool(egress):
                return entry
        return None

    def _ensure_rule_state(self, region_key, rule_number, egress, should_exist, cidr):
        entry = self._find_entry(region_key, rule_number, egress)
        if should_exist:
            if not entry:
                raise RuntimeError(
                    f"NACL rule {rule_number} ({'egress' if egress else 'ingress'}) was not created"
                )
            if entry.get("RuleAction") != "deny" or entry.get("CidrBlock") != cidr:
                raise RuntimeError(
                    f"NACL rule {rule_number} ({'egress' if egress else 'ingress'}) does not match expected deny for {cidr}"
                )
            return

        if entry:
            raise RuntimeError(
                f"NACL rule {rule_number} ({'egress' if egress else 'ingress'}) still exists"
            )

    def _refresh_region1_outage_state(self):
        if not self.enabled:
            self.region1_outage_active = False
            return False

        inbound_rule = int(self._region_config("region1").get("deny_inbound_rule_number", 90))
        outbound_rule = int(self._region_config("region1").get("deny_outbound_rule_number", 91))
        inbound_entry = self._find_entry("region1", inbound_rule, False)
        outbound_entry = self._find_entry("region1", outbound_rule, True)
        self.region1_outage_active = bool(inbound_entry and outbound_entry)
        return self.region1_outage_active

    def _create_deny_entry(self, region_key, rule_number, egress, cidr):
        region = self._region_config(region_key).get("region", "")
        nacl_id = self._region_config(region_key).get("network_acl_id", "")
        payload = json.dumps(
            {
                "NetworkAclId": nacl_id,
                "RuleNumber": int(rule_number),
                "Protocol": "-1",
                "RuleAction": "deny",
                "Egress": bool(egress),
                "CidrBlock": cidr,
            }
        )
        args = [
            "ec2",
            "create-network-acl-entry",
            "--region",
            region,
            "--cli-input-json",
            payload,
        ]
        command_preview = self._command_string(args)
        existing = self._find_entry(region_key, rule_number, egress)
        if existing and existing.get("RuleAction") == "deny" and existing.get("CidrBlock") == cidr:
            return {"changed": False, "command": command_preview}
        if existing:
            raise RuntimeError(
                f"NACL rule {rule_number} ({'egress' if egress else 'ingress'}) already exists with different settings"
            )
        self._run_aws(args)
        return {"changed": True, "command": command_preview}

    def _delete_entry(self, region_key, rule_number, egress):
        region = self._region_config(region_key).get("region", "")
        nacl_id = self._region_config(region_key).get("network_acl_id", "")
        payload = json.dumps(
            {
                "NetworkAclId": nacl_id,
                "RuleNumber": int(rule_number),
                "Egress": bool(egress),
            }
        )
        args = [
            "ec2",
            "delete-network-acl-entry",
            "--region",
            region,
            "--cli-input-json",
            payload,
        ]
        command_preview = self._command_string(args)
        existing = self._find_entry(region_key, rule_number, egress)
        if not existing:
            return {
                "changed": False,
                "command": command_preview,
                "rule_number": int(rule_number),
                "direction": "egress" if egress else "ingress",
                "status": "already-absent",
            }
        self._run_aws(args)
        return {
            "changed": True,
            "command": command_preview,
            "rule_number": int(rule_number),
            "direction": "egress" if egress else "ingress",
            "status": "removed",
        }

    def prepare(self):
        if not self.enabled:
            raise RuntimeError("Infrastructure outage mode is not enabled")

        cidr = f"{self.detect_public_ip()}/32"
        inbound_rule = int(self._region_config("region1").get("deny_inbound_rule_number", 90))
        outbound_rule = int(self._region_config("region1").get("deny_outbound_rule_number", 91))

        self.prepared = True
        self.region1_outage_active = False
        self.last_action = f"Prepared realistic Region 1 NACL outage demo for {cidr}"
        self.last_error = ""
        return {
            "cidr": cidr,
            "commands": [],
            "nacl_rules": {
                "inbound": inbound_rule,
                "outbound": outbound_rule,
            },
        }

    def simulate_region1_outage(self):
        if not self.prepared:
            self.prepare()
        cidr = f"{self.detect_public_ip()}/32"
        inbound_rule = int(self._region_config("region1").get("deny_inbound_rule_number", 90))
        outbound_rule = int(self._region_config("region1").get("deny_outbound_rule_number", 91))
        inbound_result = self._create_deny_entry("region1", inbound_rule, False, cidr)
        outbound_result = self._create_deny_entry("region1", outbound_rule, True, cidr)
        self._ensure_rule_state("region1", inbound_rule, False, True, cidr)
        self._ensure_rule_state("region1", outbound_rule, True, True, cidr)
        self._refresh_region1_outage_state()
        self.last_action = f"Applied Region 1 NACL deny rules for {cidr}"
        self.last_error = ""
        return {
            "cidr": cidr,
            "commands": [inbound_result, outbound_result],
            "nacl_rules": {
                "inbound": inbound_rule,
                "outbound": outbound_rule,
            },
        }

    def restore_region1(self):
        if not self.enabled:
            raise RuntimeError("Infrastructure outage mode is not enabled")
        cidr = f"{self.detect_public_ip()}/32"
        inbound_rule = int(self._region_config("region1").get("deny_inbound_rule_number", 90))
        outbound_rule = int(self._region_config("region1").get("deny_outbound_rule_number", 91))
        results = []
        errors = []

        for rule_number, egress in ((inbound_rule, False), (outbound_rule, True)):
            try:
                results.append(self._delete_entry("region1", rule_number, egress))
            except Exception as exc:
                errors.append(
                    f"rule {rule_number} ({'egress' if egress else 'ingress'}): {exc}"
                )

        validation_errors = []
        for rule_number, egress in ((inbound_rule, False), (outbound_rule, True)):
            try:
                self._ensure_rule_state("region1", rule_number, egress, False, cidr)
            except Exception as exc:
                validation_errors.append(str(exc))

        self._refresh_region1_outage_state()
        self.prepared = True

        if errors or validation_errors:
            self.last_error = " ; ".join(errors + validation_errors)
            raise RuntimeError(self.last_error)

        self.last_action = f"Removed Region 1 NACL deny rules for {cidr}"
        self.last_error = ""
        return {
            "cidr": cidr,
            "commands": results,
            "nacl_rules": {
                "inbound": inbound_rule,
                "outbound": outbound_rule,
            },
        }

    def status(self):
        self._refresh_region1_outage_state()
        return {
            "enabled": self.enabled,
            "prepared": self.prepared,
            "region1_outage_active": self.region1_outage_active,
            "current_public_ip": self.current_public_ip,
            "last_action": self.last_action,
            "last_error": self.last_error,
            "last_command": self.last_command,
            "region1": self._region_config("region1"),
            "region2": self._region_config("region2"),
        }


@lru_cache(maxsize=1)
def get_core_v1():
    return k8s_client.CoreV1Api()


def decode_secret_data(secret, key, default=""):
    if not secret or not secret.data or key not in secret.data:
        return default
    return base64.b64decode(secret.data[key]).decode("utf-8").strip()


def read_secret(secret_name):
    namespace = APP_CONFIG.get("namespace", "redis-enterprise")
    return get_core_v1().read_namespaced_secret(secret_name, namespace)


def load_api_credentials(secret_name):
    if isinstance(secret_name, dict):
        region_config = secret_name
        username = str(region_config.get("api_username", "")).strip()
        password = str(region_config.get("api_password", "")).strip()
        if username or password:
            return (username, password)
        secret_name = region_config.get("monitoring_secret_name", "")

    if not secret_name:
        return ("", "")

    secret = read_secret(secret_name)
    return (
        decode_secret_data(secret, "username"),
        decode_secret_data(secret, "password"),
    )


def load_database_credentials(secret_name):
    if isinstance(secret_name, dict):
        redis_config = secret_name
        password = str(redis_config.get("password", "")).strip()
        username = str(redis_config.get("username", "")).strip()
        if password or username:
            credentials = {}
            if password:
                credentials["password"] = password
            if username:
                credentials["username"] = username
            return credentials
        secret_name = redis_config.get("database_secret_name", "")

    if not secret_name:
        return {}

    secret = read_secret(secret_name)
    password = decode_secret_data(secret, "password")
    username = decode_secret_data(secret, "username")

    credentials = {}
    if password:
        credentials["password"] = password
    if username:
        credentials["username"] = username
    return credentials


class RedisEnterpriseAPI:
    def __init__(self, region_key, region_config):
        self.region_key = region_key
        self.endpoint = region_config["api_endpoint"]
        self.connect_target = region_config.get("api_connect_target", self.endpoint)
        self.port = region_config["api_port"]
        self.base_url = f"https://{self.connect_target}:{self.port}/v1"
        self.auth = load_api_credentials(region_config)

    def _get(self, path):
        try:
            if self.connect_target != self.endpoint:
                return self._get_via_connect_target(path)

            response = requests.get(
                f"{self.base_url}/{path}",
                auth=self.auth,
                verify=False,
                timeout=5,
            )
            response.raise_for_status()
            return response.json()
        except Exception as exc:
            return {"error": str(exc)}

    def _get_via_connect_target(self, path):
        connection = TargetedHTTPSConnection(
            connect_host=self.connect_target,
            connect_port=int(self.port),
            server_hostname=self.endpoint,
            timeout=5,
        )
        auth_header = base64.b64encode(f"{self.auth[0]}:{self.auth[1]}".encode("utf-8")).decode("ascii")
        try:
            connection.request(
                "GET",
                f"/v1/{path}",
                headers={
                    "Host": self.endpoint,
                    "Authorization": f"Basic {auth_header}",
                    "Accept": "application/json",
                    "Connection": "close",
                },
            )
            response = connection.getresponse()
            payload = response.read().decode("utf-8", errors="replace")
            if response.status >= 400:
                raise requests.HTTPError(
                    f"{response.status} {response.reason} for url: https://{self.endpoint}:{self.port}/v1/{path}"
                )
            return json.loads(payload)
        finally:
            connection.close()

    def get_cluster_info(self):
        return self._get("cluster")

    def get_nodes(self):
        return self._get("nodes")

    def get_databases(self):
        return self._get("bdbs")

    def get_database(self, db_name):
        databases = self.get_databases()
        if isinstance(databases, dict) and "error" in databases:
            return databases

        for database in databases:
            if database.get("name") == db_name:
                return database

        return {"error": f"Database {db_name} not found"}


class TargetedHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, connect_host, connect_port, server_hostname, timeout=5):
        context = ssl._create_unverified_context()
        super().__init__(host=server_hostname, port=connect_port, timeout=timeout, context=context)
        self._connect_host = connect_host
        self._connect_port = connect_port
        self._server_hostname = server_hostname

    def connect(self):
        sock = socket.create_connection(
            (self._connect_host, self._connect_port),
            self.timeout,
            self.source_address,
        )
        if self._tunnel_host:
            self.sock = sock
            self._tunnel()
        self.sock = self._context.wrap_socket(sock, server_hostname=self._server_hostname)


class DemoRedisClient(redis.Redis):
    controller = None

    @classmethod
    def configure(cls, controller):
        cls.controller = controller

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        connection_kwargs = getattr(self.connection_pool, "connection_kwargs", {})
        self.demo_host = connection_kwargs.get("host", "")
        self.demo_port = str(connection_kwargs.get("port", ""))
        self.demo_region = None
        if DemoRedisClient.controller:
            self.demo_region = DemoRedisClient.controller.region_for_host(self.demo_host)

    def execute_command(self, *args, **options):
        controller = DemoRedisClient.controller
        command_name = args[0] if args else "UNKNOWN"
        command_key = args[1] if len(args) > 1 else ""

        if controller:
            controller.record_command_attempt(
                self.demo_region, self.demo_host, command_name, command_key
            )

        if controller and controller.is_region_blacked_out(self.demo_region):
            controller.record_blackout_rejection(
                self.demo_region, self.demo_host, command_name, command_key
            )
            raise RedisConnectionError(
                f"Simulated outage for {self.demo_region} at {self.demo_host}"
            )

        started_at = time.monotonic()
        try:
            result = super().execute_command(*args, **options)
            if controller:
                controller.record_command_success(
                    self.demo_region,
                    self.demo_host,
                    command_name,
                    command_key,
                    (time.monotonic() - started_at) * 1000,
                )
            return result
        except Exception as exc:
            if controller:
                controller.record_command_failure(
                    self.demo_region,
                    self.demo_host,
                    command_name,
                    command_key,
                    exc,
                    (time.monotonic() - started_at) * 1000,
                )
            raise


class FailoverEventListener(EventListenerInterface):
    def __init__(self, controller):
        self.controller = controller

    def listen(self, event):
        old_region = self.controller.region_for_database(event.old_database)
        new_region = self.controller.region_for_database(event.new_database)
        old_endpoint = self.controller.endpoint_for_database(event.old_database)
        new_endpoint = self.controller.endpoint_for_database(event.new_database)
        self.controller.record_failover_event(
            old_region, new_region, old_endpoint, new_endpoint
        )


class FailoverDemoManager:
    def __init__(self, app_config):
        self.app_config = app_config
        self.failover_config = app_config["failover"]
        self.demo_config = app_config["demo"]
        self.redis_config = app_config["redis"]
        self.outage_mode = str(self.demo_config.get("outage_mode", "app_blackout"))
        self.infrastructure_outage = InfrastructureOutageController(self.demo_config)
        self.preferred_region = self.failover_config["preferred_region"]
        self.demo_key = f"{self.demo_config['key_prefix']}:{uuid.uuid4().hex[:8]}"
        self.application_blackout_regions = set()
        self.event_log = deque(
            maxlen=int(self.demo_config.get("event_log_retention", 600))
        )
        self.stats = {
            region: {
                "successes": 0,
                "failures": 0,
                "last_latency_ms": None,
                "last_error": "",
                "last_command": "",
                "last_key": "",
            }
            for region in self.app_config["regions"]
        }
        self.lock = threading.RLock()
        self.client = None
        self.demo_thread = None
        self.stop_event = threading.Event()
        self.running = False
        self.sequence = 0
        self.current_region = None
        self.current_endpoint = ""
        self.last_success_at = ""
        self.last_error = ""
        self.last_read_value = ""
        self.last_write_key = ""
        self.state = "idle"
        self.failed_over_once = False
        self.failover_metrics = {
            "outage_started_at": "",
            "first_region1_failure_at": "",
            "failover_detected_at": "",
            "first_region2_success_at": "",
            "restore_started_at": "",
            "failback_detected_at": "",
            "first_region1_success_after_restore_at": "",
        }
        self.region_by_host = {
            region_data["redis_endpoint"]: region_key
            for region_key, region_data in self.app_config["regions"].items()
        }
        self.redis_display_by_host = {
            region_data["redis_endpoint"]: region_data.get(
                "redis_display_endpoint", region_data["redis_endpoint"]
            )
            for region_data in self.app_config["regions"].values()
        }

    def log_event(self, level, event_type, message, **details):
        with self.lock:
            self.event_log.appendleft(
                {
                    "timestamp": utc_now(),
                    "level": level,
                    "event": event_type,
                    "message": message,
                    "details": details,
                }
            )

    def _safe_value(self, value):
        if value is None:
            return ""
        if isinstance(value, bytes):
            return value.decode("utf-8", errors="replace")
        return str(value)

    def _command_key(self, raw_key):
        value = self._safe_value(raw_key)
        return value if len(value) <= 120 else f"{value[:117]}..."

    def _duration_ms(self, start_key, end_key):
        start = self.failover_metrics.get(start_key)
        end = self.failover_metrics.get(end_key)
        if not start or not end:
            return None
        start_dt = datetime.fromisoformat(start)
        end_dt = datetime.fromisoformat(end)
        return round((end_dt - start_dt).total_seconds() * 1000, 2)

    def _is_demo_command(self, command_name):
        return str(command_name).upper() in {"SET", "GET"}

    def region_for_host(self, host):
        return self.region_by_host.get(host, "")

    def display_endpoint(self, endpoint):
        return self.redis_display_by_host.get(endpoint, endpoint)

    def endpoint_for_database(self, database):
        if not database:
            return ""
        client_kwargs = getattr(database, "client_kwargs", None)
        if isinstance(client_kwargs, dict) and client_kwargs.get("host"):
            return client_kwargs["host"]
        from_url = getattr(database, "from_url", None)
        if from_url:
            return str(from_url)
        return str(database)

    def region_for_database(self, database):
        endpoint = self.endpoint_for_database(database)
        for host, region in self.region_by_host.items():
            if host and host in endpoint:
                return region
        return ""

    def is_region_blacked_out(self, region):
        with self.lock:
            return region in self.application_blackout_regions

    def _mark_active_region(self, region, endpoint):
        if not region:
            return

        previous_region = self.current_region
        if previous_region == region:
            self.current_endpoint = endpoint
            return

        self.current_region = region
        self.current_endpoint = self.display_endpoint(endpoint)

        if previous_region is None:
            self.state = "primary" if region == self.preferred_region else "failed-over"
            return

        if region != self.preferred_region:
            self.failed_over_once = True
            self.state = "failed-over"
        elif self.failed_over_once:
            self.state = "failed-back"
        else:
            self.state = "primary"

    def record_command_attempt(self, region, endpoint, command_name, command_key):
        if not self._is_demo_command(command_name):
            return
        self.log_event(
            "info",
            "command-attempt",
            f"{command_name} attempting against {region or 'unknown region'}.",
            command=command_name,
            key=self._command_key(command_key),
            region=region,
            endpoint=endpoint,
        )

    def record_command_success(
        self, region, endpoint, command_name, command_key, latency_ms
    ):
        with self.lock:
            if region and self._is_demo_command(command_name):
                self._mark_active_region(region, endpoint)
                self.stats[region]["successes"] += 1
                self.stats[region]["last_latency_ms"] = round(latency_ms, 2)
                self.stats[region]["last_error"] = ""
                self.stats[region]["last_command"] = command_name
                self.stats[region]["last_key"] = self._command_key(command_key)
            self.last_success_at = utc_now()
            self.last_error = ""
            if command_name.upper() == "SET":
                self.last_write_key = self._command_key(command_key)

            if region == "region2" and self.failover_metrics["outage_started_at"]:
                if not self.failover_metrics["first_region2_success_at"]:
                    self.failover_metrics["first_region2_success_at"] = self.last_success_at
            if (
                region == "region1"
                and self.failover_metrics["restore_started_at"]
                and not self.failover_metrics["first_region1_success_after_restore_at"]
            ):
                self.failover_metrics["first_region1_success_after_restore_at"] = (
                    self.last_success_at
                )

        if self._is_demo_command(command_name):
            self.log_event(
                "info",
                "command-success",
                f"{command_name} succeeded on {region or 'unknown region'}.",
                command=command_name,
                key=self._command_key(command_key),
                region=region,
                endpoint=endpoint,
                latency_ms=round(latency_ms, 2),
            )

    def record_command_failure(
        self, region, endpoint, command_name, command_key, error, latency_ms
    ):
        with self.lock:
            if region and self._is_demo_command(command_name):
                self.stats[region]["failures"] += 1
                self.stats[region]["last_latency_ms"] = round(latency_ms, 2)
                self.stats[region]["last_error"] = str(error)
                self.stats[region]["last_command"] = command_name
                self.stats[region]["last_key"] = self._command_key(command_key)
            self.last_error = str(error)
            if (
                region == "region1"
                and self.failover_metrics["outage_started_at"]
                and not self.failover_metrics["first_region1_failure_at"]
            ):
                self.failover_metrics["first_region1_failure_at"] = utc_now()

        if self._is_demo_command(command_name):
            self.log_event(
                "error",
                "command-failure",
                f"{command_name} failed on {region or 'unknown region'}.",
                command=command_name,
                key=self._command_key(command_key),
                region=region,
                endpoint=endpoint,
                latency_ms=round(latency_ms, 2),
                error=str(error),
            )

    def record_blackout_rejection(self, region, endpoint, command_name, command_key):
        rejected_at = utc_now()
        with self.lock:
            if (
                region == "region1"
                and self.failover_metrics["outage_started_at"]
                and not self.failover_metrics["first_region1_failure_at"]
            ):
                self.failover_metrics["first_region1_failure_at"] = rejected_at
        if self._is_demo_command(command_name):
            self.log_event(
                "warning",
                "blackout-rejection",
                f"{command_name} blocked on {region or 'unknown region'} during simulated outage.",
                command=command_name,
                key=self._command_key(command_key),
                region=region,
                endpoint=endpoint,
            )

    def record_failover_event(self, old_region, new_region, old_endpoint, new_endpoint):
        if not new_region:
            return

        with self.lock:
            self._mark_active_region(new_region, new_endpoint)
            if new_region != self.preferred_region:
                self.failover_metrics["failover_detected_at"] = utc_now()
            elif self.failover_metrics["restore_started_at"]:
                self.failover_metrics["failback_detected_at"] = utc_now()

        event_type = "failback" if new_region == self.preferred_region else "failover"
        message = f"Active Redis endpoint changed from {old_region or 'unknown'} to {new_region}."
        self.log_event(
            "info",
            event_type,
            message,
            old_region=old_region,
            new_region=new_region,
            old_endpoint=old_endpoint,
            new_endpoint=new_endpoint,
        )

    def _shared_api_credentials(self):
        if not self.failover_config.get("use_lag_aware_health_check", False):
            return None

        secrets = []
        for region_data in self.app_config["regions"].values():
            secrets.append(load_api_credentials(region_data))

        usernames = {username for username, _ in secrets if username}
        passwords = {password for _, password in secrets if password}
        if len(usernames) == 1 and len(passwords) == 1:
            return (next(iter(usernames)), next(iter(passwords)))

        self.log_event(
            "warning",
            "lag-aware-disabled",
            "Lag-aware health checks require shared REST API credentials across regions. Falling back to ping health checks.",
        )
        return None

    def _resolve_initial_health_check_policy(self):
        configured = (
            str(
                self.failover_config.get(
                    "initial_health_check_policy", "one_available"
                )
            )
            .strip()
            .upper()
        )
        aliases = {
            "ANY_AVAILABLE": "ONE_AVAILABLE",
        }
        configured = aliases.get(configured, configured)
        return getattr(
            InitialHealthCheck, configured, InitialHealthCheck.ONE_AVAILABLE
        )

    def _resolve_health_check_policy(self):
        configured = (
            str(self.failover_config.get("health_check_policy", "healthy_any"))
            .strip()
            .upper()
        )
        return getattr(HealthCheckPolicies, configured, HealthCheckPolicies.HEALTHY_ANY)

    def _build_client(self):
        redis_auth = load_database_credentials(self.redis_config)
        verify_tls = self.redis_config.get("verify_tls", False)

        db_configs = []
        for region_key, region_data in self.app_config["regions"].items():
            client_kwargs = {
                "host": region_data["redis_endpoint"],
                "port": int(region_data["redis_port"]),
                "ssl": self.redis_config.get("tls", True),
                "decode_responses": True,
                "socket_connect_timeout": float(
                    self.failover_config.get("redis_connect_timeout_seconds", 3)
                ),
                "socket_timeout": float(
                    self.failover_config.get("redis_socket_timeout_seconds", 3)
                ),
            }
            if not verify_tls:
                client_kwargs["ssl_cert_reqs"] = None
                client_kwargs["ssl_check_hostname"] = False
            client_kwargs.update(redis_auth)

            db_config = DatabaseConfig(
                client_kwargs=client_kwargs,
                weight=float(region_data["redis_weight"]),
                grace_period=float(self.failover_config["grace_period_seconds"]),
                health_check_url=region_data.get("health_check_url", ""),
            )
            db_configs.append(db_config)

        event_dispatcher = EventDispatcher()
        event_dispatcher.register_listeners(
            {
                ActiveDatabaseChanged: [FailoverEventListener(self)],
            }
        )

        health_checks = None
        if self.failover_config.get("use_lag_aware_health_check", False) and LagAwareHealthCheck:
            shared_credentials = self._shared_api_credentials()
            if shared_credentials:
                health_checks = [
                    LagAwareHealthCheck(
                        rest_api_port=int(self.failover_config["lag_aware_rest_api_port"]),
                        lag_aware_tolerance=int(self.failover_config["lag_tolerance_ms"]),
                        verify_tls=bool(self.failover_config["lag_aware_verify_tls"]),
                        auth_basic=shared_credentials,
                    )
                ]

        DemoRedisClient.configure(self)
        client_config_kwargs = dict(
            databases_config=db_configs,
            client_class=DemoRedisClient,
            failures_detection_window=float(
                self.failover_config["failures_detection_window_seconds"]
            ),
            min_num_failures=int(self.failover_config["min_num_failures"]),
            failure_rate_threshold=float(self.failover_config["failure_rate_threshold"]),
            health_check_interval=float(
                self.failover_config["health_check_interval_seconds"]
            ),
            health_check_probes=int(self.failover_config["health_check_probes"]),
            health_check_probes_delay=float(
                self.failover_config["health_check_probe_delay_seconds"]
            ),
            health_check_policy=self._resolve_health_check_policy(),
            auto_fallback_interval=float(
                self.failover_config["auto_fallback_interval_seconds"]
            ),
            failover_attempts=int(self.failover_config["failover_attempts"]),
            failover_delay=float(self.failover_config["failover_delay_seconds"]),
            command_retry=Retry(
                retries=int(self.failover_config["command_retries"]),
                backoff=ExponentialWithJitterBackoff(base=1, cap=5),
            ),
            event_dispatcher=event_dispatcher,
            initial_health_check_policy=self._resolve_initial_health_check_policy(),
        )
        if health_checks:
            client_config_kwargs["health_checks"] = health_checks

        return MultiDBClient(MultiDbConfig(**client_config_kwargs))

    def ensure_client(self):
        with self.lock:
            if self.client is None:
                self.client = self._build_client()
                self.log_event(
                    "info",
                    "client-ready",
                    "Initialized redis-py failover client.",
                    preferred_region=self.preferred_region,
                )
            return self.client

    def recycle_client(self, reason):
        with self.lock:
            client = self.client
            self.client = None

        if client is not None:
            close_fn = getattr(client, "close", None)
            if callable(close_fn):
                try:
                    close_fn()
                except Exception:
                    pass
            disconnect_fn = getattr(client, "disconnect", None)
            if callable(disconnect_fn):
                try:
                    disconnect_fn()
                except Exception:
                    pass

        self.log_event(
            "info",
            "client-recycled",
            "Rebuilt the redis-py failover client after a connectivity change.",
            reason=reason,
        )

    def _workload_loop(self):
        while not self.stop_event.is_set():
            self.run_workload_cycle()
            self.stop_event.wait(float(self.demo_config["workload_interval_seconds"]))

    def run_workload_cycle(self):
        next_sequence = self.sequence + 1
        operation_key = f"{self.demo_key}:seq:{next_sequence}"
        payload = {
            "sequence": next_sequence,
            "timestamp": utc_now(),
            "source": "redis-monitoring-ui-failover-demo",
        }
        max_attempts = int(self.demo_config.get("workload_command_attempts", 2))
        last_error = None

        for attempt in range(1, max_attempts + 1):
            phase = "set"
            try:
                client = self.ensure_client()
                self.log_event(
                    "info",
                    "workload-attempt",
                    "Starting synthetic workload cycle.",
                    attempt=attempt,
                    max_attempts=max_attempts,
                    key=operation_key,
                )
                client.set(operation_key, json.dumps(payload))
                phase = "get"
                value = client.get(operation_key)
                with self.lock:
                    self.sequence = next_sequence
                    self.last_read_value = value
                    self.last_write_key = operation_key
                    if self.state == "idle":
                        self.state = "primary"
                return True
            except Exception as exc:
                last_error = exc
                with self.lock:
                    self.last_error = str(exc)
                    if self.current_region is None:
                        self.state = "unavailable"
                self.log_event(
                    "warning" if attempt < max_attempts else "error",
                    "workload-retry" if attempt < max_attempts else "workload-error",
                    "Synthetic workload cycle failed." if attempt == max_attempts else "Synthetic workload cycle failed, retrying with a fresh failover client.",
                    attempt=attempt,
                    max_attempts=max_attempts,
                    phase=phase,
                    key=operation_key,
                    error=str(exc),
                )
                if attempt < max_attempts:
                    self.recycle_client(f"workload-{phase}-retry-{attempt}")

        if last_error is not None:
            return False
        return False

    def start_demo(self):
        with self.lock:
            if self.running:
                return
            self.stop_event.clear()
            self.running = True
            self.state = "primary"
            self.demo_thread = threading.Thread(
                target=self._workload_loop,
                name="redis-failover-demo",
                daemon=True,
            )
            self.demo_thread.start()
        self.log_event(
            "info",
            "demo-started",
            "Started synthetic Redis workload for the failover demo.",
            demo_key=self.demo_key,
        )

    def simulate_region1_outage(self):
        with self.lock:
            self.failover_metrics["outage_started_at"] = utc_now()
            self.failover_metrics["first_region1_failure_at"] = ""
            self.failover_metrics["failover_detected_at"] = ""
            self.failover_metrics["first_region2_success_at"] = ""

        if self.outage_mode == "infrastructure" and self.infrastructure_outage.enabled:
            result = self.infrastructure_outage.simulate_region1_outage()
            self.log_event(
                "warning",
                "simulated-outage",
                "Simulated a Region 1 network outage by applying NACL deny rules for the local client.",
                region="region1",
                mode="infrastructure",
                client_cidr=result["cidr"],
                aws_commands=" | ".join(
                    command["command"]
                    for command in result["commands"]
                    if command.get("command")
                ),
                nacl_inbound_rule=result["nacl_rules"]["inbound"],
                nacl_outbound_rule=result["nacl_rules"]["outbound"],
            )
            return

        with self.lock:
            self.application_blackout_regions.add("region1")
        self.log_event(
            "warning",
            "simulated-outage",
            "Simulated a Region 1 outage for this app instance.",
            region="region1",
            mode="app_blackout",
        )

    def restore_region1(self):
        with self.lock:
            self.failover_metrics["restore_started_at"] = utc_now()
            self.failover_metrics["failback_detected_at"] = ""
            self.failover_metrics["first_region1_success_after_restore_at"] = ""

        if self.outage_mode == "infrastructure" and self.infrastructure_outage.enabled:
            result = self.infrastructure_outage.restore_region1()
            self.log_event(
                "info",
                "region-restored",
                "Restored Region 1 network access by removing the NACL deny rules for the local client.",
                region="region1",
                mode="infrastructure",
                client_cidr=result["cidr"],
                aws_commands=" | ".join(
                    command["command"]
                    for command in result["commands"]
                    if command.get("command")
                ),
                nacl_inbound_rule=result["nacl_rules"]["inbound"],
                nacl_outbound_rule=result["nacl_rules"]["outbound"],
            )
            self.recycle_client("region1-network-restore")
            return

        with self.lock:
            self.application_blackout_regions.discard("region1")
        self.log_event(
            "info",
            "region-restored",
            "Restored Region 1 connectivity for this app instance.",
            region="region1",
            mode="app_blackout",
        )

    def prepare_infrastructure_outage(self):
        result = self.infrastructure_outage.prepare()
        self.log_event(
            "info",
            "infrastructure-prepared",
            "Prepared Region 1 NACL rules for realistic outage simulation.",
            region="region1",
            mode="infrastructure",
            client_cidr=result["cidr"],
            aws_commands=" | ".join(
                command["command"]
                for command in result["commands"]
                if command.get("command")
            ),
            nacl_inbound_rule=result["nacl_rules"]["inbound"],
            nacl_outbound_rule=result["nacl_rules"]["outbound"],
        )

    def reset_demo(self):
        if (
            self.outage_mode == "infrastructure"
            and self.infrastructure_outage.enabled
            and self.infrastructure_outage.region1_outage_active
        ):
            self.infrastructure_outage.restore_region1()

        with self.lock:
            self.stop_event.set()
            thread = self.demo_thread
            self.demo_thread = None
            self.running = False
            self.client = None
            self.sequence = 0
            self.current_region = None
            self.current_endpoint = ""
            self.last_success_at = ""
            self.last_error = ""
            self.last_read_value = ""
            self.last_write_key = ""
            self.state = "idle"
            self.failed_over_once = False
            self.application_blackout_regions.clear()
            self.event_log.clear()
            self.failover_metrics = {
                "outage_started_at": "",
                "first_region1_failure_at": "",
                "failover_detected_at": "",
                "first_region2_success_at": "",
                "restore_started_at": "",
                "failback_detected_at": "",
                "first_region1_success_after_restore_at": "",
            }
            for region in self.stats:
                self.stats[region] = {
                    "successes": 0,
                    "failures": 0,
                    "last_latency_ms": None,
                    "last_error": "",
                    "last_command": "",
                    "last_key": "",
                }

        if thread and thread.is_alive():
            thread.join(timeout=2)

        self.log_event(
            "info",
            "demo-reset",
            "Reset failover demo state and rebuilt the client on the next start.",
        )

    def get_status(self):
        with self.lock:
            return {
                "demo_running": self.running,
                "state": self.state,
                "preferred_region": self.preferred_region,
                "active_region": self.current_region,
                "active_endpoint": self.current_endpoint,
                "blackout_regions": sorted(self.application_blackout_regions),
                "outage_regions": (
                    ["region1"]
                    if self.infrastructure_outage.region1_outage_active
                    else sorted(self.application_blackout_regions)
                ),
                "last_success_at": self.last_success_at,
                "last_error": self.last_error,
                "last_read_value": self.last_read_value,
                "last_write_key": self.last_write_key,
                "sequence": self.sequence,
                "demo_key": self.demo_key,
                "outage_mode": self.outage_mode,
                "stats": self.stats,
                "event_log": list(self.event_log),
                "failover_metrics": self.failover_metrics,
                "infrastructure_outage": self.infrastructure_outage.status(),
                "timing_summary": {
                    "outage_to_first_failure_ms": self._duration_ms(
                        "outage_started_at", "first_region1_failure_at"
                    ),
                    "outage_to_failover_detected_ms": self._duration_ms(
                        "outage_started_at", "failover_detected_at"
                    ),
                    "outage_to_region2_success_ms": self._duration_ms(
                        "outage_started_at", "first_region2_success_at"
                    ),
                    "restore_to_failback_detected_ms": self._duration_ms(
                        "restore_started_at", "failback_detected_at"
                    ),
                    "restore_to_region1_success_ms": self._duration_ms(
                        "restore_started_at", "first_region1_success_after_restore_at"
                    ),
                },
                "workload_interval_seconds": self.demo_config["workload_interval_seconds"],
                "auto_fallback_interval_seconds": self.failover_config[
                    "auto_fallback_interval_seconds"
                ],
                "health_check_mode": (
                    "lag-aware"
                    if self.failover_config.get("use_lag_aware_health_check", False)
                    else "ping"
                ),
                "initial_health_check_policy": str(
                    self._resolve_initial_health_check_policy().value
                ),
                "health_check_policy": self._resolve_health_check_policy().name,
            }


DEMO_MANAGER = FailoverDemoManager(APP_CONFIG)
if APP_CONFIG["demo"].get("auto_start", False):
    DEMO_MANAGER.start_demo()


@app.route("/")
def index():
    return render_template(
        "index.html",
        config=APP_CONFIG,
        refresh_interval=APP_CONFIG["refresh_interval"],
    )


@app.after_request
def disable_response_caching(response):
    response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate, max-age=0"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
    return response


@app.route("/api/cluster/<region>")
def get_cluster_status(region):
    if region not in APP_CONFIG["regions"]:
        return jsonify({"error": "Invalid region"}), 400

    api = RedisEnterpriseAPI(region, APP_CONFIG["regions"][region])
    return jsonify(
        {
            "region": region,
            "cluster": api.get_cluster_info(),
            "nodes": api.get_nodes(),
            "timestamp": utc_now(),
        }
    )


@app.route("/api/database/<region>")
def get_database_status(region):
    if region not in APP_CONFIG["regions"]:
        return jsonify({"error": "Invalid region"}), 400

    api = RedisEnterpriseAPI(region, APP_CONFIG["regions"][region])
    return jsonify(
        {
            "region": region,
            "database": api.get_database(APP_CONFIG["database_name"]),
            "timestamp": utc_now(),
        }
    )


@app.route("/api/crdb")
def get_crdb_status():
    result = {}
    for region_key, region_config in APP_CONFIG["regions"].items():
        api = RedisEnterpriseAPI(region_key, region_config)
        result[region_key] = api.get_database(APP_CONFIG["database_name"])

    return jsonify(
        {
            "database_name": APP_CONFIG["database_name"],
            "regions": result,
            "timestamp": utc_now(),
        }
    )


@app.route("/api/demo/status")
def get_demo_status():
    return jsonify(DEMO_MANAGER.get_status())


@app.route("/api/demo/start", methods=["POST"])
def start_demo():
    try:
        DEMO_MANAGER.start_demo()
        return jsonify(DEMO_MANAGER.get_status())
    except Exception as exc:
        DEMO_MANAGER.log_event(
            "error",
            "demo-action-error",
            "Start Demo failed.",
            action="start",
            error=str(exc),
        )
        return jsonify({"error": str(exc), "status": DEMO_MANAGER.get_status()}), 500


@app.route("/api/demo/prepare-infrastructure-outage", methods=["POST"])
def prepare_infrastructure_outage():
    try:
        DEMO_MANAGER.prepare_infrastructure_outage()
        return jsonify(DEMO_MANAGER.get_status())
    except Exception as exc:
        DEMO_MANAGER.log_event(
            "error",
            "demo-action-error",
            "Prepare Network Outage Demo failed.",
            action="prepare-infrastructure-outage",
            error=str(exc),
        )
        return jsonify({"error": str(exc), "status": DEMO_MANAGER.get_status()}), 500


@app.route("/api/demo/simulate-region1-outage", methods=["POST"])
def simulate_region1_outage():
    try:
        DEMO_MANAGER.simulate_region1_outage()
        return jsonify(DEMO_MANAGER.get_status())
    except Exception as exc:
        DEMO_MANAGER.log_event(
            "error",
            "demo-action-error",
            "Simulate Region 1 Outage failed.",
            action="simulate-region1-outage",
            error=str(exc),
        )
        return jsonify({"error": str(exc), "status": DEMO_MANAGER.get_status()}), 500


@app.route("/api/demo/restore-region1", methods=["POST"])
def restore_region1():
    try:
        DEMO_MANAGER.restore_region1()
        return jsonify(DEMO_MANAGER.get_status())
    except Exception as exc:
        DEMO_MANAGER.log_event(
            "error",
            "demo-action-error",
            "Restore Region 1 failed.",
            action="restore-region1",
            error=str(exc),
        )
        return jsonify({"error": str(exc), "status": DEMO_MANAGER.get_status()}), 500


@app.route("/api/demo/reset", methods=["POST"])
def reset_demo():
    try:
        DEMO_MANAGER.reset_demo()
        return jsonify(DEMO_MANAGER.get_status())
    except Exception as exc:
        DEMO_MANAGER.log_event(
            "error",
            "demo-action-error",
            "Reset Demo failed.",
            action="reset",
            error=str(exc),
        )
        return jsonify({"error": str(exc), "status": DEMO_MANAGER.get_status()}), 500


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "timestamp": utc_now()})


if __name__ == "__main__":
    app.run(
        host=os.getenv("APP_HOST", "0.0.0.0"),
        port=int(os.getenv("APP_PORT", "5000")),
        debug=False,
    )
