# Optional infrastructure

**tailscale: enabled.** cloudflared: waits on a
domain.

These need credentials only you can create. Each folder is complete except for its Secret, which
is a SOPS-encrypted template with placeholder values. To enable one:

1. Fill in the Secret: `sops infrastructure/optional/<name>/<secret>.sops.yaml` opens it decrypted
   in your editor and re-encrypts on save. Never commit a decrypted copy.
2. Add `- optional/<name>` to `infrastructure/kustomization.yaml`.
3. Commit and push; Flux applies it within a minute (`flux reconcile kustomization infrastructure --with-source`).

## tailscale (Tailscale Kubernetes operator)

Decided 2026-10-27: private access goes through the operator.

Tailscale's current requirements (docs: "Install the Tailscale Kubernetes Operator" and
"Configure Kubernetes RBAC for the API server proxy", checked 2026-10-30):

1. Admin console → **Access controls**, add to the policy file:
   ```json
   "tagOwners": {
     "tag:k8s-operator": [],
     "tag:k8s": ["tag:k8s-operator"]
   },
   "grants": [
     {
       "src": ["autogroup:admin"],
       "dst": ["tag:k8s-operator"],
       "app": {"tailscale.com/cap/kubernetes": [{"impersonate": {"groups": ["system:masters"]}}]}
     }
   ]
   ```
   The grant lets tailnet admins (you) use `kubectl` through the operator. If the policy file has
   no "allow all" rule, your devices also need access to `tag:k8s` and `tag:k8s-operator` on
   TCP 443. If `tagOwners` or `grants` already exist, merge these entries into them.
2. Settings → **Trust credentials** → OAuth client, with **write** scope for
   *General → Services*, *Devices → Core* and *Keys → Auth Keys*, each with tag `tag:k8s-operator`.
3. Put the client ID and secret in `tailscale/operator-oauth.sops.yaml` (keys `client_id`,
   `client_secret`), then enable it: add `- optional/tailscale` to `infrastructure/kustomization.yaml`
   and `- tailscale` to `apps/kustomization.yaml` (the ProxyClass needs the chart's CRDs first).
4. What you get: the operator as `bc250-operator` (also the `kubectl` proxy:
   `tailscale configure kubeconfig bc250-operator`), and a private HTTPS name for the hub
   (`homelab`), from its
   `tailscale-ingress.yaml`.

## cloudflared (Cloudflare Tunnel for the websites)

Waiting on a domain. Once you have one: Cloudflare dashboard → Zero Trust → Networks → Tunnels →
Create (cloudflared), copy the token into `cloudflared/tunnel-token.sops.yaml` (key `token`),
and in the tunnel's Public Hostnames route `<your domain>` to `http://traefik.kube-system.svc:80`.
