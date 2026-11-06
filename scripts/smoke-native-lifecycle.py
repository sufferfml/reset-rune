#!/usr/bin/env python3
"""Exercise only an unoccupied .mock launchd service with synthetic state.

Never targets a live label, real data directory, login, or Codex executable.
Does not change dist. Refuses an existing mock service, listener, or login item.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import time
import traceback

ROOT = Path(__file__).resolve().parents[1]
LABEL = 'local.reset-rune.service.mock'
TARGET = f'gui/{os.getuid()}/{LABEL}'
PORT = 41000 + (os.getuid() % 6000) * 2 + 1
HELPER = ROOT / 'dist/native/arm64/Bottled Reset Rune.app/Contents/Helpers/Bottled Reset Rune Service.app/Contents/MacOS/reset-rune'
RECEIPT = ROOT / '.build/native-lifecycle-verification.json'
LOGIN_PLIST = Path.home() / 'Library/LaunchAgents' / f'{LABEL}.plist'
REPORT = {'checkedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'label': LABEL,
          'port': PORT, 'passed': False, 'steps': [], 'cleanup': {},
          'realLabelsTouched': False, 'realLoginsRead': False, 'distModified': False}
TEMP: Path | None = None
ENV = None


def run(argv, *, timeout=75, check=True, env_override=None):
    result = subprocess.run([str(a) for a in argv], cwd=ROOT, env=ENV if env_override is None else env_override, capture_output=True,
                            text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{Path(str(argv[0])).name} {list(map(str, argv[1:]))}: exit {result.returncode}; {result.stderr.strip()[:1500]}')
    return result


def loaded():
    result = run(['/bin/launchctl', 'print', TARGET], check=False, timeout=8)
    return result.stdout if result.returncode == 0 else None


def listening():
    with socket.socket() as sock:
        sock.settimeout(.3)
        return sock.connect_ex(('127.0.0.1', PORT)) == 0


def assert_free():
    assert loaded() is None, 'Existing .mock launchd service; refusing to touch it.'
    assert not listening(), 'Existing .mock port listener; refusing to touch it.'
    assert not os.path.lexists(LOGIN_PLIST), 'Existing .mock login startup plist; refusing to remove it.'


def cli(*words, timeout=75):
    # Every native administration command carries --mock, with no exception.
    result = run([HELPER, '--mock', *words], timeout=timeout)
    output = result.stdout.strip()
    return json.loads(output) if output.startswith('{') else output


def wait_for(predicate, title, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (FileNotFoundError, json.JSONDecodeError, ConnectionError) as exc:
            last = str(exc)
        time.sleep(.1)
    raise AssertionError(f'Timed out waiting for {title}: {last}')


def private_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(value, file)
        file.flush()
        os.fsync(file.fileno())


def read_state(data):
    return json.loads((data / 'state.json').read_text())


def session_plist(data):
    with (data / f'{LABEL}.plist').open('rb') as file:
        value = plistlib.load(file)
    assert value['Label'] == LABEL
    assert '--mock' in value['ProgramArguments'] or value['ProgramArguments'][-1] == 'mock'
    assert Path(value['WorkingDirectory']).resolve() == data.resolve()
    assert str(TEMP) in value['EnvironmentVariables']['RESET_RUNE_DATA_DIR']
    return value


def record(name, **values):
    REPORT['steps'].append({'name': name, 'passed': True, **values})


def invariant(data, original_key, *, language='zh', appearance='dark'):
    state = read_state(data)
    assert state['version'] == 1
    assert state['config']['enabled'] is True
    assert state['config']['startup'] is False
    assert state['config']['notify'] is False
    assert state['config']['language'] == language
    assert state['config']['appearance'] == appearance
    assert state['config']['lead'] == 30
    assert len(state['operations']) == 1, f'Duplicate operations: {state["operations"]}'
    operation = state['operations'][0]
    assert operation['id'] == 'lifecycle-near'
    assert operation['key'] == original_key and operation['stage'] == 'reset'
    model = json.loads((data / 'sample-inventory.json').read_text())
    assert model['redeemed'] == {original_key: 'lifecycle-near'}
    assert [credit['id'] for credit in model['credits']] == ['lifecycle-far']
    return state


try:
    # No mutations are permitted before all collision guards pass.
    assert PORT == 42003 if os.getuid() == 501 else PORT > 1024
    assert_free()
    assert HELPER.is_file(), 'Packaged helper missing.'
    manifest_path = ROOT / 'dist/native/manifest.json'
    manifest_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
    REPORT['manifestSha256'] = manifest_hash
    helper_hash = hashlib.sha256(HELPER.read_bytes()).hexdigest()
    REPORT['helperSha256'] = helper_hash
    TEMP = Path(tempfile.mkdtemp(prefix='reset-rune-lifecycle-'))
    os.chmod(TEMP, 0o700)
    base = TEMP / 'data'
    data = base / 'simulation'
    data.mkdir(parents=True, mode=0o700)
    os.chmod(base, 0o700)
    empty_codex = TEMP / 'codex-empty'
    empty_codex.mkdir(mode=0o700)
    missing_codex = TEMP / 'codex-must-not-run'
    ENV = dict(os.environ)
    ENV.update({'RESET_RUNE_DATA_DIR': str(base),
                'CODEX_HOME': str(empty_codex), 'RESET_RUNE_CODEX_PATH': str(missing_codex),
                'NO_PROXY': '127.0.0.1,localhost', 'no_proxy': '127.0.0.1,localhost',
                'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'})
    ENV.pop('RESET_RUNE_DEVELOPMENT', None)
    now = int(time.time() * 1000)
    private_json(data / 'sample-inventory.json', {
        'identity': {'accountId': 'lifecycle-synthetic', 'scope': 'lifecycle-scope', 'email': 'demo@example.test'},
        'credits': [{'id': 'lifecycle-near', 'expiresAt': now + 5 * 60_000},
                    {'id': 'lifecycle-far', 'expiresAt': now + 7 * 86_400_000}],
        'remainingPercent': 90, 'redeemed': {}})
    record('collision-guards', noExistingMockService=True, noExistingMockListener=True, noExistingMockStartup=True)

    started = cli('start')
    assert started['mode'] == 'mock' and started['runtime']['native'] is True
    assert started['config']['enabled'] is False
    registration = session_plist(data)
    current_exe = data / 'runtime/current/Contents/MacOS/reset-rune'
    assert registration['ProgramArguments'][0] == str(current_exe)
    assert str(ROOT / 'dist') not in registration['ProgramArguments'][0]
    assert hashlib.sha256(current_exe.read_bytes()).hexdigest() == helper_hash
    record('native-start-stable-path', program=registration['ProgramArguments'][0].replace(str(TEMP), '<temp>'))
    cli('config', 'notify', 'false')
    cli('config', 'language', 'zh')
    cli('config', 'appearance', 'dark')
    cli('config', 'lead', '30')
    enabled = cli('enable')
    assert enabled['config']['enabled'] is True
    state = wait_for(lambda: (s if (s := read_state(data))['operations'] and s['operations'][0]['stage'] == 'reset' else None), 'one confirmed synthetic reset')
    key = state['operations'][0]['key']
    invariant(data, key)
    record('one-synthetic-redemption', id='lifecycle-near', key=key, operationCount=1)

    cli('restart')
    invariant(data, key)
    assert session_plist(data)['ProgramArguments'][0] == str(current_exe)
    record('native-restart', keyRetained=True, operationCount=1)
    cli('upgrade')
    invariant(data, key)
    assert (data / 'runtime/previous/Contents/MacOS/reset-rune').is_file()
    record('native-upgrade', previousPresent=True, journalRetained=True)
    # Settings changed after activation must survive switching to the previous program.
    cli('config', 'language', 'en')
    cli('config', 'appearance', 'light')
    cli('refresh')
    invariant(data, key, language='en', appearance='light')
    cli('rollback')
    invariant(data, key, language='en', appearance='light')
    assert session_plist(data)['ProgramArguments'][0] == str(current_exe)
    record('native-rollback', latestSettingsRetained=True, latestJournalRetained=True, operationCount=1)
    cli('uninstall-service')
    assert loaded() is None and not listening() and not (data / 'runtime').exists()
    invariant(data, key, language='en', appearance='light')
    record('native-uninstall', journalRetained=True, portReleased=True, startupFalse=True)
    assert list(empty_codex.iterdir()) == []
    assert hashlib.sha256(HELPER.read_bytes()).hexdigest() == helper_hash
    assert hashlib.sha256(manifest_path.read_bytes()).hexdigest() == manifest_hash
    record('artifact-integrity', emptyCodexUntouched=True, distUnchanged=True)
    REPORT['passed'] = True
except Exception as error:
    diagnostics = {}
    try:
        diagnostics['mockLaunchd'] = loaded()
        diagnostics['mockListeners'] = run(['/usr/sbin/lsof', '-nP', '-iTCP:' + str(PORT), '-sTCP:LISTEN'], check=False).stdout
        if TEMP is not None:
            sim = TEMP / 'data/simulation'
            if (sim / f'{LABEL}.plist').exists(): diagnostics['sessionPlist'] = session_plist(sim)
            if (sim / 'connection.json').exists():
                discovery = json.loads((sim / 'connection.json').read_text()); discovery.pop('token', None)
                diagnostics['connectionWithoutToken'] = discovery
            if (sim / 'state.json').exists(): diagnostics['syntheticState'] = read_state(sim)
        REPORT['diagnostics'] = diagnostics
    except Exception as diagnostic_error:
        REPORT['diagnosticError'] = str(diagnostic_error)
    REPORT['error'] = {'type': type(error).__name__, 'message': str(error)}
    REPORT['traceback'] = traceback.format_exc()
finally:
    cleanup_errors = []
    if TEMP is not None:
        try:
            registration = loaded()
            if registration is not None:
                if str(TEMP) not in registration:
                    raise RuntimeError('Mock label ownership changed; refusing to stop another service.')
                run(['/bin/launchctl', 'bootout', TARGET], check=False, timeout=60)
                wait_for(lambda: loaded() is None and not listening(), 'owned mock service shutdown', timeout=45)
            assert not listening(), 'Mock port remains occupied; preserving temporary directory.'
            assert not LOGIN_PLIST.exists(), 'Unexpected startup plist; preserving temporary directory.'
            shutil.rmtree(TEMP)
        except Exception as error:
            cleanup_errors.append(str(error))
    REPORT['cleanup'] = {'temporaryRemoved': TEMP is not None and not TEMP.exists(), 'errors': cleanup_errors,
                         'mockServiceUnloaded': loaded() is None, 'mockPortReleased': not listening()}
    if cleanup_errors:
        REPORT['passed'] = False
    RECEIPT.parent.mkdir(exist_ok=True, parents=True)
    RECEIPT.write_text(json.dumps(REPORT, indent=2) + '\n')
print(json.dumps({'passed': REPORT['passed'], 'steps': len(REPORT['steps']), 'receipt': str(RECEIPT),
                  'cleanup': REPORT['cleanup'], **({'error': REPORT['error']} if 'error' in REPORT else {})}, indent=2))
raise SystemExit(0 if REPORT['passed'] else 1)
