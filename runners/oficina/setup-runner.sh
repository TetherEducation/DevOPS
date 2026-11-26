#!/usr/bin/env bash
# Convierte un Ubuntu 24.04 (VM de Hyper-V, recomendado, o WSL2) en un runner de
# GitHub Actions de TetherEducation para los jobs programados. Ver README.md.
#
# Uso, como root dentro de la VM:
#   sudo RUNNER_TOKEN=<token de registro> bash setup-runner.sh [nombre-del-runner]
#
# Se puede volver a correr: lo que ya está hecho no se repite.
set -euo pipefail

ORG_URL="https://github.com/TetherEducation"
RUNNER_GROUP="${RUNNER_GROUP:-office}"
RUNNER_LABELS="${RUNNER_LABELS:-office-async}"
RUNNER_USER="${RUNNER_USER:-ghrunner}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_NAME="${1:-oficina-$(hostname)}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "correr con sudo"
# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "se necesita Ubuntu (24.04 recomendado); esto es ${PRETTY_NAME:-desconocido}"
[ "$(uname -m)" = x86_64 ] || die "se necesita una máquina x86_64"
[ "$(ps -p 1 -o comm=)" = systemd ] || die "systemd no está activo. En WSL: poner '[boot]' y 'systemd=true' en /etc/wsl.conf, correr 'wsl --shutdown' en Windows y volver a entrar."

echo "== 1/5 Paquetes base y Docker Engine"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl git jq cron
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker cron

echo "== 2/5 Usuario $RUNNER_USER (sin sudo; en el grupo docker para los services de los workflows)"
id -u "$RUNNER_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$RUNNER_USER"
usermod -aG docker "$RUNNER_USER"

echo "== 3/5 Runner de GitHub Actions en $RUNNER_DIR"
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"
if [ ! -x ./config.sh ]; then
  rel=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest)
  ver=$(jq -r .tag_name <<<"$rel")
  ver=${ver#v}
  # Las release notes del runner traen el SHA-256 de cada paquete entre estos marcadores.
  sha=$(jq -r .body <<<"$rel" | grep -o '<!-- BEGIN SHA linux-x64 -->[0-9a-f]\{64\}' | grep -o '[0-9a-f]\{64\}$' || true)
  [ -n "$sha" ] || die "no encontré el SHA-256 del runner $ver en sus release notes"
  curl -fsSLo runner.tar.gz "https://github.com/actions/runner/releases/download/v${ver}/actions-runner-linux-x64-${ver}.tar.gz"
  echo "$sha  runner.tar.gz" | sha256sum -c -
  tar xzf runner.tar.gz
  rm runner.tar.gz
  ./bin/installdependencies.sh
fi
chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

echo "== 4/5 Registro en $ORG_URL (grupo '$RUNNER_GROUP', etiqueta '$RUNNER_LABELS')"
if [ -f .runner ]; then
  echo "Ya estaba registrado; no lo registro de nuevo."
else
  [ -n "${RUNNER_TOKEN:-}" ] || die "falta RUNNER_TOKEN (token de registro; dura 1 hora, ver README.md)"
  sudo -u "$RUNNER_USER" ./config.sh --unattended --url "$ORG_URL" --token "$RUNNER_TOKEN" \
    --name "$RUNNER_NAME" --runnergroup "$RUNNER_GROUP" --labels "$RUNNER_LABELS" \
    --work _work --replace
fi
# config.sh genera svc.sh; svc.sh install deja el nombre del servicio en .service.
[ -f .service ] || ./svc.sh install "$RUNNER_USER"
./svc.sh start

echo "== 5/5 Limpieza semanal de Docker"
cat > /etc/cron.weekly/docker-prune <<'EOF'
#!/bin/sh
# Imágenes y contenedores de jobs con más de 7 días, para que no se llene el disco.
docker system prune -af --filter "until=168h" >/dev/null 2>&1 || true
EOF
chmod 0755 /etc/cron.weekly/docker-prune

./svc.sh status | sed -n '1,6p'
echo
echo "Listo. '$RUNNER_NAME' debería verse 'Idle' en"
echo "https://github.com/organizations/TetherEducation/settings/actions/runners"
