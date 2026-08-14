#!/bin/sh
# Launchpad — the one-box install.
#
#   curl -fsSL https://raw.githubusercontent.com/gopanair/launchpad-install/main/install.sh | sh
#
# Takes a Linux machine from nothing to a running Launchpad in shared mode:
# Docker if it is missing, Postgres alongside, secrets generated, and the
# built-in administrator's first password printed once at the end.
#
# THE WHOLE BODY IS INSIDE main(), CALLED ON THE LAST LINE. Piping into a shell
# executes what has arrived so far, so a script that is a bare sequence of
# commands runs half of itself when the connection drops mid-download. This
# arrangement means a truncated download does nothing at all.
#
# Nothing before the "Setting up" phase modifies this machine. `--check` stops
# after the checks and reports what would happen.
#
# POSIX sh on purpose: this is the first thing that runs on a box nobody has
# prepared, and it cannot depend on bash being the shell it was piped into.

set -eu

# --- What this install is ----------------------------------------------------

VERSION_DEFAULT=0.1.0
IMAGE_DEFAULT=gopanair/launchpad
RAW_BASE_DEFAULT=https://raw.githubusercontent.com/gopanair/launchpad-install
BUNDLE_FILES="compose.yml compose.metadata.yml .env.example uninstall.sh"

# Minimums. Below the hard floors the install cannot work; below the soft ones
# it comes up and then fails at the first real build, which is a much worse way
# to find out.
DISK_SOFT_GB=20
DISK_HARD_GB=10
MEM_SOFT_MB=4000

# --- Options -----------------------------------------------------------------

ASSUME_YES=0
CHECK_ONLY=0
VERBOSE=0
FORCE=0
SKIP_DOCKER_INSTALL=0
VERSION=$VERSION_DEFAULT
IMAGE=$IMAGE_DEFAULT
RAW_BASE=$RAW_BASE_DEFAULT
HOME_DIR=

usage() {
    cat <<'EOF'
Launchpad installer

  install.sh [options]

  --yes                 do not prompt; assume yes (required when there is no terminal)
  --check               run the checks, change nothing, and report
  --dir PATH            install into PATH (default /opt/launchpad, or ~/.launchpad)
  --version X.Y.Z       the Launchpad version to install
  --image NAME          the image repository (default gopanair/launchpad)
  --no-docker-install   fail rather than installing Docker
  --verbose             show the output of each command instead of a spinner
  --force               proceed past checks that would otherwise stop the install
  --help                this

Upgrading is re-running this script. It reuses the existing .env untouched.
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
        --yes | -y) ASSUME_YES=1 ;;
        --check) CHECK_ONLY=1 ;;
        --verbose) VERBOSE=1 ;;
        --force) FORCE=1 ;;
        --no-docker-install) SKIP_DOCKER_INSTALL=1 ;;
        --dir)
            shift
            [ $# -gt 0 ] || die "--dir needs a path"
            HOME_DIR=$1
            ;;
        --version)
            shift
            [ $# -gt 0 ] || die "--version needs a value"
            VERSION=$1
            ;;
        --image)
            shift
            [ $# -gt 0 ] || die "--image needs a value"
            IMAGE=$1
            ;;
        --raw-base)
            shift
            [ $# -gt 0 ] || die "--raw-base needs a value"
            RAW_BASE=$1
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *) die "unknown option $1 — run with --help" ;;
        esac
        shift
    done
}

# --- Output ------------------------------------------------------------------
#
# Colour and box-drawing are both conditional. A pipe into a file, NO_COLOR, a
# dumb terminal or a non-UTF-8 locale each fall back rather than emitting escape
# codes and mojibake into somebody's provisioning log.

ui_init() {
    UI_TTY=0
    [ -t 1 ] && UI_TTY=1
    C_RESET='' C_DIM='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
    if [ "$UI_TTY" = 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != dumb ]; then
        C_RESET=$(printf '\033[0m') C_DIM=$(printf '\033[2m') C_BOLD=$(printf '\033[1m')
        C_RED=$(printf '\033[31m') C_GREEN=$(printf '\033[32m')
        C_YELLOW=$(printf '\033[33m') C_BLUE=$(printf '\033[34m')
    fi
    UI_UNICODE=0
    case "$(locale charmap 2>/dev/null || echo)" in
    UTF-8 | utf8 | UTF8) [ "$UI_TTY" = 1 ] && UI_UNICODE=1 ;;
    esac
    if [ "$UI_UNICODE" = 1 ]; then
        M_OK='✔' M_BAD='✖' M_WARN='!' M_ARROW='·'
    else
        M_OK='[ok]' M_BAD='[!!]' M_WARN='[w]' M_ARROW='-'
    fi
}

log_line() { [ -n "${LOGFILE:-}" ] && printf '%s\n' "$*" >>"$LOGFILE" 2>/dev/null || true; }

section() {
    printf '\n  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
    log_line "== $1"
}
ok() {
    printf '    %s%s%s %s\n' "$C_GREEN" "$M_OK" "$C_RESET" "$1"
    log_line "ok: $1"
}
note() {
    printf '    %s%s %s%s\n' "$C_DIM" "$M_ARROW" "$1" "$C_RESET"
    log_line "note: $1"
}
warn() {
    printf '    %s%s%s %s\n' "$C_YELLOW" "$M_WARN" "$C_RESET" "$1"
    log_line "warn: $1"
}
bad() {
    printf '    %s%s%s %s\n' "$C_RED" "$M_BAD" "$C_RESET" "$1"
    log_line "fail: $1"
}
die() {
    printf '\n  %sCannot continue.%s %s\n\n' "$C_RED" "$C_RESET" "$1" >&2
    log_line "die: $1"
    [ -n "${LOGFILE:-}" ] && printf '  The full log is %s\n\n' "$LOGFILE" >&2
    exit 1
}

