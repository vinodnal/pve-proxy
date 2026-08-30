#!/usr/bin/env python3
"""Merge PVE live container data with services.yaml to render a Caddyfile."""

import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader

# Service names become Caddy matcher labels and DNS host labels.
NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


def load_live_containers(path: str) -> set[str]:
    """Return the set of running LXC names from PVE cluster/resources JSON."""
    with open(path) as f:
        data = json.load(f)
    result = set()
    for item in data.get("data", []):
        if item.get("type") != "lxc" or item.get("status") != "running":
            continue
        name = item.get("name", "").lower()
        if name:
            result.add(name)
    return result


def load_services(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def render(template_path: str, services: list[dict], output_path: str,
           domain: str, email: str):
    template_dir = str(Path(template_path).parent)
    template_name = Path(template_path).name
    env = Environment(
        loader=FileSystemLoader(template_dir),
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    template = env.get_template(template_name)
    rendered = template.render(services=services, domain=domain, email=email)
    with open(output_path, "w") as f:
        f.write(rendered)


def main():
    parser = argparse.ArgumentParser(description="Render Caddyfile from PVE data + services.yaml")
    parser.add_argument("--live", required=True, help="Path to live-containers.json from PVE API")
    parser.add_argument("--services", required=True, help="Path to services.yaml")
    parser.add_argument("--template", required=True, help="Path to Caddyfile.template")
    parser.add_argument("--domain", required=True, help="Wildcard base domain, e.g. pve.example.com")
    parser.add_argument("--email", required=True, help="ACME contact email")
    parser.add_argument("--basic-auth-hash", default="",
                        help="bcrypt hash (caddy hash-password output) for services marked auth: basic")
    parser.add_argument("--out", required=True, help="Path to write rendered Caddyfile")
    args = parser.parse_args()

    live = load_live_containers(args.live)
    svc_map = load_services(args.services)
    if svc_map is None:
        svc_map = {}
    elif not isinstance(svc_map, dict):
        print("error: services.yaml must be a mapping of name -> config", file=sys.stderr)
        sys.exit(1)

    basic_auth_hash = (args.basic_auth_hash or "").strip()

    # Build service list: only include services whose container is running.
    # Every field that is later interpolated into the Caddyfile is validated
    # here so a bad services.yaml entry can never inject Caddyfile directives.
    services = []
    for name, conf in svc_map.items():
        if not isinstance(conf, dict):
            print(f"warn: service '{name}' config is not a mapping, skipping", file=sys.stderr)
            continue
        if name not in live:
            print(f"warn: service '{name}' not found in running containers, skipping", file=sys.stderr)
            continue
        if not NAME_RE.match(name):
            print(f"warn: service '{name}' has an invalid name (use lowercase [a-z0-9-]), skipping",
                  file=sys.stderr)
            continue
        ip = str(conf.get("ip", "")).strip()
        try:
            ipaddress.ip_address(ip)
        except ValueError:
            print(f"warn: service '{name}' has an invalid IP '{ip}', skipping", file=sys.stderr)
            continue
        try:
            port = int(conf.get("port", 0))
            if not 1 <= port <= 65535:
                raise ValueError
        except (TypeError, ValueError):
            print(f"warn: service '{name}' has an invalid port '{conf.get('port')}', skipping",
                  file=sys.stderr)
            continue

        svc = {"name": name, "ip": ip, "port": port, "auth": None, "basic_auth_hash": None}
        if conf.get("auth") == "basic":
            if basic_auth_hash:
                svc["auth"] = "basic"
                svc["basic_auth_hash"] = basic_auth_hash
            else:
                print(f"warn: service '{name}' requests basic auth but no BASIC_AUTH_HASH "
                      f"is configured; rendering it WITHOUT auth", file=sys.stderr)
        services.append(svc)

    render(args.template, services, args.out, args.domain, args.email)
    print(f"Rendered {len(services)} services to {args.out}")


if __name__ == "__main__":
    main()
