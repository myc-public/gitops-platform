#!/usr/bin/env python3
"""Controle des regles d'autorisation des realms Keycloak (ADR 02/10, DI2) : Groupe -> Role metier -> Permission.

Regles verifiees sur les fichiers de realm (apps/keycloak/**/*.yaml) :
  R1 un utilisateur ne porte jamais de role directement (sauf comptes de service service-account-*) ;
  R2 un utilisateur (hors comptes de service) appartient a au moins un groupe ;
  R3 un groupe ne pointe que vers des roles metier (roles de realm), jamais vers une permission (role de client) ;
  R4 un groupe reference uniquement des roles metier definis dans le realm ;
  R5 myc-internal ne contient aucune permission "proprietaire" (:own) ; myc-customers ne contient que des permissions :own ;
  R6 un realm qui definit clientScopeMappings y redeclare la projection par defaut account -> account-console
     (keycloak-config-cli gere ce bloc en entier : sans elle, la console "mon compte" recoit un 401).

Usage : python tools/check-realm-rbac.py [repertoire]   (defaut : apps/keycloak)
Necessite PyYAML. Sans Python local :
  docker run --rm -v "${PWD}:/w" -w /w python:3.12-alpine sh -c "pip install -q pyyaml && python tools/check-realm-rbac.py"
"""
import sys
from pathlib import Path

import yaml

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "apps/keycloak")
SERVICE_ACCOUNT_PREFIX = "service-account-"
API_CLIENT = "donation-api"

errors = []
realms = {}  # nom -> {"realm_roles": set, "permissions": set, "groups": [...], "users": [...]}
ACCOUNT_CONSOLE_ROLES = {"manage-account", "view-groups"}


def walk_groups(groups, parent=""):
    for g in groups or []:
        path = f"{parent}/{g['name']}"
        yield path, g
        yield from walk_groups(g.get("subGroups"), path)


for file in sorted(ROOT.rglob("*.yaml")):
    doc = yaml.safe_load(file.read_text(encoding="utf-8"))
    if not isinstance(doc, dict) or "realm" not in doc:
        continue
    r = realms.setdefault(doc["realm"], {"realm_roles": set(), "permissions": set(), "groups": [], "users": []})
    roles = doc.get("roles") or {}
    r["realm_roles"] |= {role["name"] for role in roles.get("realm") or []}
    r["permissions"] |= {role["name"] for role in (roles.get("client") or {}).get(API_CLIENT) or []}
    r["groups"] += [(file, path, g) for path, g in walk_groups(doc.get("groups"))]
    r["users"] += [(file, u) for u in doc.get("users") or []]
    mappings = doc.get("clientScopeMappings")
    if mappings is not None:
        account = {(m.get("client"), role) for m in mappings.get("account") or [] for role in m.get("roles") or []}
        missing = {role for role in ACCOUNT_CONSOLE_ROLES if ("account-console", role) not in account}
        if missing:
            errors.append(f"R6 {file}: {doc['realm']} clientScopeMappings sans la projection account -> account-console {sorted(missing)}")

for name, r in realms.items():
    for file, user in r["users"]:
        username = user.get("username", "?")
        is_service = username.startswith(SERVICE_ACCOUNT_PREFIX)
        if not is_service and (user.get("realmRoles") or user.get("clientRoles")):
            errors.append(f"R1 {file}: {name}/{username} porte un role directement (attribuer un groupe)")
        if not is_service and not user.get("groups"):
            errors.append(f"R2 {file}: {name}/{username} n'appartient a aucun groupe")
    for file, path, group in r["groups"]:
        if group.get("clientRoles"):
            errors.append(f"R3 {file}: {name}{path} pointe vers une permission (clientRoles) au lieu d'un role metier")
        for role in group.get("realmRoles") or []:
            if role not in r["realm_roles"]:
                errors.append(f"R4 {file}: {name}{path} reference un role metier inconnu : {role}")
    own = {p for p in r["permissions"] if p.endswith(":own")}
    if name.endswith("-internal") and own:
        errors.append(f"R5 {name} : permissions proprietaire interdites dans le realm interne : {sorted(own)}")
    if name.endswith("-customers") and r["permissions"] - own:
        errors.append(f"R5 {name} : permissions globales interdites dans le realm externe : {sorted(r['permissions'] - own)}")

if not realms:
    errors.append(f"aucun realm trouve sous {ROOT}")

for e in errors:
    print("ERREUR", e)
print(f"{len(realms)} realm(s) controle(s) : {', '.join(sorted(realms))} -> {'KO' if errors else 'OK'}")
sys.exit(1 if errors else 0)
