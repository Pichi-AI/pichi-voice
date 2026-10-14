#!/usr/bin/env python3
"""Opt-in, synthetic Command Mode semantic regression for an existing local Ollama.

No CI registration, installation, preference access or command execution. Requires
an explicit model, artifact digest and loopback /v1 URL. Eight fixed cases maximum;
60 seconds/request, 240 seconds/run, 2 MiB/response, 4096 frames, 128 KiB/frame.
Raw requests, responses, failures and source/model provenance go into ignored .build.

Offline examples (no HTTP, including metadata):
  python3 -S Tests/probe_command_profile_quality.py --model MODEL --model-digest SHA256 \
    --base-url http://127.0.0.1:11434/v1 --dry-render
  # Compare the original-case request with a caller-owned captured native request:
  python3 -S Tests/probe_command_profile_quality.py --model MODEL --model-digest SHA256 \
    --base-url http://127.0.0.1:11434/v1 --compare-capture /absolute/request.json

Replace --dry-render with --enable-inference only when inference is authorized.
The snapshot uses streaming, think=false, temperature=0.1, default context/output,
and a finite 60s lease. It does not read saved app settings or reproduce residency
pinning. Caller-selected reasoning preferences may differ from this fixed profile.
This independently projects native requests, not the Swift runtime/parser.
Transport/config source drift fails closed and requires a reviewed runner update.
"""

import argparse
import hashlib
import http.client
import json
from pathlib import Path
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlsplit
import uuid

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL = ('Это синтетический тест E2E финальной сборки DC. Не используй инструменты. '
            'Сколько будет 2 + 2? Ответь ровно: E2E-DC-OK 4')