# Asks, unless told not to. Reads /dev/tty rather than stdin: under
# `curl … | sh` stdin IS this script, and a read would consume the lines that
# have not run yet — a failure with no plausible explanation.
# Openable, not merely present. /dev/tty exists in plenty of contexts where
# opening it fails — a cron job, a container with no controlling terminal — and
# testing with -e turns a clean refusal into a raw shell error.
tty_ok() { { : </dev/tty; } 2>/dev/null; }

confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    tty_ok || die "no terminal to ask on, and --yes was not given. Re-run with --yes."
    printf '    %s [y/N] ' "$1" >/dev/tty
    read -r reply </dev/tty || reply=n
    case $reply in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

now() { date +%s; }
elapsed() { printf '%ss' "$(($(now) - $1))"; }

# Runs a command, showing a spinner while it works. Output goes to the log, and
# is printed in full only when the command fails or --verbose asked for it —
# the image pull is several minutes of docker's own progress bars, and they are
# not what somebody watching this wants to read.
spin() {
    _msg=$1
    shift
    log_line "+ $*"
    if [ "$VERBOSE" = 1 ] || [ "$UI_TTY" != 1 ]; then
        printf '    %s %s\n' "$M_ARROW" "$_msg"
        if [ "$VERBOSE" = 1 ]; then "$@" 2>&1 | tee -a "$LOGFILE"; else "$@" >>"$LOGFILE" 2>&1; fi
        return $?
    fi
    _start=$(now)
    "$@" >>"$LOGFILE" 2>&1 &
    _pid=$!
    _i=0
    while kill -0 "$_pid" 2>/dev/null; do
        _f=$(spin_frame "$_i")
        printf '\r    %s%s%s %s %s%s%s ' "$C_BLUE" "$_f" "$C_RESET" "$_msg" \
            "$C_DIM" "$(elapsed "$_start")" "$C_RESET"
        _i=$((_i + 1))
        sleep 0.1 2>/dev/null || sleep 1
    done
    # Captured directly off `wait`, and before anything else runs. Reading $?
    # after an `if wait …; then … fi` gives the status of the *if*, which is 0
    # when no branch was taken — so a failed command reported success and the
    # install carried on past it.
    _rc=0
    wait "$_pid" || _rc=$?
    printf '\r\033[K'
    if [ "$_rc" -eq 0 ]; then
        printf '    %s%s%s %s %s%s%s\n' "$C_GREEN" "$M_OK" "$C_RESET" "$_msg" \
            "$C_DIM" "$(elapsed "$_start")" "$C_RESET"
        return 0
    fi
    bad "$_msg"
    return "$_rc"
}

spin_frame() {
    if [ "$UI_UNICODE" = 1 ]; then
        case $(($1 % 10)) in
        0) printf '⠋' ;; 1) printf '⠙' ;; 2) printf '⠹' ;; 3) printf '⠸' ;; 4) printf '⠼' ;;
        5) printf '⠴' ;; 6) printf '⠦' ;; 7) printf '⠧' ;; 8) printf '⠇' ;; *) printf '⠏' ;;
        esac
    else
        case $(($1 % 4)) in
        0) printf '|' ;; 1) printf '/' ;; 2) printf -- '-' ;; *) printf '\\' ;;
        esac
    fi
}

# --- Small helpers -----------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# Privilege, worked out once. An install run as root needs no sudo; one run as a
# user needs sudo for the package manager and — until the docker group takes
# effect at next login — for docker itself.
PRIV=
priv_init() {
    if [ "$(id -u)" = 0 ]; then
        PRIV=
        return 0
    fi
    if have sudo; then
        PRIV=sudo
        return 0
    fi
    PRIV=none
}
run_priv() {
    case $PRIV in
    none) die "this needs root, and there is no sudo on this machine: $*" ;;
    '') "$@" ;;
    *) sudo "$@" ;;
    esac
}

# docker, run with privilege only when it is actually needed. Group membership
# granted during this run does not apply to this shell, so a fresh install keeps
# using sudo until the operator logs out and back in.
DOCKER_NEEDS_PRIV=0
dkr() {
    if [ "$DOCKER_NEEDS_PRIV" = 1 ]; then run_priv docker "$@"; else docker "$@"; fi
}
compose() { dkr compose --project-directory "$HOME_DIR" "$@"; }

fetch() {
    # $1 url, $2 destination
    if have curl; then
        curl -fsSL --retry 3 --retry-delay 2 "$1" -o "$2"
    elif have wget; then
        wget -qO "$2" "$1"
    else
        die "neither curl nor wget is installed, so nothing can be downloaded"
    fi
}

# 24 characters from an unambiguous alphabet — no l/1/I or 0/O, because this
# gets read off a terminal and typed into a login form. The same alphabet and
# length the platform's own generator uses.
gen_password() {
    LC_ALL=C tr -dc 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789' \
        </dev/urandom 2>/dev/null | head -c 24
    echo
}
gen_hex() {
    if have openssl; then
        openssl rand -hex "$1"
    else
        LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c "$(($1 * 2))"
        echo
    fi
}

# --- Phase 1: the checks -----------------------------------------------------

OS_ID= OS_NAME= OS_LIKE= ARCH= INIT=none IS_CLOUD=0 IS_WSL=0

