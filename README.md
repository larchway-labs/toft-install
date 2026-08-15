# Launchpad

Internal app hosting — paste a GitHub repo URL, and it clones, builds, deploys
and serves it. One command, one Linux box.

```bash
curl -fsSL https://raw.githubusercontent.com/gopanair/launchpad-install/main/install.sh | sh
```

It checks the machine first and changes nothing until it has told you what it is
about to do. If Docker is missing it offers to install it. At the end it prints
the administrator's password, once.

**Requirements** — Linux on x86_64 or arm64, 4 GB of RAM (plus swap), 20 GB free.
Nothing else; Docker is the only dependency and the script can install it.

## Getting to it

Launchpad listens on loopback only, so reach it over an SSH tunnel:

```bash
ssh -L 8080:localhost:8080 -L 8081:localhost:8081 you@your-box
```

then open **http://localhost:8080**.

**Forward both ports, to the same numbers.** The platform is on 8080 and your
deployed apps are on 8081 — they are deliberately on a separate origin, so an
app's JavaScript cannot act as you against the platform. Forward only 8080 and
every app you deploy will 404. Forward to *different* local ports and reads will
work while every write fails with a 403; if you have to, put the origin you
actually browse in `EXTRA_ORIGINS` in `.env`.

Nothing is exposed to your network, so there is no firewall rule to get right.
Serving this on a real hostname means putting TLS in front of it — see
"Beyond one box" below.

## Day to day

All of these run from the install directory — `~/.launchpad`, or
`/opt/launchpad` when the install needed root anyway (Docker was missing, or the
Docker socket needs `sudo`). The installer prints which one it used, and
`./uninstall.sh` finds it from either place:

```bash
docker compose logs -f            # what it is doing
docker compose down               # stop, keeping everything
docker compose up -d              # start again
./uninstall.sh                    # the same as `down`
./uninstall.sh --purge            # destroy the database and all releases
```

**Upgrading is re-running the installer.** It reuses your `.env` untouched,
pulls the new image and restarts. Migrations run at boot and are one-way, so
take a dump first if the install holds anything you care about:

```bash
docker compose exec postgres pg_dump -U launchpad launchpad > backup.sql
```

## The administrator password

It is generated at install and shown once. It cannot be read back — it is stored
only as a hash, and the first sign-in has to replace it anyway.

If nobody knows it, this needs no old password, only a shell on the box:

```bash
docker compose exec launchpad launchpad local-admin enable
```

That prints a new one, unlocks the account, and switches local sign-in back on.
Once you have configured a real identity provider under **Admin → Sign-in**, you
can switch the password form off; that command is deliberately the only way to
switch it back on, so recovery always requires the machine.

## Back up `.env`

`ENCRYPTION_KEY` in that file is the only thing that can decrypt this install's
app secrets and git tokens. There is no second copy. Losing it does not produce
an error — the secrets simply stop coming back.

## What this install does and does not have

Apps run as OS processes inside the Launchpad container, each as its own account,
supervised by PM2. That is *shared mode*, and it is the whole of what this bundle
sets up.

Deliberately absent, rather than switched off: the object store for releases,
isolated (per-app container) execution, background jobs, durable app storage, and
telemetry export. Their routes return 404 and nothing about them appears in the
UI. Each needs infrastructure a single box does not have — those installs use the
Helm chart instead.

The bundled Postgres is a **fixture**: one container, one volume, no replication,
no failover, no backups. Point `DATABASE_URL` at a managed database for anything
that matters.

Apps can reach each other over loopback inside the container. Per-app accounts
stop them reading each other's files; nothing here stops them reaching each
other's ports. That is the accepted trade of shared mode.

## Beyond one box

Serving on a real hostname needs TLS in front — a browser silently discards this
install's session cookies over plain http on anything that is not `localhost`,
which presents as a sign-in that appears to work and does not. Put Caddy or nginx
in front, change `BASE_URL` and `APPS_BASE_URL` in `.env`, and add the proxy to
`TRUSTED_PROXY_CIDRS`.

An install behind a mandatory outbound proxy can run, but cannot yet build apps:
the platform's own calls honour `HTTP_PROXY`, and `git`, `npm` and `uv` are
deliberately not given it.

## If something goes wrong

```bash
docker compose logs launchpad     # the platform
docker compose ps                 # what is running, and its health
cat install.log                   # what the installer did
```

`./install.sh --check` re-runs every machine check and changes nothing.
