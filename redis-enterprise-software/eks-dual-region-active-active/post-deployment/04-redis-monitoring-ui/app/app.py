#!/usr/bin/env python3
"""
Redis Enterprise Active-Active monitoring UI with a redis-py failover demo.
"""

import base64
import json
import os
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
from redis.multidb.config import DatabaseConfig, MultiDbConfig
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

CONFIG_PATH = os.getenv("CONFIG_PATH", "/app/config/config.yaml")
with open(CONFIG_PATH, "r", encoding="utf-8") as config_file:
    APP_CONFIG = yaml.safe_load(config_file)


def utc_now():
    return datetime.now(timezone.utc).isoformat()


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
    secret = read_secret(secret_name)
    return (
        decode_secret_data(secret, "username"),
        decode_secret_data(secret, "password"),
    )


def load_database_credentials(secret_name):
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
        self.port = region_config["api_port"]
        self.base_url = f"https://{self.endpoint}:{self.port}/v1"
        self.auth = load_api_credentials(region_config["monitoring_secret_name"])

    def _get(self, path):
        try:
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

        if controller and controller.is_region_blacked_out(self.demo_region):
            controller.record_blackout_rejection(
                self.demo_region, self.demo_host, command_name
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
                    (time.monotonic() - started_at) * 1000,
                )
            return result
        except Exception as exc:
            if controller:
                controller.record_command_failure(
                    self.demo_region,
                    self.demo_host,
                    command_name,
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
        self.preferred_region = self.failover_config["preferred_region"]
        self.demo_key = f"{self.demo_config['key_prefix']}:{uuid.uuid4().hex[:8]}"
        self.blackout_regions = set()
        self.event_log = deque(maxlen=50)
        self.stats = {
            region: {
                "successes": 0,
                "failures": 0,
                "last_latency_ms": None,
                "last_error": "",
                "last_command": "",
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
        self.state = "idle"
        self.failed_over_once = False
        self.region_by_host = {
            region_data["redis_endpoint"]: region_key
            for region_key, region_data in self.app_config["regions"].items()
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

    def region_for_host(self, host):
        return self.region_by_host.get(host, "")

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
            return region in self.blackout_regions

    def _mark_active_region(self, region, endpoint):
        if not region:
            return

        previous_region = self.current_region
        if previous_region == region:
            self.current_endpoint = endpoint
            return

        self.current_region = region
        self.current_endpoint = endpoint

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

    def record_command_success(self, region, endpoint, command_name, latency_ms):
        with self.lock:
            if region:
                self._mark_active_region(region, endpoint)
                self.stats[region]["successes"] += 1
                self.stats[region]["last_latency_ms"] = round(latency_ms, 2)
                self.stats[region]["last_error"] = ""
                self.stats[region]["last_command"] = command_name
            self.last_success_at = utc_now()
            self.last_error = ""

    def record_command_failure(self, region, endpoint, command_name, error, latency_ms):
        with self.lock:
            if region:
                self.stats[region]["failures"] += 1
                self.stats[region]["last_latency_ms"] = round(latency_ms, 2)
                self.stats[region]["last_error"] = str(error)
                self.stats[region]["last_command"] = command_name
            self.last_error = str(error)

    def record_blackout_rejection(self, region, endpoint, command_name):
        self.log_event(
            "warning",
            "blackout-rejection",
            f"Blocked {command_name} on {region or 'unknown region'} during simulated outage.",
            region=region,
            endpoint=endpoint,
        )

    def record_failover_event(self, old_region, new_region, old_endpoint, new_endpoint):
        if not new_region:
            return

        with self.lock:
            self._mark_active_region(new_region, new_endpoint)

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
            secrets.append(load_api_credentials(region_data["monitoring_secret_name"]))

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

    def _build_client(self):
        redis_auth = load_database_credentials(self.redis_config.get("database_secret_name", ""))
        verify_tls = self.redis_config.get("verify_tls", False)

        db_configs = []
        for region_key, region_data in self.app_config["regions"].items():
            client_kwargs = {
                "host": region_data["redis_endpoint"],
                "port": int(region_data["redis_port"]),
                "ssl": self.redis_config.get("tls", True),
                "decode_responses": True,
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
        )
        if health_checks:
            client_config_kwargs["health_check"] = health_checks

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

    def _workload_loop(self):
        while not self.stop_event.is_set():
            self.run_workload_cycle()
            self.stop_event.wait(float(self.demo_config["workload_interval_seconds"]))

    def run_workload_cycle(self):
        client = self.ensure_client()
        payload = {
            "sequence": self.sequence + 1,
            "timestamp": utc_now(),
            "source": "redis-monitoring-ui-failover-demo",
        }
        try:
            client.set(self.demo_key, json.dumps(payload))
            value = client.get(self.demo_key)
            with self.lock:
                self.sequence += 1
                self.last_read_value = value
                if self.state == "idle":
                    self.state = "primary"
            return True
        except Exception as exc:
            with self.lock:
                self.last_error = str(exc)
                if self.current_region is None:
                    self.state = "unavailable"
            self.log_event(
                "error",
                "workload-error",
                "Synthetic workload cycle failed.",
                error=str(exc),
            )
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
            self.blackout_regions.add("region1")
        self.log_event(
            "warning",
            "simulated-outage",
            "Simulated a Region 1 outage for this app instance.",
            region="region1",
        )

    def restore_region1(self):
        with self.lock:
            self.blackout_regions.discard("region1")
        self.log_event(
            "info",
            "region-restored",
            "Restored Region 1 connectivity for this app instance.",
            region="region1",
        )

    def reset_demo(self):
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
            self.state = "idle"
            self.failed_over_once = False
            self.blackout_regions.clear()
            self.event_log.clear()
            for region in self.stats:
                self.stats[region] = {
                    "successes": 0,
                    "failures": 0,
                    "last_latency_ms": None,
                    "last_error": "",
                    "last_command": "",
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
                "blackout_regions": sorted(self.blackout_regions),
                "last_success_at": self.last_success_at,
                "last_error": self.last_error,
                "last_read_value": self.last_read_value,
                "sequence": self.sequence,
                "demo_key": self.demo_key,
                "stats": self.stats,
                "event_log": list(self.event_log),
                "workload_interval_seconds": self.demo_config["workload_interval_seconds"],
                "auto_fallback_interval_seconds": self.failover_config[
                    "auto_fallback_interval_seconds"
                ],
                "health_check_mode": (
                    "lag-aware"
                    if self.failover_config.get("use_lag_aware_health_check", False)
                    else "ping"
                ),
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
    DEMO_MANAGER.start_demo()
    return jsonify(DEMO_MANAGER.get_status())


@app.route("/api/demo/simulate-region1-outage", methods=["POST"])
def simulate_region1_outage():
    DEMO_MANAGER.simulate_region1_outage()
    return jsonify(DEMO_MANAGER.get_status())


@app.route("/api/demo/restore-region1", methods=["POST"])
def restore_region1():
    DEMO_MANAGER.restore_region1()
    return jsonify(DEMO_MANAGER.get_status())


@app.route("/api/demo/reset", methods=["POST"])
def reset_demo():
    DEMO_MANAGER.reset_demo()
    return jsonify(DEMO_MANAGER.get_status())


@app.route("/health")
def health():
    return jsonify({"status": "healthy", "timestamp": utc_now()})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
