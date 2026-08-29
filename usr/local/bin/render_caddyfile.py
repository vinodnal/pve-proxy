#!/usr/bin/env python3
"""Merge PVE live container data with services.yaml to render a Caddyfile."""

import argparse
import json
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader


def load_live_containers(path: str) -> dict[str, str]:
    """Return {lowercase_name: ip} from PVE cluster/resources JSON."""
    with open(path) as f:
        data = json.load(f)
    result = {}
    for item in data.get("data", []):
        if item.get("type") != "lxc" or item.get("status") != "running":
            continue
        name = item.get("name", "").lower()
        # PVE returns network info inconsistently; fall back to empty
        # The IP is not reliably in cluster/resources — we rely on services.yaml for it
        result[name] = name
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
    parser.add_argument("--out", required=True, help="Path to write rendered Caddyfile")
    args = parser.parse_args()

    live = load_live_containers(args.live)
    svc_map = load_services(args.services)

    # Build service list: only include services whose container is running
    services = []
    for name, conf in svc_map.items():
        if name in live:
            services.append({
                "name": name,
                "ip": conf["ip"],
                "port": conf["port"],
                "auth": conf.get("auth"),
            })
        else:
            print(f"warn: service '{name}' not found in running containers, skipping", file=sys.stderr)

    render(args.template, services, args.out, args.domain, args.email)
    print(f"Rendered {len(services)} services to {args.out}")


if __name__ == "__main__":
    main()
