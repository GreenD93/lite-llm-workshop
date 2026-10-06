"""SSO key-vending broker - validates Keycloak JWTs, mints temporary LiteLLM Virtual Keys.

Flow: 1) verify signature/issuer/expiry against JWKS  2) check azp (issuing client)
      3) join the LiteLLM user by the email claim  4) /key/generate (with duration cap)
Never put team_id on the key - team keys bypass per-user budgets by default.
"""
import os
import secrets
import time
from datetime import datetime

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Request
from jwt import PyJWKClient

ISSUER = os.environ["KEYCLOAK_ISSUER"].rstrip("/")
# Local reproduction: the issuer is the browser-facing URL (localhost), which is
# unreachable from inside the container, so JWKS is fetched over the docker network.
JWKS_URL = os.environ.get("KEYCLOAK_JWKS_URL", ISSUER + "/protocol/openid-connect/certs")
CLIENT_ID = os.environ.get("KEYCLOAK_CLIENT_ID", "workshop-cli")
KEY_DURATION = os.environ.get("KEY_DURATION", "4h")
LITELLM_URL = os.environ.get("LITELLM_URL", "http://litellm:4000")
MASTER_KEY = os.environ["LITELLM_MASTER_KEY"]

jwks = PyJWKClient(JWKS_URL, cache_keys=True)
app = FastAPI()


@app.get("/auth/health")
def health():
    return {
        "status": "ok",
        "issuer": ISSUER,
        "client_id": CLIENT_ID,
        "key_duration": KEY_DURATION,
        "litellm_url": LITELLM_URL,
    }


@app.post("/auth/key")
async def issue_key(request: Request):
    authz = request.headers.get("authorization", "")
    if not authz.lower().startswith("bearer "):
        raise HTTPException(401, "Authorization: Bearer <Keycloak JWT> header required")
    token = authz.split(" ", 1)[1].strip()

    # 1) verify signature + issuer + expiry (Keycloak public keys fetched/cached via JWKS)
    try:
        signing_key = jwks.get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token, signing_key.key, algorithms=["RS256"],
            issuer=ISSUER, options={"verify_aud": False, "require": ["exp"]},
        )
    except Exception as exc:
        raise HTTPException(401, "JWT validation failed: " + str(exc))

    # 2) confirm the token was issued by the CLI client we approved
    if claims.get("azp") != CLIENT_ID:
        raise HTTPException(401, "client not allowed: azp=" + str(claims.get("azp")))

    email = claims.get("email")
    username = claims.get("preferred_username", "unknown")
    if not email:
        raise HTTPException(401, "token has no email claim")

    async with httpx.AsyncClient(timeout=15) as client:
        # 3) join the LiteLLM user by email (user_email filter is partial-match, so re-verify exact)
        try:
            r = await client.get(
                LITELLM_URL + "/user/list", params={"user_email": email},
                headers={"Authorization": "Bearer " + MASTER_KEY},
            )
            r.raise_for_status()
        except Exception as exc:
            raise HTTPException(502, "LiteLLM user lookup failed: " + str(exc))
        users = [
            u for u in r.json().get("users", [])
            if (u.get("user_email") or "").lower() == email.lower()
        ]
        if not users:
            raise HTTPException(
                404, "no LiteLLM user with email " + email + " - create the user in Module 2-3 first")
        user_id = users[0]["user_id"]

        # 4) mint the temporary Virtual Key (no team_id - the user budget governs the key)
        stamp = time.strftime("%m%d-%H%M%S", time.gmtime())
        payload = {
            "user_id": user_id,
            "duration": KEY_DURATION,
            "key_alias": "sso-" + username + "-" + stamp + "-" + secrets.token_hex(2),
            "metadata": {"issued_via": "sso-broker", "kc_username": username},
        }
        try:
            r = await client.post(
                LITELLM_URL + "/key/generate", json=payload,
                headers={"Authorization": "Bearer " + MASTER_KEY},
            )
            r.raise_for_status()
        except Exception as exc:
            raise HTTPException(502, "key issuance failed: " + str(exc))
        body = r.json()

    expires_at = body.get("expires")
    expires_epoch = None
    if expires_at:
        try:
            expires_epoch = int(datetime.fromisoformat(expires_at).timestamp())
        except (TypeError, ValueError):
            pass
    if expires_epoch is None:
        raise HTTPException(502, "key issuance response missing a valid expiry")
    return {
        "key": body["key"],
        "expires_at": expires_at,
        "expires_epoch": expires_epoch,
        "user_id": user_id,
        "user_email": email,
        "duration": KEY_DURATION,
    }
