#!/usr/bin/env bash
# Artha Marketing (Mautic) — deterministic boot for Scalingo buildpack deploys.
# Scalingo's archive deploys do not reliably run postdeploy hooks, so config
# generation + schema install/migration are performed here, idempotently, on
# every web boot. DB creds are read live from SCALINGO_MYSQL_URL so addon
# credential rotation never breaks the app.
#
# IMPORTANT (Mautic gotcha): mautic:install short-circuits ("already installed")
# whenever config/local.php contains BOTH db_driver AND site_url. So on a fresh
# DB we must write a local.php WITHOUT site_url, run the installer (which creates
# the schema + admin and appends site_url itself), and only then write the full
# runtime config. The mysql client is NOT present in the PHP slug, so schema
# detection is done via PHP PDO.
set -uo pipefail

export MAUTIC_ENV="${MAUTIC_ENV:-prod}"
SITE_URL="${ARTHA_SITE_URL:-https://${APP:-artha-marketing}.osc-fr1.scalingo.io}"
SECRET_KEY="${ARTHA_SECRET_KEY:-changeme-set-ARTHA_SECRET_KEY}"

php_console() { php -d memory_limit=-1 bin/console "$@" --no-interaction; }

# write_local_config <with_site_url:0|1>  — regenerate config/local.php from env.
write_local_config() {
  ARTHA_WITH_SITE_URL="$1" ARTHA_SITE_URL_VAL="$SITE_URL" ARTHA_SECRET_VAL="$SECRET_KEY" \
  python3 - <<'PY'
import os, urllib.parse as u
with_site = os.environ.get("ARTHA_WITH_SITE_URL", "1") == "1"
url = os.environ.get("SCALINGO_MYSQL_URL", "")
p = u.urlparse(url) if url else None
cfg = {
    "db_driver": "pdo_mysql",
    "db_host": p.hostname if p else "127.0.0.1",
    "db_port": (p.port or 3306) if p else 3306,
    "db_name": p.path.lstrip("/") if p else "mautic",
    "db_user": p.username if p else "root",
    "db_password": u.unquote(p.password or "") if p else "",
    "db_table_prefix": "",
    "secret_key": os.environ.get("ARTHA_SECRET_VAL", ""),
}
if with_site:
    cfg.update({
        "site_url": os.environ.get("ARTHA_SITE_URL_VAL", ""),
        "mailer_from_name": os.environ.get("ARTHA_MAILER_FROM_NAME", "Artha Marketing"),
        "mailer_from_email": os.environ.get("ARTHA_MAILER_FROM", "no-reply@arthize.com"),
        "mailer_dsn": os.environ.get("ARTHA_MAILER_DSN", "null://null"),
    })
def php(v):
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int):  return str(v)
    return "'" + str(v).replace("\\", "\\\\").replace("'", "\\'") + "'"
lines = ["<?php", "$parameters = array("]
lines += [f"    '{k}' => {php(v)}," for k, v in cfg.items()]
lines += [");"]
os.makedirs("config", exist_ok=True)
open("config/local.php", "w").write("\n".join(lines) + "\n")
print("[artha-boot] wrote config/local.php (db_host=%s db_name=%s site_url=%s)"
      % (cfg["db_host"], cfg["db_name"], "yes" if with_site else "no"))
PY
}

# schema_installed -> echoes "1" if the users table exists, else "0".
schema_installed() {
  php -r '
    $url = getenv("SCALINGO_MYSQL_URL");
    if (!$url) { echo "0"; exit; }
    $p = parse_url($url);
    $db = ltrim($p["path"] ?? "", "/");
    try {
        $pdo = new PDO("mysql:host={$p["host"]};port=".($p["port"] ?? 3306).";dbname={$db}",
                       $p["user"] ?? "", isset($p["pass"]) ? urldecode($p["pass"]) : "");
        $n = $pdo->query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=".$pdo->quote($db)." AND table_name=\"users\"")->fetchColumn();
        echo ($n > 0) ? "1" : "0";
    } catch (Throwable $e) { echo "0"; }
  '
}

INSTALLED="$(schema_installed)"
echo "[artha-boot] schema_installed=${INSTALLED}"

if [ "$INSTALLED" != "1" ]; then
  echo "[artha-boot] fresh DB -> writing site_url-less config, running mautic:install"
  write_local_config 0
  php_console mautic:install "$SITE_URL" --force \
      --admin_email="${ARTHA_ADMIN_EMAIL:-admin@arthize.com}" \
      --admin_password="${ARTHA_ADMIN_PASSWORD:-Artha!Admin1@}" \
      --admin_firstname="Artha" --admin_lastname="Admin" \
      && echo "[artha-boot] mautic:install OK" \
      || echo "[artha-boot] WARNING: mautic:install returned non-zero"
  # Re-check; if still empty the install genuinely failed.
  INSTALLED="$(schema_installed)"
  echo "[artha-boot] post-install schema_installed=${INSTALLED}"
else
  echo "[artha-boot] schema present -> applying migrations"
  php_console doctrine:migrations:migrate --allow-no-migration || true
fi

# Always write the full runtime config (db + site_url + mailer) for the web app.
write_local_config 1

php_console cache:clear || true

# Register/sync plugins (incl. ArthaSsoBundle) in the plugins table. The Artha
# SSO route works from bundle registration alone, so this is best-effort.
php_console mautic:plugins:reload || true

echo "[artha-boot] starting nginx+php-fpm via buildpack bin/run (port ${PORT:-5000})"
exec bash bin/run
