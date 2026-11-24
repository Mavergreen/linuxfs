#!/usr/bin/python
# A stand-in keychain keeper for fs-test.sh. usage: kcstub.py SOCKET LOG MODE
#   MODE: none | offered PW | saved PW | hang (accepts, never answers) | stale (binds SOCKET and exits: nothing listens)
# Appends each request to LOG as one line, tabs and newlines turned into spaces ("find disk9", "save disk9 pw").
import os, socket, sys
path, log, mode = sys.argv[1], sys.argv[2], sys.argv[3:]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
if mode[0] == 'stale':
    sys.exit(0)
s.listen(5)
open(path + '.ready', 'w').close()
while True:
    c, _ = s.accept()
    if mode[0] == 'hang':
        continue
    data = ''
    while data.count('\n') < (2 if data.startswith('save\t') else 1):
        d = c.recv(4096)
        if not d:
            break
        data += d
    open(log, 'a').write(data.replace('\t', ' ').replace('\n', ' ').rstrip() + '\n')
    if data.startswith('find\t'):
        c.sendall('none\n' if mode[0] == 'none' else '%s\n%s\n' % (mode[0], mode[1]))
    else:
        c.sendall('ok\n')
    c.close()