# One field out of /etc/os-release, read in a subshell so nothing it defines
# escapes into this script's variables.
os_release() (
    [ -r /etc/os-release ] || {
        printf '%s' "$2"
        exit 0
    }
    # shellcheck disable=SC1091
    . /etc/os-release
    eval "_v=\${$1:-}"
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
)

preflight() {
    section 'Checking this machine'

    [ "$(uname -s)" = Linux ] || die "this bundle is Linux only (found $(uname -s))."

    # Each read in its own subshell. /etc/os-release is a shell fragment that
    # defines NAME, VERSION, ID — sourcing it into this shell silently
    # overwrites $VERSION with the *distribution's* version, and the installer
    # goes looking for an image tagged "2023".
    OS_ID=$(os_release ID unknown)
    OS_NAME=$(os_release PRETTY_NAME "$OS_ID")
    OS_LIKE=$(os_release ID_LIKE '')

    ARCH=$(uname -m)
    case $ARCH in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "no Launchpad image is published for $ARCH. The image is built for x86_64 and arm64." ;;
    esac

    if [ -d /run/systemd/system ]; then INIT=systemd; elif have rc-update; then INIT=openrc; fi
    ok "$OS_NAME $M_ARROW $ARCH $M_ARROW $INIT"

    if grep -qi microsoft /proc/version 2>/dev/null; then
        IS_WSL=1
        # Recent WSL runs systemd when /etc/wsl.conf asks it to, and then the
        # daemon is managed from in here like anywhere else. Assuming it never
        # is throws that away and leaves the daemon un-enabled on a machine
        # that could have started it.
        if [ "$INIT" = systemd ]; then
            note 'WSL detected, with systemd running — the daemon is managed from here'
        else
            note 'WSL detected — the Docker daemon is started by Docker Desktop, not by this script'
            INIT=none
        fi
    fi

    priv_init
    if [ "$PRIV" = none ] && [ "$(id -u)" != 0 ]; then
        warn 'not root, and no sudo — Docker cannot be installed and privileged steps will fail'
    fi
    # A password prompt in an unattended run hangs until something kills it.
    if [ "$PRIV" = sudo ] && [ "$ASSUME_YES" = 1 ] && ! sudo -n true 2>/dev/null; then
        die "sudo wants a password and --yes was given. Run it as root, or without --yes."
    fi

    check_docker
    check_resources
    check_ports
    check_egress
    check_metadata
    check_existing
}

check_docker() {
    if have docker && dkr info >/dev/null 2>&1; then
        DOCKER_PRESENT=1
    elif have docker; then
        # Installed but not answering: either stopped, or this user has no
        # access to the socket. Distinguishing them matters — one needs a
        # daemon start, the other needs sudo.
        if [ "$PRIV" != none ] && run_priv docker info >/dev/null 2>&1; then
            DOCKER_NEEDS_PRIV=1
            DOCKER_PRESENT=1
            note 'docker needs sudo for this user — using it, and see the end for the fix'
        else
            DOCKER_PRESENT=0
            warn 'docker is installed but its daemon is not answering'
        fi
    else
        DOCKER_PRESENT=0
    fi

    if [ "$DOCKER_PRESENT" = 1 ]; then
        _dv=$(dkr version --format '{{.Server.Version}}' 2>/dev/null || echo '?')
        if dkr compose version >/dev/null 2>&1; then
            _cv=$(dkr compose version --short 2>/dev/null || echo '?')
            ok "Docker $_dv, Compose v$_cv"
            COMPOSE_OK=1
        else
            COMPOSE_OK=0
            if have docker-compose; then
                warn 'only Compose v1 (docker-compose) is present; v2 is required'
            else
                warn 'the Docker Compose v2 plugin is missing'
            fi
        fi
    else
        COMPOSE_OK=0
        # "not installed" and "installed but dead" need different fixes, and the
        # warn above has already said which this is. Repeating it as "Docker is
        # not installed" contradicts it in the same block of output.
        if have docker; then
            note 'the docker CLI is here, but nothing is answering on the socket'
        else
            note 'Docker is not installed'
        fi
    fi
}

