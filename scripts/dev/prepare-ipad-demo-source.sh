#!/usr/bin/env bash
# Prepare a verified recipient source delivery. No build or installation.
set -euo pipefail
command -v python3 >/dev/null || { printf 'Python 3 is required.\n' >&2; exit 1; }
command -v git >/dev/null || { printf 'Git is required.\n' >&2; exit 1; }
exec python3 - "$@" <<'PY'
import argparse, hashlib, json, os, pathlib, re, shlex, shutil, stat, subprocess, sys, unicodedata, zipfile

parser = argparse.ArgumentParser(description='Prepare verified source locally. The expected SHA-256 must come from an independently trusted handoff, not the manifest being checked.')
parser.add_argument('--archive', required=True, type=pathlib.Path)
parser.add_argument('--manifest', required=True, type=pathlib.Path)
parser.add_argument('--destination', required=True, type=pathlib.Path)
parser.add_argument('--expected-sha256', required=True)
args = parser.parse_args()

def require(condition, message):
    if not condition:
        raise ValueError(message)

try:
    dest = pathlib.Path(os.path.abspath(args.destination.expanduser()))
    require(not dest.exists() and not dest.is_symlink(), 'Destination must be a new directory.')
    require(dest.parent.is_dir(), 'Destination parent must already exist.')
    require(not any(p.is_symlink() for p in (dest, *dest.parents)), 'Destination path must not contain symlinks.')
    for item in (args.archive, args.manifest):
        require(not item.is_symlink() and item.is_file(), 'Archive and manifest must be regular files, not symlinks.')
    require(args.manifest.stat().st_size <= 8 * 1024 * 1024, 'Manifest is too large.')
    manifest = json.loads(args.manifest.read_text())
    require(isinstance(manifest, dict), 'Manifest must be a JSON object.')
    require(manifest.get('schemaVersion') == 2, 'Unexpected manifest schema.')
    REVISION = manifest.get('originalSourceRevision', '')
    DIGEST = args.expected_sha256
    BYTE_COUNT = manifest.get('archiveBytes')
    require(isinstance(REVISION, str) and re.fullmatch('[0-9a-f]{40}', REVISION), 'Invalid original source revision.')
    require(re.fullmatch('[0-9a-f]{64}', DIGEST) and manifest.get('archiveSHA256') == DIGEST, 'Manifest does not match the independently supplied archive SHA-256.')
    require(type(BYTE_COUNT) is int and 0 < BYTE_COUNT <= 1024 * 1024 * 1024, 'Invalid archive byte count.')
    PREFIX = 'pichi-voice-' + REVISION[:12] + '/'
    require(manifest.get('archivePrefix') == PREFIX, 'Incorrect archive prefix.')
    with args.archive.open('rb') as source_zip:
        require(os.fstat(source_zip.fileno()).st_size == BYTE_COUNT, 'Archive byte count does not match.')
        digest = hashlib.sha256()
        for chunk in iter(lambda: source_zip.read(1024 * 1024), b''):
            digest.update(chunk)
        require(digest.hexdigest() == DIGEST, 'Archive SHA-256 does not match.')
        source_zip.seek(0)
        with zipfile.ZipFile(source_zip) as archive:
            require(archive.comment.decode('ascii') == REVISION, 'ZIP original revision comment does not match.')
            entries, seen, total = [], {}, 0
            require(len(archive.infolist()) <= 10000, 'Too many ZIP entries.')
            for entry in archive.infolist():
                name = entry.filename
                require(name == entry.orig_filename and name.startswith(PREFIX) and '\\' not in name and ':' not in name, 'Unsafe ZIP path.')
                relative = name[len(PREFIX):].rstrip('/')
                mode = entry.external_attr >> 16
                require(entry.create_system == 3 and (stat.S_ISREG(mode) or stat.S_ISDIR(mode)), 'ZIP contains a symlink or unsupported file type.')
                require(entry.is_dir() == stat.S_ISDIR(mode), 'ZIP entry type mismatch.')
                if not relative:
                    require(entry.is_dir(), 'Invalid archive root.')
                    continue
                parts = relative.split('/')
                require(all(p and p not in ('.', '..') and p.casefold() != '.git' for p in parts), 'Unsafe ZIP path component.')
                key = unicodedata.normalize('NFD', relative).casefold()
                require(key not in seen, 'Duplicate or case-colliding ZIP path.')
                seen[key] = entry.is_dir()
                total += entry.file_size
                require(total <= 1024 * 1024 * 1024, 'Expanded archive is too large.')
                entries.append((entry, relative, mode))
            for key in seen:
                require(all(seen.get(str(p), True) for p in pathlib.PurePosixPath(key).parents if str(p) != '.'), 'ZIP file conflicts with a parent directory.')
            require('scripts/dev/new-worktree.sh' in seen and 'fluid.xcodeproj/project.pbxproj' in seen, 'Missing project or worktree helper.')
            dest.mkdir(mode=0o700)
            primary = dest / 'source'
            primary.mkdir()
            for entry, relative, mode in entries:
                output = primary / relative
                if entry.is_dir():
                    output.mkdir(parents=True, exist_ok=True)
                else:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    with archive.open(entry) as incoming, output.open('xb') as outgoing:
                        shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
                    output.chmod(0o755 if mode & 0o111 else 0o644)
    # Ignore inherited Git configuration, hooks, filters, signing and credentials.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    env.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
               PICHI_VOICE_WORKTREE_ROOT=str(dest / 'worktrees'))
    def git(*words):
        return subprocess.check_output(['git', '-c', 'core.hooksPath=' + os.devnull,
            '-c', 'core.fsmonitor=false', '-c', 'commit.gpgSign=false', *words],
            cwd=primary, env=env, text=True).strip()
    git('init', '--template=', '-b', 'main')
    # The delivery contains tracked files matching inherited ignore rules.
    git('add', '--force', '.')
    git('-c', 'user.name=Local Demo', '-c', 'user.email=demo@example.invalid',
        'commit', '-m', 'Import verified delivered demo sources')
    local_commit = git('rev-parse', 'HEAD')
    worktree = subprocess.check_output(['bash', 'scripts/dev/new-worktree.sh', 'ratibor-demo', local_commit],
        cwd=primary, env=env, text=True).strip()
    print('Prepared source only. No build, provisioning or installation performed.')
    print('Original source revision: ' + REVISION)
    print('Local import commit (different identity): ' + local_commit)
    print('Isolated worktree: ' + worktree)
    print('Next: open ' + shlex.quote(str(pathlib.Path(worktree) / 'Fluid.xcodeproj')))
    print('Before building: set Release PICHI_SOURCE_REVISION=' + REVISION)
    print('Use your own Personal Team and unique bundle ID; follow the delivered quickstart.')
except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
    print('STOP: ' + str(error), file=sys.stderr)
    print('No existing installation was changed. If a new destination was partially created, keep it and retry with a different new directory.', file=sys.stderr)
    sys.exit(1)
PY