PRINT_COMMAND = "printf 'COMMAND-PROBE-OK\\n'"
CASES = [
    ('original', ORIGINAL, 'E2E-DC-OK 4'),
    ('en-direct', 'Without using tools, what is 9 minus 5? Reply with only the numeral.', '4'),
    ('ru-information', 'Не используй инструменты. Как называется столица Франции? '
     'Ответь одним словом, без знаков препинания.', 'Париж'),
    ('exact-unicode', 'Do not use tools. Return exactly the following text, with no other content: '
     'Ёжик, café, 東京 ✅', 'Ёжик, café, 東京 ✅'),
    ('safe-tool-contract', 'Use the terminal tool to print COMMAND-PROBE-OK to standard output '
     'using exactly this command: ' + PRINT_COMMAND + '. This does not read or change files. '
     'Do not run any other commands.', None),
    ('command-as-text', 'Do not use tools or run anything. Return only the shell command that '
     'prints the word hello using printf with a newline. Use single quotes and no code fence.',
     "printf 'hello\\n'"),
    ('original-repeat-one', ORIGINAL, 'E2E-DC-OK 4'),
    ('original-repeat-two', ORIGINAL, 'E2E-DC-OK 4'),
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def bounded_file(path):
    require(path.is_file() and path.stat().st_size <= 2_097_152, 'Expected bounded regular file')
    return path.read_text()


def swift_string(literal):
    require('\\(' not in literal, 'Swift interpolation needs a reviewed extraction update')
    if literal.startswith('"""'):
        require(literal.startswith('"""\n'), 'Unsupported Swift multiline string')
        # Match Swift closing-delimiter indentation; reject unsupported escapes.
        lines = literal[4:-3].split('\n')
        indent = lines.pop()
        require(not indent.strip(), 'Unsupported multiline closing delimiter')
        require(all(not line.strip() or line.startswith(indent) for line in lines), 'Invalid indentation')
        value = '\n'.join(line[len(indent):] if line.strip() else '' for line in lines)
        require('\\' not in value, 'Multiline escapes need a reviewed extraction update')
        return value
    return json.loads(literal)


def swift_data(source):
    """Read only Swift's current data-only dictionary/array/string literal subset."""
    tokens = []
    pattern = re.compile(r'\s*("""[\s\S]*?"""|"(?:\\.|[^"\\])*"|[\[\]:,])')
    position = 0
    while position < len(source):
        match = pattern.match(source, position)
        require(match is not None, 'Unsupported tool literal expression')
        tokens.append(match[1])
        position = match.end()
    index = 0

    def parse():
        nonlocal index
        token = tokens[index]
        index += 1
        if token.startswith('"'):
            return swift_string(token)
        require(token == '[', 'Expected literal container')
        if tokens[index] == ']':
            index += 1
            return []
        first = parse()
        mapping = tokens[index] == ':'
        result = {} if mapping else []
        while True:
            if mapping:
                require(isinstance(first, str) and first not in result, 'Invalid/duplicate dictionary key')
                require(tokens[index] == ':', 'Expected dictionary colon')
                index += 1
                result[first] = parse()
            else:
                result.append(first)
            if tokens[index] == ',':
                index += 1
                if tokens[index] != ']':
                    first = parse()
                    continue
            require(tokens[index] == ']', 'Expected container end')
            index += 1
            return result

    result = parse()
    require(index == len(tokens), 'Unexpected trailing tool expression')
    return result


def source_request(model):
    paths = ['Sources/Fluid/Services/' + name + '.swift'
             for name in ('CommandModeService', 'TerminalService', 'OllamaChatAdapter')]
    sources = {path: bounded_file(ROOT / path) for path in paths}
    command, terminal, adapter = (sources[path] for path in paths)
    # Audit markers cover the native transport and production configuration. Prompt
    # and tool data are extracted afresh, so future prompt changes can be evaluated.
    require(digest(adapter.encode()) == '86c645ab56b5c1e9ef62aec0d43a9479e8daaa140c16e09441434465ae736ac7',
            'Ollama transport changed; audit this source projection before running')
    config = command.split('        var config = LLMClient.Config(')
    require(len(config) == 2, 'Expected one production Command Mode config')
    config = '        var config = LLMClient.Config(' + config[1].split('\n        config.providerOptions')[0]
    require(digest(config.encode()) == 'e27521ad672092f008e6333e2ae57a7b047495b47796051f09e829f3463bf131',
            'Command request configuration changed; audit this projection')
    prompts = re.findall(r'        let systemPrompt = ("""\n[\s\S]*?\n        """)', command)
    require(len(prompts) == 1, 'Expected one literal production system prompt')
    prompt = swift_string(prompts[0])
    definitions = re.findall(r'static var toolDefinition: \[String: Any\] \{\s*return (\[[\s\S]*?\])\s*\n    \}', terminal)
    require(len(definitions) == 1, 'Expected one data-only production tool definition')
    tool = swift_data(definitions[0])
    require(tool.get('type') == 'function' and tool.get('function', {}).get('name') == 'execute_terminal_command',
            'Unexpected terminal tool contract')
    defaults = {}
    for name in ('defaultContextTokens', 'defaultOutputTokens'):
        values = re.findall(r'static let ' + name + r' = (\d+)\n', adapter)
        require(len(values) == 1, 'Expected one native transport default')
        defaults[name] = int(values[0])
    request = dict(model=model, stream=True, think=False, keep_alive='60s', truncate=False, shift=False,
                   options=dict(num_ctx=defaults['defaultContextTokens'], num_predict=defaults['defaultOutputTokens'], temperature=0.1),
                   tools=[tool], messages=[dict(role='system', content=prompt)])
    return request, {path: digest(text.encode()) for path, text in sources.items()}


def loopback_url(value):
    require(not any(ord(char) <= 32 for char in value), 'URL must not contain whitespace/control characters')
    parsed = urlsplit(value)
    require(parsed.scheme in ('http', 'https') and parsed.port == 11434
            and parsed.hostname in ('localhost', '127.0.0.1', '::1')
            and parsed.path in ('/v1', '/v1/') and not any((parsed.username, parsed.password, parsed.query, parsed.fragment))
            and '?' not in value and '#' not in value and '@' not in value, 'Expected credential-free loopback Ollama /v1 URL on port 11434')
    return parsed


def evaluate(raw, expected):
    lines = raw.splitlines()
    require(0 < len(lines) <= 4096 and all(len(line) <= 131_072 for line in lines), 'Invalid frame bounds')
    frames = [json.loads(line) for line in lines]
    require(all(isinstance(frame, dict) and not frame.get('error') for frame in frames)
            and frames[-1].get('done') is True and frames[-1].get('done_reason') == 'stop' and not any(frame.get('done') for frame in frames[:-1]), 'Incomplete/error native stream')
    content = ''.join(frame.get('message', {}).get('content', '') for frame in frames)
    calls = [call for frame in frames for call in frame.get('message', {}).get('tool_calls', [])]
    if expected is None:
        function = calls[0].get('function', {}) if len(calls) == 1 else {}
        arguments = function.get('arguments', {})
        passed = (function.get('name') == 'execute_terminal_command' and isinstance(arguments, dict)
                  and arguments.get('command') == PRINT_COMMAND and isinstance(arguments.get('purpose'), str)
                  and bool(arguments['purpose'].strip()) and set(arguments) <= {'command', 'purpose', 'workingDirectory'}
                  and arguments.get('workingDirectory', '') in ('', None))
    else:
        passed = content.strip() == expected and not calls
    return dict(content=content, tool_calls=calls, expected=expected, passed=passed, tools_executed=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--model', required=True)
    parser.add_argument('--model-digest', required=True)
    parser.add_argument('--base-url', required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--dry-render', action='store_true')
    mode.add_argument('--compare-capture', type=Path)
    mode.add_argument('--enable-inference', action='store_true')
    args = parser.parse_args()
    parsed = loopback_url(args.base_url)
    require(re.fullmatch(r'[0-9a-f]{64}', args.model_digest) is not None, 'Expected SHA-256 model artifact digest')
    require(0 < len(args.model) <= 256 and args.model.strip() == args.model, 'Invalid explicit model')
    request, provenance = source_request(args.model)
    output = ROOT / '.build/command-profile-quality-probe' / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-') + uuid.uuid4().hex[:8])
    require(subprocess.run(['git', '-C', str(ROOT), 'check-ignore', '-q', str(output)]).returncode == 0,
            'Probe output must stay Git-ignored')
    output.mkdir(parents=True)
    report = dict(source_revision=subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
                  source_dirty=bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain'])),
                  sources=provenance, model=args.model, expected_digest=args.model_digest, base_url=args.base_url,
                  harness_sha256=digest(Path(__file__).read_bytes()),
                  planned_cases=[dict(case=name, expected=expected) for name, _, expected in CASES],
                  generation_calls=0, tools_executed=False, results=[], status='RUNNING',
                  limits='Independent native request projection; no Swift decoder or installed app execution. Finite synthetic cases do not establish general accuracy.')
    started_run = time.monotonic()
    deadline = started_run + 240

    def http(path, body, destination):
        connection_type = http.client.HTTPSConnection if parsed.scheme == 'https' else http.client.HTTPConnection
        connection = connection_type('::1' if parsed.hostname == '::1' else '127.0.0.1', 11434, timeout=5)
        request_deadline = min(deadline, time.monotonic() + 60)
        try:
            require(time.monotonic() < request_deadline, 'Request/run deadline exceeded')
            connection.connect()
            sock = connection.sock
            sock.settimeout(max(0.001, min(5, request_deadline - time.monotonic())))
            connection.request('POST' if body is not None else 'GET', path, body=body,
                               headers={'Content-Type': 'application/json'} if body is not None else {})
            sock.settimeout(max(0.001, request_deadline - time.monotonic()))
            response = connection.getresponse()
            total = 0
            with destination.open('wb') as stream:
                while True:
                    require(time.monotonic() < request_deadline, 'Request/run deadline exceeded')
                    sock.settimeout(max(0.001, request_deadline - time.monotonic()))
                    chunk = response.read1(min(65_536, 2_097_153 - total))
                    if not chunk:
                        break
                    stream.write(chunk)
                    total += len(chunk)
                    require(total <= 2_097_152, 'Response byte limit exceeded')
            require(response.status == 200, 'HTTP status ' + str(response.status))
            return destination.read_bytes()
        finally:
            connection.close()

    def metadata():
        version = json.loads(http('/api/version', None, output / 'version.json'))
        require(re.match(r'^(?:[1-9]\d*\.|0\.(?:1[6-9]|[2-9]\d|\d{3,})\.)', version.get('version', '')), 'Ollama 0.16+ required')
        tags_path = output / 'tags.json'
        tags = json.loads(http('/api/tags', None, tags_path))
        # Retain only the explicit selected model; do not retain other installed names.
        selected = [model for model in tags.get('models', []) if model.get('name') == args.model]
        save(tags_path, {'selected': selected})
        require(len(selected) == 1 and selected[0].get('digest') == args.model_digest, 'Pinned artifact unavailable or changed')
        return dict(version=version, selected_model=selected[0])

    try:
        requests = []
        for index, (name, user, expected) in enumerate(CASES, 1):
            body = dict(request, messages=request['messages'] + [dict(role='user', content=user)])
            payload = json.dumps(body, ensure_ascii=False).encode()
            (output / f'{index:02}-{name}-request.json').write_bytes(payload)
            requests.append((name, expected, payload))
        if args.compare_capture:
            require(json.loads(bounded_file(args.compare_capture)) == json.loads(requests[0][2]), 'Captured request differs from current source/profile')
            report['status'] = 'OFFLINE_CAPTURE_MATCH'
        elif args.dry_render:
            report['status'] = 'OFFLINE_RENDERED'
        else:
            report['preflight'] = metadata()
            for index, (name, expected, payload) in enumerate(requests, 1):
                require(time.monotonic() < deadline, 'Run deadline exceeded')
                report['generation_calls'] += 1
                report['active_case'] = name
                save(output / 'report.json', report)
                started = time.monotonic()
                raw = http('/api/chat', payload, output / f'{index:02}-{name}-raw.ndjson')
                result = dict(case=name, request_sha256=digest(payload), latency_seconds=time.monotonic() - started,
                              **evaluate(raw, expected))
                report['results'].append(result)
                report.pop('active_case', None)
                save(output / f'{index:02}-{name}-receipt.json', result)
            report['postflight'] = metadata()
            report['status'] = 'PASS' if all(result['passed'] for result in report['results']) else 'FAIL'
    except (Exception, KeyboardInterrupt) as error:
        report.update(status='ERROR', error=type(error).__name__ + ': ' + str(error))
    finally:
        report['elapsed_seconds'] = time.monotonic() - started_run
        report['completed_at'] = datetime.now(timezone.utc).isoformat()
        save(output / 'report.json', report)
        print(str(output / 'report.json'))
    return 0 if report['status'] in ('PASS', 'OFFLINE_RENDERED', 'OFFLINE_CAPTURE_MATCH') else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError) as error:
        sys.exit(str(error))