check_resources() {
    _mem=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    _swap=$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    _total=$((_mem + _swap))
    if [ "$_total" -ge "$MEM_SOFT_MB" ]; then
        ok "$((_mem / 1024)).$(((_mem % 1024) * 10 / 1024)) GB RAM, $((_swap / 1024)).$(((_swap % 1024) * 10 / 1024)) GB swap"
    else
        warn "only $((_total)) MB of RAM+swap. Node and Python builds run inside the container and are what exhaust it — a build will be killed long after this script has finished."
    fi

    # Measured where Docker actually writes, which is often not /.
    _root=/var/lib/docker
    [ "$DOCKER_PRESENT" = 1 ] && _root=$(dkr info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
    _check=$_root
    while [ ! -d "$_check" ] && [ "$_check" != / ]; do _check=$(dirname "$_check"); done
    _gb=$(df -BG --output=avail "$_check" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
    [ -n "$_gb" ] || _gb=0
    if [ "$_gb" -ge "$DISK_SOFT_GB" ]; then
        ok "$_gb GB free on $_check"
    elif [ "$_gb" -ge "$DISK_HARD_GB" ]; then
        warn "$_gb GB free on $_check — the image alone is about 1 GB, and every app keeps its own node_modules"
    else
        [ "$FORCE" = 1 ] || die "$_gb GB free on $_check is not enough to install (need at least $DISK_HARD_GB). --force overrides."
        warn "$_gb GB free on $_check — proceeding because --force was given"
    fi
}

# The container always listens on 8080 and 8081. Only the host side moves, and
# it can move freely because the browser reaches this through a tunnel — the
# origin at the laptop end stays http://localhost:8080 either way.
check_ports() {
    HOST_PLATFORM_PORT=8080
    HOST_APPS_PORT=8081

    # Already ours? Re-running the installer must not trip over itself.
    if [ "$DOCKER_PRESENT" = 1 ] && dkr ps --filter 'name=^launchpad-launchpad' --format '{{.Names}}' 2>/dev/null | grep -q .; then
        ok "ports are held by this install's own containers"
        return 0
    fi

    if ! port_in_use 8080 && ! port_in_use 8081; then
        ok 'ports 8080 and 8081 are free on 127.0.0.1'
        return 0
    fi

    _p=8080
    while [ "$_p" -lt 8200 ]; do
        if ! port_in_use "$_p" && ! port_in_use "$((_p + 1))"; then break; fi
        _p=$((_p + 2))
    done
    [ "$_p" -lt 8200 ] || die "no free pair of loopback ports between 8080 and 8200."

    HOST_PLATFORM_PORT=$_p
    HOST_APPS_PORT=$((_p + 1))
    warn "8080/8081 are in use, so this install publishes on $HOST_PLATFORM_PORT/$HOST_APPS_PORT"
    if have ss; then ss -ltnp 2>/dev/null | grep -E ':(8080|8081)\b' | sed 's/^/      /' || true; fi
    note "the tunnel maps them back: ssh -L 8080:localhost:$HOST_PLATFORM_PORT -L 8081:localhost:$HOST_APPS_PORT"
}

port_in_use() {
    if have ss; then
        ss -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$1 |\*:$1 |0\.0\.0\.0:$1 "
    elif have netstat; then
        netstat -ltn 2>/dev/null | grep -qE "127\.0\.0\.1:$1 |0\.0\.0\.0:$1 "
    else
        return 1
    fi
}

check_egress() {
    _fail=
    for _h in https://registry-1.docker.io/v2/ https://github.com; do
        if ! egress_ok "$_h"; then _fail="$_fail $_h"; fi
    done
    if [ -z "$_fail" ]; then
        ok 'Docker Hub and GitHub are reachable'
    else
        warn "cannot reach:$_fail"
        note 'the image comes from the first; apps are cloned from the second'
        if [ -n "${HTTPS_PROXY:-}${https_proxy:-}" ]; then
            note 'a proxy is set in this shell — note that the Docker daemon does not read it, and needs its own systemd drop-in'
        fi
    fi
}

egress_ok() {
    if have curl; then
        curl -fsS --max-time 8 -o /dev/null "$1" 2>/dev/null && return 0
        # 401 from a registry is a reachable registry.
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null || echo 000)" != 000 ]
    elif have wget; then
        wget -q --spider --timeout=8 "$1" 2>/dev/null
    else
        return 0
    fi
}

# A metadata endpoint that answers means deployed apps could read this node's
# cloud credentials. See compose.metadata.yml.
check_metadata() {
    if have curl && curl -fsS --max-time 1 -o /dev/null http://169.254.169.254/ 2>/dev/null; then
        IS_CLOUD=1
        ok 'cloud metadata endpoint present — deployed apps will be blocked from it'
    else
        note 'no cloud metadata endpoint'
    fi
}

# The dangerous state: a database from a previous install, and no .env. Its
# ENCRYPTION_KEY is gone, so everything encrypted in it is already unreadable.
# Generating a fresh .env over the top produces an install that boots, looks
# entirely healthy, and cannot decrypt a single stored secret.
check_existing() {
    resolve_home
    if [ -f "$HOME_DIR/.env" ]; then
        EXISTING=1
        ok "existing install in $HOME_DIR — its .env will be reused unchanged"
        return 0
    fi
    EXISTING=0
    if [ "$DOCKER_PRESENT" = 1 ] && dkr volume ls -q 2>/dev/null | grep -qx 'launchpad_postgres-data'; then
        bad 'a Launchpad database volume exists, but there is no .env beside this install'
        note 'that database was encrypted with a key that is not on this machine any more'
        [ "$FORCE" = 1 ] || die "restore the old .env into $HOME_DIR, or pass --force to start over on a fresh volume (the old one is left untouched, and you can remove it with: docker volume rm launchpad_postgres-data)."
        warn 'proceeding with --force: the existing volume will be reused and its secrets will not decrypt'
    else
        ok "nothing installed yet $M_ARROW $HOME_DIR"
    fi
}

resolve_home() {
    [ -n "$HOME_DIR" ] && return 0
    if [ "$(id -u)" = 0 ] || [ "$PRIV" = sudo ]; then
        HOME_DIR=/opt/launchpad
    else
        HOME_DIR=${HOME:-.}/.launchpad
    fi
}

# --- Phase 2: dependencies ---------------------------------------------------

ensure_docker() {
    if [ "$DOCKER_PRESENT" = 1 ] && [ "$COMPOSE_OK" = 1 ]; then return 0; fi

    # WSL with a docker CLI already on PATH is Docker Desktop, with either its
    # daemon stopped on the Windows side or this distribution left out of its
    # integration list. Neither is fixable from in here, and installing Docker
    # Engine over the top makes it worse: the machine ends up with two dockers,
    # the second one started by an init system WSL is not running, and the
    # symptom is this same message with a longer path to the cause.
    if [ "$IS_WSL" = 1 ] && [ "$DOCKER_PRESENT" = 0 ] && have docker; then
        die "the docker CLI is here but no daemon is answering it, and on WSL this script cannot start one.
  Start Docker Desktop on Windows, then Settings $M_ARROW Resources $M_ARROW WSL integration
  and turn this distribution on. 'docker info' working in this shell is the test.
  Then run this again."
    fi

    [ "$SKIP_DOCKER_INSTALL" = 0 ] ||
        die "Docker with the Compose v2 plugin is required, and --no-docker-install was given."

    section 'Installing Docker'
    _how=$(docker_install_plan)
    [ -n "$_how" ] || die "this script does not know how to install Docker on $OS_NAME.
  Install Docker Engine and the Compose v2 plugin — https://docs.docker.com/engine/install/ —
  then run this again, or pass --no-docker-install."

    note "on $OS_NAME this runs:"
    printf '%s\n' "$_how" | sed "s/^/        /"
    confirm 'Install Docker now?' || die "Docker is required. Install it yourself and re-run."

    case $(docker_family) in
    convenience) install_docker_convenience ;;
    amzn) install_docker_amzn ;;
    suse) install_docker_pkg zypper 'install -y docker docker-compose' ;;
    arch) install_docker_pkg pacman '-S --noconfirm docker docker-compose' ;;
    alpine) install_docker_pkg apk 'add --no-cache docker docker-cli-compose' ;;
    esac

    enable_daemon
    add_to_docker_group

    have docker || die "Docker still is not on PATH after installing it. The log is $LOGFILE"
    if ! docker info >/dev/null 2>&1; then
        if [ "$PRIV" != none ] && run_priv docker info >/dev/null 2>&1; then
            DOCKER_NEEDS_PRIV=1
        else
            die "the Docker daemon is not answering after installation. Try: sudo journalctl -u docker -n 50"
        fi
    fi
    dkr compose version >/dev/null 2>&1 || die "the Docker Compose v2 plugin is still missing. The log is $LOGFILE"
    DOCKER_PRESENT=1
    COMPOSE_OK=1
    ok 'Docker is ready'
}

