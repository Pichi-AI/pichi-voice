#!/usr/bin/env bash
set -euo pipefail

pichi_analytics_mode="${1:-env}"
case "$pichi_analytics_mode" in
    env|infisical) ;;
    *) printf '%s\n' 'Usage: bash scripts/dev/analytics-config.sh env|infisical' >&2; exit 1 ;;
esac
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh

# Capture only ingestion credentials. Never export the entire secret project or
# copy its personal/admin API key into the desktop build.
python3 -S - "$pichi_analytics_mode" "$pichi_root" <<'PY'
import json, os, pathlib, re, subprocess, sys, tempfile, urllib.parse

mode, root = sys.argv[1:]
class ConfigurationError(Exception):
    pass
directory = pathlib.Path(root) / '.build' / 'private'
directory.mkdir(parents=True, exist_ok=True, mode=0o700)
destination = directory / 'pichi-posthog.xcconfig'
try:
    if mode == 'infisical':
        domain = os.environ.get('PICHI_INFISICAL_DOMAIN', '')
        project = os.environ.get('PICHI_INFISICAL_PROJECT_ID', '')
        environment = os.environ.get('PICHI_INFISICAL_ENVIRONMENT', 'local')
        if not domain.startswith('https://') or not re.fullmatch(r'[a-fA-F0-9-]{36}', project):
            raise ConfigurationError('Set PICHI_INFISICAL_DOMAIN and PICHI_INFISICAL_PROJECT_ID from the approved Pichi secret project.')
        result = subprocess.run(
            ['infisical', 'secrets', 'get', 'POSTHOG_KEY', 'POSTHOG_HOST',
             '--domain=' + domain, '--projectId=' + project, '--env=' + environment,
             '--output=json', '--silent', '--telemetry=false'],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
        if result.returncode:
            raise ConfigurationError('Infisical ingestion-key lookup failed. Check the existing local login and environment; no credential values were printed.')
        secrets = json.loads(result.stdout)
        if not isinstance(secrets, list):
            raise ConfigurationError('Unexpected Infisical response; no configuration was written.')
        values = {
            item.get('secretKey', item.get('key')): item.get('secretValue', item.get('value'))
            for item in secrets if isinstance(item, dict)
        }
        token, host = values.get('POSTHOG_KEY', ''), values.get('POSTHOG_HOST', '')
    else:
        token = os.environ.get('PICHI_POSTHOG_PROJECT_TOKEN', os.environ.get('POSTHOG_KEY', ''))
        host = os.environ.get('PICHI_POSTHOG_HOST', os.environ.get('POSTHOG_HOST', ''))
    if not isinstance(token, str) or not re.fullmatch(r'phc_[A-Za-z0-9_-]{4,252}', token):
        raise ConfigurationError('A PostHog ingestion project token is required. Personal/admin tokens are never accepted.')
    parsed = urllib.parse.urlsplit(host)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.path not in ('', '/') or parsed.query or parsed.fragment
            or parsed.port not in (None, 443) or re.search(r'[\s$\\#]', host)):
        raise ConfigurationError('An explicit HTTPS ingestion origin is required.')
    enabled = os.environ.get('PICHI_POSTHOG_ENABLED', 'yes').lower()
    if enabled not in ('yes', 'no'):
        raise ConfigurationError('PICHI_POSTHOG_ENABLED must be yes or no.')
    # Avoid xcconfig treating // as a comment. $() expands to the empty string.
    escaped_host = host.rstrip('/').replace('https://', 'https:/$()/')
    text = ('// Private build input. Never commit this file or build logs that expand its token.\n'
            'PICHI_POSTHOG_ENABLED = ' + enabled.upper() + '\n'
            'PICHI_POSTHOG_PROJECT_TOKEN = ' + token + '\n'
            'PICHI_POSTHOG_HOST = ' + escaped_host + '\n')
    descriptor, temporary = tempfile.mkstemp(prefix='.analytics-', dir=directory)
    try:
        with os.fdopen(descriptor, 'w') as output:
            os.chmod(temporary, 0o600)
            output.write(text)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(json.dumps({'configuration': str(destination), 'enabled': enabled == 'yes',
                      'ingestionHost': host.rstrip('/'), 'source': mode, 'tokenPrinted': False}))
except Exception as error:
    # Do not continue an explicit refresh with a previous project's credentials.
    destination.unlink(missing_ok=True)
    if isinstance(error, ConfigurationError):
        print(str(error), file=sys.stderr)
    else:
        print('Analytics configuration could not be prepared; no credential values were printed.', file=sys.stderr)
    sys.exit(1)
PY
