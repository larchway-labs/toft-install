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

All of these run from the install directory, which is `~/.launchpad` unless you
gave `install.sh --dir`:

```bash
docker compose logs -f            # what it is doing
docker compose down               # stop, keeping everything
docker compose up -d              # start again
./uninstall.sh                    # the same as `down`
./uninstall.sh --purge            # remove everything: see below
```

**`--purge` is the clean uninstall.** It destroys the database and every built
release, removes the Launchpad image, and deletes the install directory and
everything in it — **including any dumps you left there**, so move those out
first. It asks you to type `DELETE` before any of that, because none of it is
recoverable: `ENCRYPTION_KEY` goes with `.env`, and a dump of the database is
unreadable without it anyway.

Two things it leaves, because they were never this install's:
`postgres:17-alpine` — a public image your machine may be using elsewhere — and
Docker itself.

**Upgrading is re-running the installer.** It reuses your `.env` untouched,
pulls the new image and restarts. Migrations run at boot and are one-way, so
take a dump first if the install holds anything you care about:

```bash
docker compose exec postgres pg_dump -U launchpad launchpad > backup.sql
```

A release that says which Python it needs is built against the interpreter the
image carries, so **an upgrade that moves that interpreter rebuilds each Python
app's dependencies on its next start** — automatically, one log line per app,
nothing to redeploy and no particular order. What it costs is time: the first
start of each Python app is as slow as installing its dependencies, and if they
were running they all pay it at once when the new container comes up. Node is
not covered and cannot be — a Node major changes the ABI every compiled
dependency was built against, so a version that moves Node's major is a redeploy
of every Node app rather than something an upgrade absorbs quietly.

## Deploying from the machine you write code on

The browser is one door and `lp` is the other. It is a single binary that
deploys a folder from your own machine, watches the build, and reads the logs
afterwards:

```bash
curl -fsSL https://raw.githubusercontent.com/gopanair/launchpad-cli/main/install.sh | sh
```

```bash
lp login http://localhost:8080     # or wherever this install answers
cd ~/code/my-app
lp link my-app
lp deploy
```

It uploads what is on your disk, respecting every `.gitignore` — no git remote,
no commit and no repository needed. Linux and Windows; there is no macOS build
yet and the installer says so rather than failing at a download.

`lp sdk vendor` writes this install's app SDK into your working directory, so
your editor and your local build can see it before anything is deployed. That
matters most for Go, where the import does not resolve at all until the platform
has built the app.

Nothing on this box needs it — the install works entirely through the browser —
and nothing about it is specific to this shape.

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
app secrets and git tokens. There is no second copy, and losing it is not
recoverable — the platform still starts, and tells you in one line how many
stored secrets it cannot read.

**Replacing that key is a rotation, not a restart with a new value.** Every
stored record names the key that wrote it, so both keys can be live at once:
put the new key in `ENCRYPTION_KEY`, move the old one to `ENCRYPTION_KEY_OLD`,
`docker compose up -d`, then

```bash
docker compose exec launchpad launchpad rotate-key
```

to re-encrypt what is left. Only when that reports nothing under the old key is
it safe to empty `ENCRYPTION_KEY_OLD` — until then the retired key is still the
only thing that opens those records. `.env.example` has the long version.

## What this install does and does not have

Apps run as OS processes inside the Launchpad container, each as its own account,
supervised by PM2. That is *shared mode*, and it is the whole of what this bundle
sets up.

Deliberately absent, rather than switched off: the object store for releases,
isolated (per-app container) execution, background jobs, durable app storage, and
telemetry export. Their routes return 404 and nothing about them appears in the
UI. Each needs infrastructure a single box does not have — those installs use the
Helm chart instead.

**Durable app storage is the one you can add here**, if you have a filesystem to
give it. Apps otherwise write into a release directory that the next deploy
replaces, which is why this install refuses a storage mapping outright rather
than half-honouring it.

Mount the filesystem on the host yourself — an NFS export, an Amazon S3 Files
file system, a disk, anything — then give the container a bind mount and a name
for it in `compose.override.yml`:

```yaml
services:
  launchpad:
    environment:
      # name=/path inside the container, comma-separated. Add `:ro` where the
      # host mount is read-only.
      SHARED_STORAGE_ROOTS: "reports=/mnt/reports"
    volumes:
      - /srv/reports:/mnt/reports
```

Launchpad makes a directory under that path for each storage resource and gates
it to a group only the apps you map can join. It never makes the mount — that
would need privileges this container deliberately does not hold — and it never
deletes what is under one. A read-only level is a second mount you make
read-only, not a permission Launchpad applies, so a resource under a `:ro` root
can only be mapped at read.

### Which language versions your apps can ask for

The image carries three of each, and the first is what an app with no pin gets:

| | Versions | An app pins it with |
|---|---|---|
| Python | **3.14**, 3.13, 3.12 | `[runtime] python = ">=3.12,<3.13"` in `launchpad.toml` |
| Node | **24**, 22, 20 | `[runtime] node = ">=20,<21"` |
| R | **4.5**, 4.4, 4.3 | `[runtime] r = ">=4.4"` |
| Go | 1.27, 1.26, 1.25 | nothing — see below |

A pin is **refused, never approximated**: a range nothing satisfies fails the
deploy naming both the range and what this install has, rather than quietly
building against something else. Comparators only — `>=`, `<`, `==`, comma for
AND — because `^` infers a range from a semver assumption Python does not share.
The version a build resolved is in its log, on the app's Runtime section, and in
the estate census under Admin.

**Node 20 is past its end of life** and is here for apps that ask for it by
name — a compiled addon is built against one major's ABI, and refusing to run
such an app is not what moves it off. It is never the default. To stop offering
it, set `LAUNCHPAD_NODE_PATH` in `compose.override.yml` to just the versions you
want.

**Go is the exception and takes no pin.** A `go.mod` directive is a *minimum*, so
the newest toolchain that satisfies it always wins, and Go will not downgrade for
a module's `toolchain` line either. If you need an older one, name it for the
whole install with `GOTOOLCHAIN=go1.25.14` in `.env` — it resolves from inside
the image with no outbound HTTPS, which is the point on a box that has none.

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

An install with **no** outbound HTTPS at all can still scan deployed apps'
dependencies for known vulnerabilities, which is otherwise the one admin setting
whose only input is a URL. Bring the corpus in by hand — the same per-ecosystem
archive the platform would have fetched from OSV — and everything downstream of
it behaves identically:

```bash
docker compose cp all.zip launchpad:/tmp/all.zip
docker compose exec launchpad launchpad advisory-import \
    --ecosystem pypi --as-of 2026-08-01 /tmp/all.zip
```

`--as-of` is the snapshot's own date and is required, because every finding
reports the corpus's age from it — passing today's date would make a stale
corpus read as fresh, and nothing here is going to refresh it for you.

## If something goes wrong

```bash
docker compose logs launchpad     # the platform
docker compose ps                 # what is running, and its health
cat install.log                   # what the installer did
```

`./install.sh --check` re-runs every machine check and changes nothing.