# The family decides the commands. Docker's own convenience script covers the
# mainstream distributions and is the right thing to delegate to — but it
# refuses on Amazon Linux, which is one of the likeliest single-VM targets
# there is, and it does not cover Arch or Alpine.
docker_family() {
    case $OS_ID in
    amzn) echo amzn ;;
    arch | manjaro | endeavouros) echo arch ;;
    alpine) echo alpine ;;
    ubuntu | debian | raspbian | linuxmint | pop) echo convenience ;;
    fedora | centos | rhel | rocky | almalinux) echo convenience ;;
    sles | opensuse* | sled) echo suse ;;
    *)
        case " $OS_LIKE " in
        *' debian '* | *' ubuntu '*) echo convenience ;;
        *' fedora '* | *' rhel '* | *' centos '*) echo convenience ;;
        *' suse '*) echo suse ;;
        *' arch '*) echo arch ;;
        *) echo '' ;;
        esac
        ;;
    esac
}

docker_install_plan() {
    case $(docker_family) in
    convenience) printf 'curl -fsSL https://get.docker.com | sh' ;;
    amzn) printf 'dnf install -y docker\n(the Compose v2 plugin is not packaged for Amazon Linux and is downloaded separately)' ;;
    suse) printf 'zypper install -y docker docker-compose' ;;
    arch) printf 'pacman -S --noconfirm docker docker-compose' ;;
    alpine) printf 'apk add --no-cache docker docker-cli-compose' ;;
    *) printf '' ;;
    esac
}

install_docker_convenience() {
    # A temp file, not $HOME_DIR: Docker is installed in phase 2 and $HOME_DIR
    # is not created until phase 3, so writing there fails with `curl: (23)
    # Failure writing output to destination` — a message that names neither the
    # directory nor the reason. Nothing keeps this file anyway; it is removed
    # three lines down.
    _s=$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/launchpad-get-docker.$$.sh")
    spin 'downloading get.docker.com' fetch https://get.docker.com "$_s" ||
        die "could not download Docker's install script"
    spin 'installing Docker Engine' run_priv sh "$_s" ||
        die "Docker's install script failed. The log is $LOGFILE"
    rm -f "$_s"
}

install_docker_amzn() {
    _pm=dnf
    have dnf || _pm=yum
    spin "installing Docker Engine ($_pm)" run_priv "$_pm" install -y docker ||
        die "$_pm install docker failed. The log is $LOGFILE"

    # Compose v2 is a CLI plugin and Amazon Linux packages neither it nor
    # docker-compose-plugin. Fetched to the system plugin directory, which is
    # where `docker compose` looks.
    if ! docker compose version >/dev/null 2>&1 && ! run_priv docker compose version >/dev/null 2>&1; then
        _plugin_dir=/usr/libexec/docker/cli-plugins
        case $ARCH in amd64) _a=x86_64 ;; *) _a=aarch64 ;; esac
        _url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${_a}"
        run_priv mkdir -p "$_plugin_dir"
        spin 'downloading the Compose v2 plugin' fetch_priv "$_url" "$_plugin_dir/docker-compose" ||
            die "could not download the Compose v2 plugin from $_url"
        run_priv chmod 0755 "$_plugin_dir/docker-compose"
    fi
}

fetch_priv() {
    _tmp=$(mktemp)
    fetch "$1" "$_tmp" || {
        rm -f "$_tmp"
        return 1
    }
    run_priv cp "$_tmp" "$2"
    rm -f "$_tmp"
}

