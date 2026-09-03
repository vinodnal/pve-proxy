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


def load_ips(path: str) -> dict:
    """Return service name -> IP map produced by the sync (PVE /interfaces).

    Empty/invalid files yield an empty map so discovery is always optional.
    """
    if not path:
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(k): str(v).strip() for k, v in data.items() if str(v).strip()}


def render(template_path: str, services: list[dict], tcp_services: list[dict],
           output_path: str, domain: str, email: str,
           allowed_cidrs: str = "100.64.0.0/10", acme_ca: str = ""):
    template_dir = str(Path(template_path).parent)
    template_name = Path(template_path).name
    env = Environment(
        loader=FileSystemLoader(template_dir),
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    template = env.get_template(template_name)
    rendered = template.render(services=services, tcp_services=tcp_services,
                               domain=domain, email=email,
                               allowed_cidrs=allowed_cidrs, acme_ca=acme_ca)
    with open(output_path, "w") as f:
        f.write(rendered)


def main():
    parser = argparse.ArgumentParser(description="Render Caddyfile from PVE data + services.yaml")
    parser.add_argument("--live", required=True, help="Path to live-containers.json from PVE API")
    parser.add_argument("--live-ips", default="",
                        help="Optional name->IP map (auto-discovered from PVE /interfaces). "
                             "Used for services whose services.yaml entry omits `ip:`.")
    parser.add_argument("--services", required=True, help="Path to services.yaml")
    parser.add_argument("--template", required=True, help="Path to Caddyfile.template")
    parser.add_argument("--domain", required=True, help="Wildcard base domain, e.g. pve.example.com")
    parser.add_argument("--email", required=True, help="ACME contact email")
    parser.add_argument("--basic-auth-hash", default="",
                        help="bcrypt hash (caddy hash-password output) for services marked auth: basic")
    parser.add_argument("--extra-subnets", default="",
                        help="Comma/space-separated extra client CIDRs to trust in addition to "
                             "Tailscale CGNAT (100.64.0.0/10)")
    parser.add_argument("--acme-ca", default="",
                        help="Optional ACME directory URL (default: Let's Encrypt production)")
    parser.add_argument("--out", required=True, help="Path to write rendered Caddyfile")
    args = parser.parse_args()

    # Guardrails: refuse to render garbage instead of shipping a broken
    # Caddyfile downstream (validate catches a subset; we catch the rest).
    domain = (args.domain or "").strip()
    if not re.fullmatch(
        r"(?i)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*",
        domain,
    ):
        print(f"error: --domain '{args.domain}' is not a valid DNS name", file=sys.stderr)
        sys.exit(2)
    email = (args.email or "").strip()
    if "@" not in email or "." not in email.split("@", 1)[1]:
        print(f"error: --email '{args.email}' is not a valid email address", file=sys.stderr)
        sys.exit(2)

    live = load_live_containers(args.live)
    ips = load_ips(args.live_ips)
    svc_map = load_services(args.services)
    if svc_map is None:
        svc_map = {}
    elif not isinstance(svc_map, dict):
        print("error: services.yaml must be a mapping of name -> config", file=sys.stderr)
        sys.exit(1)

    basic_auth_hash = (args.basic_auth_hash or "").strip()

    # Trusted-client CIDR set: Tailscale CGNAT is always trusted; the operator
    # may add extra subnets via config.sh -> Advanced -> trusted subnets.
    trusted = ["100.64.0.0/10"]
    for part in re.split(r"[,\s]+", args.extra_subnets.strip()):
        if not part:
            continue
        try:
            ipaddress.ip_network(part)
        except ValueError:
            print(f"error: --extra-subnets has an invalid CIDR '{part}'", file=sys.stderr)
            sys.exit(2)
        trusted.append(part)
    allowed_cidrs = " ".join(trusted)
    acme_ca = (args.acme_ca or "").strip()

    # Build service list: only include services whose container is running.
    # Every field that is later interpolated into the Caddyfile is validated
    # here so a bad services.yaml entry can never inject Caddyfile directives.
    # Two kinds of service:
    #   - HTTP (default):   rendered as a virtual host inside the `*.<domain>`
    #                       site block (name -> https://name.<domain> on :443).
    #   - TCP (mode: tcp):  rendered as a caddy-l4 layer4 server on its own
    #                       public port. Raw TCP carries no hostname, so the
    #                       `name` is only a label and routing is by port.
    services = []      # HTTP services (host-based routing on *.<domain>)
    tcp_services = []  # raw TCP forwards (port-based routing via caddy-l4)
    reserved_l4_ports = {80, 443, 2019}  # Caddy HTTP (:80/:443) + admin API
    tcp_ports = set()  # reject duplicate listen_port values across TCP services
    for name, conf in svc_map.items():
        if not isinstance(conf, dict):
            print(f"warn: service '{name}' config is not a mapping, skipping", file=sys.stderr)
            continue
        if not NAME_RE.match(name):
            print(f"warn: service '{name}' has an invalid name (use lowercase [a-z0-9-]), skipping",
                  file=sys.stderr)
            continue

        mode = str(conf.get("mode", "") or "").strip().lower()

        # Resolve the backend container. HTTP routes by subdomain, so the key is
        # the container name and must be running. TCP routes by port, so the key
        # is just a label — point it at a running container with `container:`
        # (or keep the key equal to a container name to omit the field). The
        # container also selects which container PVE is asked about for IP
        # auto-discovery.
        if mode == "tcp":
            container = str(conf.get("container", "") or "").strip() or name
        else:
            container = name
        if container not in live:
            suffix = "" if container == name else f" (container '{container}')"
            print(f"warn: service '{name}'{suffix} not found in running containers, skipping",
                  file=sys.stderr)
            continue

        # IP: prefer an explicit `ip:` in services.yaml, else the value the
        # sync auto-discovered from the PVE /interfaces endpoint (works even for
        # DHCP containers). A service with neither is skipped, never guessed.
        ip = str(conf.get("ip", "")).strip()
        if not ip:
            ip = ips.get(container, "")
        if not ip:
            print(f"warn: service '{name}' has no ip and none was discovered from PVE; "
                  f"set ip: manually in services.yaml or check the container is up", file=sys.stderr)
            continue
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

        # ── Raw TCP forward (caddy-l4) ──────────────────────────────
        if mode == "tcp":
            # listen_port is the PUBLIC port on the proxy. It must be explicit
            # (no default) so it can never silently collide with the proxy's own
            # sshd (:22), Caddy's HTTP app (:80/:443) or the admin API (:2019).
            try:
                listen_port = int(conf.get("listen_port", 0))
                if not 1 <= listen_port <= 65535:
                    raise ValueError
            except (TypeError, ValueError):
                print(f"warn: TCP service '{name}' needs a valid listen_port "
                      f"(public proxy port, 1-65535); skipping", file=sys.stderr)
                continue
            if listen_port in reserved_l4_ports:
                print(f"warn: TCP service '{name}' listen_port {listen_port} is reserved "
                      f"(Caddy HTTP/admin already bind it); skipping", file=sys.stderr)
                continue
            if listen_port in tcp_ports:
                print(f"warn: TCP service '{name}' listen_port {listen_port} is already "
                      f"in use by another TCP service; skipping", file=sys.stderr)
                continue
            if conf.get("auth") == "basic":
                print(f"warn: TCP service '{name}' has auth: basic, which applies only "
                      f"to HTTP services; ignoring", file=sys.stderr)
            tcp_ports.add(listen_port)
            tcp_services.append({"name": name, "ip": ip, "port": port,
                                 "listen_port": listen_port})
            continue

        if mode not in ("", "http"):
            print(f"warn: service '{name}' has an unsupported mode '{mode}' "
                  f"(use \"tcp\" or omit/\"http\" for HTTP); skipping", file=sys.stderr)
            continue

        # ── HTTP service (virtual host on *.<domain>) ───────────────
        svc = {"name": name, "ip": ip, "port": port, "auth": None, "basic_auth_hash": None}
        if conf.get("auth") == "basic":
            if basic_auth_hash:
                svc["auth"] = "basic"
                svc["basic_auth_hash"] = basic_auth_hash
            else:
                print(f"warn: service '{name}' requests basic auth but no BASIC_AUTH_HASH "
                      f"is configured; rendering it WITHOUT auth", file=sys.stderr)
        services.append(svc)

    if not services and not tcp_services:
        print("warn: no services rendered (no matching running containers); "
              "Caddyfile will only serve the base host", file=sys.stderr)
    render(args.template, services, tcp_services, args.out,
           domain, email, allowed_cidrs, acme_ca)
    print(f"Rendered {len(services)} HTTP + {len(tcp_services)} TCP services to {args.out}")


if __name__ == "__main__":
    main()
