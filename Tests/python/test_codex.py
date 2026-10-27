import asyncio
import os
from pathlib import Path
import stat
import sys

import pytest

from litecu.codex import CodexModel, diagnostic
from litecu.core import DECISION_SCHEMA


def executable(tmp_path, body):
    path = tmp_path / 'fake-codex'
    path.write_text('#!' + sys.executable + '\n' + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return str(path)


async def test_cli_receives_isolation_flags_and_all_images(tmp_path):
    fake = executable(tmp_path, '''
import sys, pathlib, json
args=sys.argv[1:]
assert '--ignore-user-config' in args and '--ignore-rules' in args
assert args[args.index('--sandbox')+1] == 'read-only'
assert args.count('--image') == 2
assert 'shell_tool' in args and 'computer_use' in args
assert 'mcp_servers={}' in args
assert 'model_reasoning_effort="low"' in args
assert sys.stdin.read() == 'Synthetic input'
schema=json.loads(pathlib.Path(args[args.index('--output-schema')+1]).read_text())
assert schema['additionalProperties'] is False
pathlib.Path(args[args.index('--output-last-message')+1]).write_text('{"kind":"finish","result":"OK"}')
''')
    images=[]
    for number in (1, 2):
        path=tmp_path/f'{number}.png'; path.write_bytes(b'synthetic'); images.append(str(path))
    value=await CodexModel(binary=fake).decide('Synthetic input', images, DECISION_SCHEMA)
    assert value['result'] == 'OK'


async def test_timeout_stops_model_process(tmp_path):
    pidfile=tmp_path/'pid'
    fake=executable(tmp_path, f'import os,time,pathlib\npathlib.Path({str(pidfile)!r}).write_text(str(os.getpid()))\ntime.sleep(10)\n')
    with pytest.raises(TimeoutError):
        await CodexModel(binary=fake, timeout=1).decide('test', [], DECISION_SCHEMA)
    with pytest.raises(ProcessLookupError):
        os.kill(int(pidfile.read_text()), 0)


async def test_cancel_stops_model_process(tmp_path):
    pidfile=tmp_path/'pid'
    fake=executable(tmp_path, f'import os,time,pathlib\npathlib.Path({str(pidfile)!r}).write_text(str(os.getpid()))\ntime.sleep(10)\n')
    model=CodexModel(binary=fake)
    task=asyncio.create_task(model.decide('test', [], DECISION_SCHEMA))
    while not pidfile.exists():
        await asyncio.sleep(.01)
    model.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    with pytest.raises(ProcessLookupError):
        os.kill(int(pidfile.read_text()), 0)


def test_error_does_not_echo_raw_prompt_log():
    assert 'private screenshot' not in diagnostic('startup: private screenshot content', 'gpt-6-sol')
    assert 'capacity' in diagnostic('ERROR: Model capacity exhausted', 'gpt-6-sol')

async def test_fast_exiting_process_cannot_bypass_final_output_limit(tmp_path):
    fake=executable(tmp_path, '''
import pathlib,sys
args=sys.argv[1:]
pathlib.Path(args[args.index('--output-last-message')+1]).write_bytes(b'x'*(1024*1024+1))
''')
    with pytest.raises(RuntimeError, match='size limit'):
        await CodexModel(binary=fake).decide('test', [], DECISION_SCHEMA)

def test_parent_api_credentials_and_agent_settings_are_not_forwarded(monkeypatch):
    from litecu.codex import runtime_environment
    monkeypatch.setenv('OPENAI_API_KEY', 'synthetic-test-not-a-secret')
    monkeypatch.setenv('OPENAI_BASE_URL', 'https://invalid.example')
    monkeypatch.setenv('CODEX_PARENT_SESSION', 'synthetic-session')
    environment=runtime_environment()
    assert 'OPENAI_API_KEY' not in environment
    assert 'OPENAI_BASE_URL' not in environment
    assert 'CODEX_PARENT_SESSION' not in environment
    assert environment.get('HOME') == os.environ.get('HOME')

async def test_cancel_during_spawn_reaps_child(tmp_path, monkeypatch):
    from litecu import codex
    original = asyncio.create_subprocess_exec
    child_ready, release = asyncio.Event(), asyncio.Event()
    children=[]
    async def delayed_spawn(*args, **kwargs):
        child=await original(*args, **kwargs)
        children.append(child)
        child_ready.set()
        await release.wait()
        return child
    monkeypatch.setattr(asyncio, 'create_subprocess_exec', delayed_spawn)
    fake=executable(tmp_path, 'import time\ntime.sleep(10)\n')
    task=asyncio.create_task(CodexModel(binary=fake).decide('test', [], DECISION_SCHEMA))
    await child_ready.wait()
    task.cancel()
    release.set()
    with pytest.raises(asyncio.CancelledError): await task
    assert children[0].returncode is not None
