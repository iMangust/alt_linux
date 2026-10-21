import pty, os, time, select, sys

LOG = '/tmp/pty_test.log'
SCRIPT = sys.argv[1] if len(sys.argv) > 1 else '/workspace/alt_sync.sh'

master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.setsid()
    os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
    os.close(master); os.close(slave)
    env = dict(os.environ, ALT_SYNC_NO_AUTOINSTALL='1')
    inner = "su -c 'ALT_SYNC_NO_AUTOINSTALL=1 bash %s'" % SCRIPT
    os.execve('/bin/bash', ['bash', '-lc', inner], env)
else:
    os.close(slave)
    out = open(LOG, 'wb')
    sent_choice = False
    sent_enter = False
    deadline = time.time() + 40
    buf = b''
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 1.0)
        if r:
            try:
                data = os.read(master, 4096)
            except OSError:
                break
            if not data:
                break
            buf += data
            out.write(data); out.flush()
        if not sent_choice and b'0-9' in buf:
            os.write(master, b'8\n'); sent_choice = True
        elif sent_choice and not sent_enter and b'ENTER' in buf:
            os.write(master, b'\n'); sent_enter = True
            time.sleep(1.5)
            os.write(master, b'0\n')
            break
    time.sleep(1)
    try:
        while True:
            r, _, _ = select.select([master], [], [], 0.5)
            if not r:
                break
            d = os.read(master, 4096)
            if not d:
                break
            buf += d; out.write(d)
    except OSError:
        pass
    out.close()
    try:
        os.kill(pid, 0); os.kill(pid, 15)
    except OSError:
        pass
    st = os.waitpid(pid, 0)
    print('EXIT_STATUS:', st[1])
    txt = buf.decode(errors='replace')
    print('HAS_PASSWORD_PROMPT:', ('Password' in txt or 'password' in txt.lower()))
    print('HAS_MENU:', '0-9' in txt)
    print('HAS_READ_ERROR:', 'Input/output error' in txt or 'ошибка чтения' in txt)
    print('---- TAIL ----')
    print(txt[-1500:])
