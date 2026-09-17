#!/usr/bin/env python3
"""Check the installed app server's MCP recovery using an isolated, ephemeral fixture.

No model request, saved user task, existing tool process, or real browser is used.
Run manually on macOS; this is not part of the portable unit suite.
"""
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time

RESOURCES = Path('/Applications/ChatGPT.app/Contents/Resources')
REPL = RESOURCES / 'cua_node/bin/node_repl'


def verify(wrapped):
    with tempfile.TemporaryDirectory(prefix='canaryd-reconnect-') as directory:
        root = Path(directory)
        config = '[mcp_servers.fixture]\nstartup_timeout_sec = 10\n'
        if wrapped:
            config += 'command = ' + json.dumps(str(RESOURCES / 'cua_node/bin/node')) + '\n'
            config += 'args = [' + json.dumps(str(RESOURCES / 'cua_node/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs')) + ']\n'
            config += '[mcp_servers.fixture.env]\nCUA_REPL_ENABLED_SURFACES = "browser"\n'
            config += 'CUA_REPL_NODE_REPL_PATH = ' + json.dumps(str(REPL)) + '\n'
        else:
            config += 'command = ' + json.dumps(str(REPL)) + '\n'
        (root / 'config.toml').write_text(config)
        environment = dict(os.environ, CODEX_HOME=directory)
        with (root / 'stderr.log').open('w') as errors:
            server = subprocess.Popen(
                [str(RESOURCES / 'codex'), 'app-server'],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors,
                text=True, env=environment, start_new_session=True,
            )
            messages = queue.Queue()

            def read_messages():
                for line in server.stdout:
                    try:
                        messages.put(json.loads(line))
                    except ValueError:
                        pass

            threading.Thread(target=read_messages, daemon=True).start()
            sequence = 0

            def call(method, params):
                nonlocal sequence
                sequence += 1
                server.stdin.write(json.dumps({'id': sequence, 'method': method, 'params': params}) + '\n')
                server.stdin.flush()
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    message = messages.get(timeout=max(.1, deadline - time.monotonic()))
                    if message.get('id') == sequence:
                        if 'error' in message:
                            raise RuntimeError(message['error']['message'])
                        return message['result']
                raise TimeoutError(method)

            try:
                call('initialize', {'clientInfo': {'name': 'canaryd_reconnect_test', 'version': '1'},
                                    'capabilities': {'experimentalApi': True}})
                server.stdin.write('{"method":"initialized"}\n')
                server.stdin.flush()
                thread = call('thread/start', {'ephemeral': True, 'cwd': directory,
                                              'approvalPolicy': 'never', 'sandbox': 'read-only'})['thread']['id']
                status = call('mcpServerStatus/list', {'threadId': thread})
                for _ in range(10):
                    if status['data'][0]['runtimeStatus'] != 'starting':
                        break
                    time.sleep(.2)
                    status = call('mcpServerStatus/list', {'threadId': thread})
                assert status['data'][0]['runtimeStatus'] == 'connected', status['data'][0]['runtimeStatus']
                call('mcpServer/tool/call', {'threadId': thread, 'server': 'fixture',
                                           'tool': 'js_reset', 'arguments': {}})
                rows = [row.split(None, 2) for row in subprocess.check_output(
                    ['ps', '-Ao', 'pid=,ppid=,command='], text=True).splitlines()]
                children = {server.pid}
                for _ in range(4):
                    children.update(int(pid) for pid, parent, _ in rows if int(parent) in children)
                targets = [int(pid) for pid, _, command in rows if int(pid) in children and command == str(REPL)]
                assert len(targets) == 1, targets
                target = targets[0]
                assert not any(int(parent) == target for _, parent, _ in rows), 'fixture has an execution kernel'
                os.kill(target, signal.SIGTERM)
                time.sleep(.5)
                outcomes = []
                for _ in range(2):
                    try:
                        result = call('mcpServer/tool/call', {'threadId': thread, 'server': 'fixture',
                                                           'tool': 'js', 'arguments': {'code': 'console.log(6 * 7)'}})
                        outcomes.append(result)
                    except RuntimeError as error:
                        outcomes.append(str(error))
                print(json.dumps({'fixture': 'cua' if wrapped else 'repl', 'after_stop': outcomes}), flush=True)
            finally:
                # Only the new session/process group owned by this fixture is stopped.
                os.killpg(server.pid, signal.SIGTERM)
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid, signal.SIGKILL)
                    server.wait()


if __name__ == '__main__':
    print(subprocess.check_output([str(RESOURCES / 'codex'), '--version'], text=True).strip())
    verify(False)
    verify(True)