install_docker_pkg() {
    _pm=$1
    shift
    # shellcheck disable=SC2086
    spin "installing Docker Engine ($_pm)" run_priv $_pm $1 ||
        die "$_pm failed to install Docker. The log is $LOGFILE"
}

enable_daemon() {
    case $INIT in
    systemd)
        # `enable` as much as `start`: a box that reboots with the daemon
        # disabled comes back with no Launchpad and no error anywhere.
        spin 'enabling and starting the Docker daemon' run_priv systemctl enable --now docker ||
            warn 'could not enable the Docker daemon — start it yourself before the next reboot'
        ;;
    openrc)
        run_priv rc-update add docker default >/dev/null 2>&1 || true
        spin 'starting the Docker daemon' run_priv rc-service docker start ||
            warn 'could not start the Docker daemon'
        ;;
    *)
        # WSL without systemd still has the sysvinit script the Debian package
        # ships, and `service docker start` is the documented way to run it.
        if [ "$IS_WSL" = 1 ] && have service; then
            spin 'starting the Docker daemon (service)' run_priv service docker start ||
                warn 'could not start the Docker daemon — try: sudo service docker start'
        else
            note 'no init system to enable the daemon with — start Docker yourself'
        fi
        ;;
    esac
}

GROUP_ADDED=0
add_to_docker_group() {
    [ "$(id -u)" = 0 ] && return 0
    id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker && return 0
    if run_priv usermod -aG docker "$(id -un)" >/dev/null 2>&1; then
        GROUP_ADDED=1
        # The new group is not in this process's credentials and cannot be, so
        # everything from here on keeps using sudo.
        DOCKER_NEEDS_PRIV=1
        note "added $(id -un) to the docker group — it takes effect at your next login"
    fi
}

# --- Phase 3: the bundle -----------------------------------------------------

fetch_bundle() {
    section 'Setting up'
    if [ ! -d "$HOME_DIR" ]; then
        run_priv mkdir -p "$HOME_DIR"
        [ "$(id -u)" = 0 ] || run_priv chown "$(id -u):$(id -g)" "$HOME_DIR"
    fi
    [ -w "$HOME_DIR" ] || die "$HOME_DIR is not writable by $(id -un)."
    LOGFILE=$HOME_DIR/install.log
    ok "$HOME_DIR"

    # Authored beside this script? Then this is a checkout of the source, or an
    # unpacked bundle, and there is nothing to download.
    _here=$(script_dir)
    if [ -n "$_here" ] && [ -f "$_here/compose.yml" ]; then
        if [ "$_here" != "$HOME_DIR" ]; then
            for _f in $BUNDLE_FILES; do
                [ -f "$_here/$_f" ] && cp "$_here/$_f" "$HOME_DIR/$_f"
            done
        fi
        chmod +x "$HOME_DIR/uninstall.sh" 2>/dev/null || true
        ok 'using the compose files beside this script'
        return 0
    fi

    for _f in $BUNDLE_FILES; do
        spin "downloading $_f" fetch "$RAW_BASE/v$VERSION/$_f" "$HOME_DIR/$_f" ||
            die "could not download $_f from $RAW_BASE/v$VERSION/"
    done
    verify_checksums
    chmod +x "$HOME_DIR/uninstall.sh" 2>/dev/null || true
}

script_dir() {
    case ${0:-} in
    '' | sh | -sh | bash | -bash | dash) return 0 ;;
    esac
    [ -f "$0" ] || return 0
    (cd "$(dirname "$0")" 2>/dev/null && pwd) || true
}

# A mismatch is a truncated response from something in the middle, or worse.
# Neither is a thing to retry quietly.
verify_checksums() {
    fetch "$RAW_BASE/v$VERSION/SHA256SUMS" "$HOME_DIR/SHA256SUMS" 2>/dev/null || {
        note 'no SHA256SUMS published for this version — skipping verification'
        return 0
    }
    have sha256sum || {
        note 'sha256sum is not installed — skipping verification'
        return 0
    }
    if (cd "$HOME_DIR" && grep -E "($(echo "$BUNDLE_FILES" | tr ' ' '|'))\$" SHA256SUMS | sha256sum -c --quiet -) >>"$LOGFILE" 2>&1; then
        ok 'checksums verified'
    else
        die "a downloaded file does not match its published checksum. Nothing has been started."
    fi
}

# --- Phase 4: configuration --------------------------------------------------

