#!/usr/bin/env bash
set -euo pipefail

TR_WEBROOT="${TR_WEBROOT:-/var/www/testrail}"
TR_APP_USER="${TR_APP_USER:-testrail}"
TR_APP_UID="${TR_APP_UID:-1001}"
TR_APP_GID="${TR_APP_GID:-1001}"
TR_DEFAULT_TASK_EXECUTION="${TR_DEFAULT_TASK_EXECUTION:-60}"

# Chrome Headless Shell path (TestRail uses this)
TR_CHROME_PATH="${TR_CHROME_PATH:-/usr/bin/chrome-headless-shell-linux64/chrome-headless-shell}"

# Directories TestRail writes to
TR_CONFIGPATH="${TR_CONFIGPATH:-${TR_WEBROOT}/config}"
TR_OPT_BASE="${TR_OPT_BASE:-/opt/testrail}"
TR_DEFAULT_LOG_DIR="${TR_DEFAULT_LOG_DIR:-${TR_OPT_BASE}/logs}"
TR_DEFAULT_AUDIT_DIR="${TR_DEFAULT_AUDIT_DIR:-${TR_OPT_BASE}/audit}"
TR_DEFAULT_REPORT_DIR="${TR_DEFAULT_REPORT_DIR:-${TR_OPT_BASE}/reports}"
TR_DEFAULT_ATTACHMENT_DIR="${TR_DEFAULT_ATTACHMENT_DIR:-${TR_OPT_BASE}/attachments}"

ensure_dir_owned() {
  local d="$1"
  mkdir -p "$d"

  # Required for runtime writes
  chown -R "${TR_APP_UID}:${TR_APP_GID}" "$d" 2>/dev/null || true
  chmod -R u+rwX,g+rwX "$d" 2>/dev/null || true

  # Probe write ability; don't fail on bind mounts
  touch "${d}/.permcheck" 2>/dev/null || true
  rm -f "${d}/.permcheck" 2>/dev/null || true
}

ensure_exec_path() {
  local p="$1"

  if [ ! -e "$p" ]; then
    echo "ERROR: Chrome Headless Shell not found at: $p" >&2
    echo "       Make sure chrome-headless-shell-linux64.zip was copied/unzipped into /usr/bin." >&2
    ls -la /usr/bin/chrome-headless-shell-linux64 2>/dev/null || true
    exit 1
  fi

  # Ensure directory is searchable and binary is executable for TR_APP_UID/GID
  local dir
  dir="$(dirname "$p")"

  chmod 0755 "$dir" 2>/dev/null || true
  chmod 0755 "$p" 2>/dev/null || true

  # If you *must* enforce ownership at runtime (your ask):
  chown -R "${TR_APP_UID}:${TR_APP_GID}" "$dir" 2>/dev/null || true

  # Optional: quick self-test (won't fail container if it can't run due to sandbox)
  "$p" --version >/dev/null 2>&1 || true
}

echo "==> Preparing TestRail writable directories"
ensure_dir_owned "${TR_CONFIGPATH}"
ensure_dir_owned "${TR_DEFAULT_LOG_DIR}"
ensure_dir_owned "${TR_DEFAULT_AUDIT_DIR}"
ensure_dir_owned "${TR_DEFAULT_REPORT_DIR}"
ensure_dir_owned "${TR_DEFAULT_ATTACHMENT_DIR}"

echo "==> Preparing Chrome Headless Shell"
ensure_exec_path "${TR_CHROME_PATH}"

# php-fpm socket dir must exist and be writable
mkdir -p /run/php-fpm
chown -R "${TR_APP_UID}:${TR_APP_GID}" /run/php-fpm 2>/dev/null || true
chmod -R 0775 /run/php-fpm 2>/dev/null || true

echo "==> Starting php-fpm"
# php-fpm master runs as root, workers run as TR_APP_USER/TR_APP_GID (from www.conf)
php-fpm -F &

echo "==> Starting background task loop (task.php)"
while [ ! -f "${TR_WEBROOT}/task.php" ]; do
  sleep 2
done

(
  while true; do
    php "${TR_WEBROOT}/task.php" || true
    sleep "${TR_DEFAULT_TASK_EXECUTION}"
  done
) &

echo "==> Starting httpd"
exec /usr/sbin/httpd -DFOREGROUND
