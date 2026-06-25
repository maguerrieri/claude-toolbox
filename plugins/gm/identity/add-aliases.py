#!/usr/bin/env python3
"""Ensure a per-persona email alias on the gm identity seat (Google Workspace).

Reads identity.json (identity_domain + seat) and the plugin's personas/, and ensures
an alias <persona-slug>@<identity_domain> exists on the seat via the Admin SDK
Directory API.

Follow-on infra — the plugin works without it; aliases only enable the per-persona
Gravatar avatars on campaign commit identities. Requires a Workspace admin service
account with the directory user.alias scope, and google-api-python-client. Run with:

  uv run --with google-api-python-client --with google-auth \\
    plugins/gm/identity/add-aliases.py --creds <service-account.json> [--dry-run]
"""
import argparse
import glob
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN_ROOT = os.path.dirname(HERE)
SCOPE = "https://www.googleapis.com/auth/admin.directory.user.alias"


def persona_slugs(plugin_root):
    slugs = []
    for d in sorted(glob.glob(os.path.join(plugin_root, "personas", "*"))):
        pm = os.path.join(d, "persona.md")
        if not os.path.isfile(pm):
            continue
        with open(pm, encoding="utf-8") as f:
            m = re.search(r"email:\s*([\w.+-]+)@\$\{identity_domain\}", f.read())
        slugs.append(m.group(1) if m else os.path.basename(d))
    return slugs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--creds", help="service-account JSON with the directory user.alias scope")
    ap.add_argument("--config", default=os.path.join(HERE, "identity.json"))
    ap.add_argument("--plugin-root", default=PLUGIN_ROOT)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    with open(a.config, encoding="utf-8") as f:
        cfg = json.load(f)
    domain, seat = cfg["identity_domain"], cfg["seat"]
    aliases = [f"{s}@{domain}" for s in persona_slugs(a.plugin_root)]
    print(f"seat: {seat}")
    print(f"aliases to ensure: {aliases}")
    if a.dry_run or not a.creds:
        print("(dry run — pass --creds to apply)")
        return

    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    creds = service_account.Credentials.from_service_account_file(a.creds, scopes=[SCOPE])
    svc = build("admin", "directory_v1", credentials=creds)
    existing = {al["alias"] for al in
                svc.users().aliases().list(userKey=seat).execute().get("aliases", [])}
    for alias in aliases:
        if alias in existing:
            print(f"exists: {alias}")
            continue
        svc.users().aliases().insert(userKey=seat, body={"alias": alias}).execute()
        print(f"added:  {alias}")


if __name__ == "__main__":
    main()