# One value out of the .env we wrote, without sourcing a file of secrets into
# this shell.
env_value() {
    _v=$(sed -n "s/^$1=//p" "$ENVF" 2>/dev/null | tail -1)
    [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
}

configure() {
    ENVF=$HOME_DIR/.env
    if [ -f "$ENVF" ]; then
        # Reused entirely. Regenerating ENCRYPTION_KEY over a live database is
        # silent, unrecoverable data loss, so this path never writes secrets.
        ok 'reusing the existing .env'
        NEW_PASSWORD=
        sed -i "s|^LAUNCHPAD_VERSION=.*|LAUNCHPAD_VERSION=$VERSION|" "$ENVF"
        sed -i "s|^LAUNCHPAD_IMAGE=.*|LAUNCHPAD_IMAGE=$IMAGE|" "$ENVF"
        # The ports this install already publishes on win over anything the
        # port scan just guessed — they are in use precisely because they are ours.
        HOST_PLATFORM_PORT=$(env_value HOST_PLATFORM_PORT "$HOST_PLATFORM_PORT")
        HOST_APPS_PORT=$(env_value HOST_APPS_PORT "$HOST_APPS_PORT")
        return 0
    fi

    NEW_PASSWORD=$(gen_password)
    _jwt=$(gen_hex 32)
    _key=$(gen_hex 32)
    _pg=$(gen_hex 16)
    [ ${#_key} -eq 64 ] || die "could not generate a 64-character encryption key"

    _old=$(umask)
    umask 077
    {
        printf '# Written by install.sh. BACK THIS FILE UP — ENCRYPTION_KEY is the only\n'
        printf '# thing that can decrypt this install'"'"'s app secrets and git tokens.\n\n'
        printf 'LAUNCHPAD_IMAGE=%s\n' "$IMAGE"
        printf 'LAUNCHPAD_VERSION=%s\n\n' "$VERSION"
        printf 'JWT_SECRET=%s\n' "$_jwt"
        printf 'ENCRYPTION_KEY=%s\n' "$_key"
        printf 'POSTGRES_PASSWORD=%s\n\n' "$_pg"
        printf '# Read exactly once, at first boot. Removed from this file afterwards.\n'
        printf 'BOOTSTRAP_ADMIN_PASSWORD=%s\n\n' "$NEW_PASSWORD"
        # BASE_URL is the browser's origin at the far end of the tunnel, which
        # is localhost:8080 no matter which host port this machine had free.
        printf 'BASE_URL=http://localhost:8080\n'
        printf 'HOST_PLATFORM_PORT=%s\n' "$HOST_PLATFORM_PORT"
        printf 'HOST_APPS_PORT=%s\n' "$HOST_APPS_PORT"
        # Only when they differ: someone browsing from the box itself, or
        # tunnelling straight through to the host port, arrives on an origin
        # BASE_URL does not describe, and every write would 403.
        if [ "$HOST_PLATFORM_PORT" != 8080 ]; then
            printf 'EXTRA_ORIGINS=http://localhost:%s\n' "$HOST_PLATFORM_PORT"
        else
            printf 'EXTRA_ORIGINS=\n'
        fi
        [ "$IS_CLOUD" = 1 ] && printf '\nCOMPOSE_FILE=compose.yml:compose.metadata.yml\n'
    } >"$ENVF"
    umask "$_old"
    chmod 600 "$ENVF"
    ok 'generated JWT_SECRET, ENCRYPTION_KEY and the database password'
    [ "$IS_CLOUD" = 1 ] && ok 'deployed apps will be blocked from the cloud metadata endpoint'
    return 0
}

# --- Phase 5: start ----------------------------------------------------------

start() {
    section 'Starting'
    if ! spin "pulling $IMAGE:$VERSION (this usually takes a few minutes)" compose pull; then
        # A pull can fail on a machine that already has the image: an
        # air-gapped install with a side-loaded tarball, or a re-run on a box
        # that pulled it an hour ago. Refusing there would be refusing to start
        # something that is sitting on the disk.
        if dkr image inspect "$IMAGE:$VERSION" >/dev/null 2>&1; then
            note "could not reach the registry, but $IMAGE:$VERSION is already on this machine"
        else
            die "could not pull $IMAGE:$VERSION, and it is not on this machine. Check the tag exists and the registry is reachable — the log is $LOGFILE"
        fi
    fi
    spin 'starting postgres and launchpad' compose up -d ||
        die "docker compose up failed. The log is $LOGFILE"
    wait_healthy
}

wait_healthy() {
    _start=$(now)
    _limit=240
    _i=0
    while :; do
        _state=$(compose ps --format '{{.Name}} {{.State}} {{.Health}}' 2>/dev/null || echo)
        if printf '%s' "$_state" | grep -q 'launchpad-launchpad.*running.*healthy'; then
            [ "$UI_TTY" = 1 ] && printf '\r\033[K'
            ok "launchpad is healthy $C_DIM$(elapsed "$_start")$C_RESET"
            break
        fi
        # Nothing to wait for. Spinning out the full timeout against a container
        # that was never created tells the operator nothing they can act on.
        if ! printf '%s' "$_state" | grep -q 'launchpad-launchpad'; then
            [ "$UI_TTY" = 1 ] && printf '\r\033[K'
            bad 'the launchpad container was not created'
            compose ps -a 2>&1 | sed 's/^/      /' || true
            die "docker compose did not start it. The log is $LOGFILE"
        fi
        if printf '%s' "$_state" | grep -qE 'launchpad-launchpad.*(exited|restarting)'; then
            [ "$UI_TTY" = 1 ] && printf '\r\033[K'
            bad 'the launchpad container is not staying up'
            compose logs --tail 50 launchpad 2>&1 | sed 's/^/      /' || true
            die "see above, and 'docker compose -f $HOME_DIR/compose.yml logs -f launchpad' for the rest."
        fi
        if [ $(($(now) - _start)) -gt "$_limit" ]; then
            [ "$UI_TTY" = 1 ] && printf '\r\033[K'
            bad "launchpad did not become healthy within ${_limit}s"
            compose logs --tail 50 launchpad 2>&1 | sed 's/^/      /' || true
            die "see above. The container is still running; nothing has been rolled back."
        fi
        if [ "$UI_TTY" = 1 ]; then
            printf '\r    %s%s%s waiting for launchpad to become healthy %s%s%s ' \
                "$C_BLUE" "$(spin_frame "$_i")" "$C_RESET" "$C_DIM" "$(elapsed "$_start")" "$C_RESET"
        fi
        _i=$((_i + 1))
        sleep 1
    done

    # The probe the image's own healthcheck uses, asked from outside the
    # container — which is the thing the operator will actually do.
    if have curl && curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$HOST_PLATFORM_PORT/api/v1/config" 2>/dev/null; then
        ok "http://127.0.0.1:$HOST_PLATFORM_PORT answered"
    else
        warn "the platform is healthy inside its container but did not answer on 127.0.0.1:$HOST_PLATFORM_PORT"
    fi
}

# The password has been read by now, and the variable is never read again. Left
# in place it is a stale string in a file people copy around; removed, the only
# route back is the recovery command, which is the one we want them to learn.
strip_bootstrap_password() {
    [ -n "$NEW_PASSWORD" ] || return 0
    sed -i \
        -e 's|^BOOTSTRAP_ADMIN_PASSWORD=.*|# BOOTSTRAP_ADMIN_PASSWORD was read at first boot and removed.\n# A new one: docker compose exec launchpad launchpad local-admin enable|' \
        "$ENVF"
}

# --- The summary -------------------------------------------------------------

BOX_LINES=
box_add() { BOX_LINES="$BOX_LINES$1
"; }

box_print() {
    _w=0
    printf '%s' "$BOX_LINES" | while IFS= read -r _l; do printf '%s\n' "${#_l}"; done >/tmp/.lpwidths.$$ 2>/dev/null || true
    if [ -f "/tmp/.lpwidths.$$" ]; then
        _w=$(sort -n "/tmp/.lpwidths.$$" | tail -1)
        rm -f "/tmp/.lpwidths.$$"
    fi
    [ -n "$_w" ] || _w=60
    [ "$_w" -lt 60 ] && _w=60
    _bar=$(rep "$_w" '─')
    if [ "$UI_UNICODE" = 1 ]; then
        printf '\n  ╭─%s─╮\n' "$_bar"
        printf '%s' "$BOX_LINES" | while IFS= read -r _l; do
            printf '  │ %s%s │\n' "$_l" "$(rep $((_w - ${#_l})) ' ')"
        done
        printf '  ╰─%s─╯\n\n' "$_bar"
    else
        printf '\n  +-%s-+\n' "$_bar"
        printf '%s' "$BOX_LINES" | while IFS= read -r _l; do
            printf '  | %s%s |\n' "$_l" "$(rep $((_w - ${#_l})) ' ')"
        done
        printf '  +-%s-+\n\n' "$_bar"
    fi
}

rep() {
    _n=$1
    _c=$2
    _o=
    while [ "$_n" -gt 0 ]; do
        _o="$_o$_c"
        _n=$((_n - 1))
    done
    printf '%s' "$_o"
}

summary() {
    _user=$(id -un)
    _host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo this-machine)

    box_add "Launchpad $VERSION is running"
    box_add ''
    box_add "On this machine    http://localhost:$HOST_PLATFORM_PORT"
    box_add "From your laptop   ssh -L 8080:localhost:$HOST_PLATFORM_PORT \\"
    box_add "                       -L 8081:localhost:$HOST_APPS_PORT $_user@$_host"
    box_add '                   then open http://localhost:8080'
    box_add ''
    if [ -n "$NEW_PASSWORD" ]; then
        box_add 'username   admin'
        box_add "password   $NEW_PASSWORD"
        box_add ''
        box_add 'Shown once. The first sign-in has to replace it — it mints'
        box_add 'no session, only the chance to choose a real one.'
    else
        box_add 'This install already had an administrator, so no password'
        box_add 'was set. If nobody knows it:'
        box_add ''
        box_add "  cd $HOME_DIR && docker compose exec \\"
        box_add '      launchpad launchpad local-admin enable'
    fi
    box_print

    printf '  %sBoth ports matter.%s The platform is on 8080 and deployed apps are on 8081;\n' "$C_BOLD" "$C_RESET"
    printf '  forward only the first and every app you deploy will 404. Forward them to\n'
    printf '  different local ports and writes will fail — set EXTRA_ORIGINS if you must.\n\n'
    printf '  %sBack up %s.%s Its ENCRYPTION_KEY is the only thing that can decrypt\n' "$C_BOLD" "$ENVF" "$C_RESET"
    printf '  this install'"'"'s app secrets and git tokens. Nothing else has a copy.\n\n'
    if [ "$GROUP_ADDED" = 1 ]; then
        printf '  You were added to the %sdocker%s group. Log out and back in to use docker\n' "$C_BOLD" "$C_RESET"
        printf '  without sudo.\n\n'
    fi
    printf '  %sStop%s   cd %s && docker compose down\n' "$C_DIM" "$C_RESET" "$HOME_DIR"
    printf '  %sLogs%s   cd %s && docker compose logs -f\n' "$C_DIM" "$C_RESET" "$HOME_DIR"
    printf '  %sLog%s    %s\n\n' "$C_DIM" "$C_RESET" "$LOGFILE"
}

# --- main --------------------------------------------------------------------

main() {
    parse_args "$@"
    ui_init
    LOGFILE=${TMPDIR:-/tmp}/launchpad-install.log
    : >"$LOGFILE" 2>/dev/null || LOGFILE=

    printf '\n  %sLaunchpad%s %s\n' "$C_BOLD" "$C_RESET" "$VERSION"

    preflight

    if [ "$CHECK_ONLY" = 1 ]; then
        printf '\n  %s--check%s: nothing on this machine was changed.\n\n' "$C_DIM" "$C_RESET"
        exit 0
    fi

    ensure_docker
    fetch_bundle
    configure
    start
    strip_bootstrap_password
    summary
}

main "$@"
