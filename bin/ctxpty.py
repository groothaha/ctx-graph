#!/usr/bin/env python3
"""ctxpty — CtxGraph 앱 터미널의 대화를 앱 밖에서 살려 두는 작은 pty 보관자 (dtach 와 비슷, 표준 라이브러리만).

앱의 터미널 탭은 Claude 를 직접 띄우지 않고 이 스크립트의 `open` 을 띄운다.
  open  : 보관자(holder)가 없으면 만들고(그 안에서 Claude 실행), 있으면 다시 붙는다. 앱 터미널 ↔ 보관자 중계.
  kill  : 보관자 안의 Claude 를 끝낸다 (앱에서 탭을 닫을 때만).
  probe : 살아 있는지 (exit 0/1) + 메타 JSON.
  list  : 폴더 안의 살아 있는 보관자 목록 JSON.
  info  : 보관자마다 지금 폴더·git 브랜치·열린 포트·하위 프로세스 수 JSON (앱의 세로 탭 정보).
앱이 꺼지면 중계(open)만 죽고 보관자와 Claude 는 계속 돈다. 다시 붙으면 최근 출력(최대 BUF_MAX)을
다시 그려 화면을 되살린다.

소켓 프레임: [종류 1바이트][길이 4바이트 BE][내용]
  클라이언트→보관자: A(붙기: rows,cols) I(입력) W(크기) K(끝내기) P(상태)
  보관자→클라이언트: R(다시 그리기) O(출력) X(종료 코드) D(다른 곳에서 붙어서 떨어짐) S(상태 JSON)
"""
import argparse
import errno
import fcntl
import json
import os
import re
import selectors
import signal
import socket
import struct
import subprocess
import sys
import termios
import time
import tty

BUF_MAX = 4 * 1024 * 1024          # 다시 그리기용으로 들고 있는 최근 출력
HIGH = 4 * 1024 * 1024             # 대기열이 이보다 크면 읽기를 잠시 멈춤 (역압)
LINGER = 15.0                      # Claude 가 끝났는데 붙은 앱이 없으면 이만큼 기다렸다가 사라짐
HDR = struct.Struct(">cI")
READ, WRITE = selectors.EVENT_READ, selectors.EVENT_WRITE

DEC_MODE = re.compile(rb"\x1b\[\?([0-9;]+)([hl])")
KITTY = re.compile(rb"\x1b\[[<>=][0-9;]*u")
MOK = re.compile(rb"\x1b\[>4(?:;[0-9]*)?m")
ALT_SCREEN = ("47", "1047", "1049")


def frame(kind: bytes, payload: bytes = b"") -> bytes:
    return HDR.pack(kind, len(payload)) + payload


class Frames:
    def __init__(self):
        self.buf = bytearray()

    def feed(self, data: bytes):
        self.buf += data
        out = []
        while len(self.buf) >= HDR.size:
            kind, n = HDR.unpack_from(self.buf)
            if len(self.buf) < HDR.size + n:
                break
            out.append((kind, bytes(self.buf[HDR.size:HDR.size + n])))
            del self.buf[:HDR.size + n]
        return out


def winsize(fd):
    try:
        rows, cols, xp, yp = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))
        if rows and cols:
            return rows, cols
    except OSError:
        pass
    return 40, 100


def set_winsize(fd, rows, cols):
    try:
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    except OSError:
        pass


def connect(path, timeout=2.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
    except OSError:
        s.close()
        return None
    return s


def log(msg):
    sys.stderr.write(time.strftime("%m-%d %H:%M:%S ") + msg + "\n")
    sys.stderr.flush()


class Loop:
    """selectors 위의 아주 작은 이벤트 루프: fd 마다 관심 이벤트를 매번 다시 계산한다."""

    def __init__(self):
        self.sel = selectors.DefaultSelector()

    def want(self, f, events, tag):
        try:
            key = self.sel.get_key(f)
        except (KeyError, ValueError):
            key = None
        if not events:
            if key:
                self.sel.unregister(f)
        elif key is None:
            self.sel.register(f, events, tag)
        elif key.events != events or key.data != tag:
            self.sel.modify(f, events, tag)

    def drop(self, f):
        try:
            self.sel.unregister(f)
        except (KeyError, ValueError):
            pass


# ───────────────────────── 보관자 ─────────────────────────

class Conn:
    def __init__(self, sock):
        self.sock = sock
        self.frames = Frames()
        self.out = bytearray()
        self.closing = False       # out 을 다 보내면 닫기


class Holder:
    def __init__(self, path, meta, rows, cols, argv):
        self.path = path
        self.meta = meta
        self.buf = bytearray()
        self.trim_modes = {}       # 잘라낸 부분 끝에서의 DEC 모드 상태
        self.trim_kitty = []       # 잘라낸 부분의 키보드 프로토콜 시퀀스 (순서대로)
        self.trim_mok = b""
        self.to_child = bytearray()
        self.conns = {}
        self.attached = None
        self.status = None         # Claude 종료 코드
        self.master_eof = False
        self.ended_at = None
        self.kill_at = None
        self.killer = None         # 탭 닫기(K)를 보낸 연결 — 끝나면 닫아서 알려 준다
        self.delivered = False     # 붙은 앱에 종료 코드를 보냈는지
        self.loop = Loop()

        self.lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        self.lsock.bind(path)
        os.chmod(path, 0o600)
        self.lsock.listen(8)
        self.lsock.setblocking(False)
        self.ino = os.stat(path).st_ino

        master, slave = os.openpty()
        set_winsize(slave, rows, cols)
        pid = os.fork()
        if pid == 0:
            try:
                os.close(master)
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                if slave > 2:
                    os.close(slave)
                # 파이썬이 무시하도록 바꿔 둔 신호를 원래대로 (Claude·셸이 평소처럼 동작하게)
                for s in (signal.SIGPIPE, signal.SIGXFSZ, signal.SIGHUP, signal.SIGINT,
                          signal.SIGTERM, signal.SIGQUIT, signal.SIGCHLD, signal.SIGWINCH):
                    signal.signal(s, signal.SIG_DFL)
                os.execvp(argv[0], argv)
            except BaseException as e:  # noqa: BLE001
                os.write(2, f"ctxpty: {argv[0]} 실행 실패: {e}\r\n".encode())
            os._exit(127)
        os.close(slave)
        os.set_blocking(master, False)
        self.master = master
        self.pid = pid
        self.meta.update(pid=os.getpid(), child=pid, started=time.time())

    # 다시 그리기: 잘라낸 지점의 모드 상태 + 남은 출력
    def replay(self) -> bytes:
        pre = bytearray()
        alt = [m for m in ALT_SCREEN if self.trim_modes.get(m) == b"h"]
        for m in alt[-1:]:
            pre += b"\x1b[?" + m.encode() + b"h"
        for m, v in self.trim_modes.items():
            if m not in ALT_SCREEN:
                pre += b"\x1b[?" + m.encode() + v
        pre += self.trim_mok
        for k in self.trim_kitty:
            pre += k
        return bytes(pre) + bytes(self.buf)

    def keep(self, data: bytes):
        self.buf += data
        if len(self.buf) <= BUF_MAX + 256 * 1024:
            return
        cut = len(self.buf) - BUF_MAX
        nl = self.buf.find(b"\n", cut)
        cut = nl + 1 if 0 <= nl < cut + 64 * 1024 else cut
        gone = bytes(self.buf[:cut])
        del self.buf[:cut]
        for m in DEC_MODE.finditer(gone):
            for n in m.group(1).split(b";"):
                if n:
                    self.trim_modes[n.decode()] = m.group(2)
        for m in KITTY.finditer(gone):
            self.trim_kitty.append(m.group(0))
        self.trim_kitty = self.trim_kitty[-32:]
        mok = MOK.findall(gone)
        if mok:
            self.trim_mok = mok[-1]

    def send(self, c: Conn, data: bytes):
        c.out += data

    def close(self, c: Conn):
        self.loop.drop(c.sock)
        try:
            c.sock.close()
        except OSError:
            pass
        self.conns.pop(c.sock, None)
        if self.attached is c:
            self.attached = None

    def on_frame(self, c: Conn, kind: bytes, p: bytes):
        if kind == b"A":
            if self.attached and self.attached is not c:
                old = self.attached
                self.send(old, frame(b"D"))
                old.closing = True
            self.attached = c
            if len(p) >= 4:
                rows, cols = struct.unpack(">HH", p[:4])
                set_winsize(self.master, rows, cols)
            self.send(c, frame(b"R", self.replay()))
            if self.status is not None:
                self.send(c, frame(b"X", struct.pack(">i", self.status)))
                c.closing = True
                self.delivered = True
        elif kind == b"I":
            if c is self.attached and self.status is None:
                self.to_child += p
        elif kind == b"W":
            if c is self.attached and len(p) >= 4:
                rows, cols = struct.unpack(">HH", p[:4])
                set_winsize(self.master, rows, cols)
        elif kind == b"K":
            if self.status is None and self.kill_at is None:
                # 셸은 터미널 창을 닫을 때처럼 SIGHUP (셸이 자기 작업들에도 HUP 를 보냄), Claude 는 SIGTERM
                sig = signal.SIGHUP if self.meta.get("kind") == "shell" else signal.SIGTERM
                try:
                    os.kill(self.pid, sig)
                except ProcessLookupError:
                    pass
                self.kill_at = time.time() + 4
            self.killer = c
        elif kind == b"P":
            info = dict(self.meta, attached=self.attached is not None, alive=self.status is None)
            self.send(c, frame(b"S", json.dumps(info).encode()))
            c.closing = True

    def reap(self):
        if self.status is not None:
            return
        try:
            pid, st = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            pid, st = self.pid, 0
        if pid == 0:
            return
        self.status = os.waitstatus_to_exitcode(st) if hasattr(os, "waitstatus_to_exitcode") else (st >> 8)
        self.ended_at = time.time()
        # 남은 출력 마저 읽기
        while not self.master_eof:
            try:
                d = os.read(self.master, 65536)
            except BlockingIOError:
                break
            except OSError:
                d = b""
            if not d:
                self.master_eof = True
                break
            self.keep(d)
            if self.attached:
                self.send(self.attached, frame(b"O", d))
        for c in list(self.conns.values()):
            if c is self.attached:
                self.send(c, frame(b"X", struct.pack(">i", self.status)))
                self.delivered = True
            c.closing = True

    def run(self):
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        lp = self.loop
        while True:
            self.reap()
            if self.kill_at and self.status is None and time.time() > self.kill_at:
                try:
                    os.killpg(self.pid, signal.SIGKILL)
                except OSError:
                    pass
                self.kill_at = time.time() + 2
            if self.status is not None and not any(c.out for c in self.conns.values()):
                # 종료 코드를 앱에 전했거나, 탭을 닫아서 끝난 거면 바로 사라진다.
                # 붙은 앱이 없을 때 끝났으면 잠깐 기다려 준다 (곧 다시 붙으면 마지막 화면·종료 코드를 보여 주게)
                if self.delivered or self.killer is not None or time.time() - self.ended_at > LINGER:
                    break

            # 관심 이벤트
            att_full = self.attached is not None and len(self.attached.out) > HIGH
            if self.master_eof or self.status is not None:
                lp.drop(self.master)
            else:
                ev = (0 if att_full else READ) | (WRITE if self.to_child else 0)
                lp.want(self.master, ev, "master")
            lp.want(self.lsock, READ, "listen")
            for c in list(self.conns.values()):
                ev = (READ if len(self.to_child) < HIGH and not c.closing else 0) | (WRITE if c.out else 0)
                if c.closing and not c.out:
                    self.close(c)
                    continue
                lp.want(c.sock, ev, c)

            for key, ev in lp.sel.select(0.25):
                tag = key.data
                if tag == "listen":
                    try:
                        s, _ = self.lsock.accept()
                    except OSError:
                        continue
                    s.setblocking(False)
                    self.conns[s] = Conn(s)
                elif tag == "master":
                    if ev & READ:
                        try:
                            d = os.read(self.master, 65536)
                        except BlockingIOError:
                            d = None
                        except OSError:
                            d = b""
                        if d == b"":
                            self.master_eof = True
                        elif d:
                            self.keep(d)
                            if self.attached:
                                self.send(self.attached, frame(b"O", d))
                    if ev & WRITE and self.to_child:
                        try:
                            n = os.write(self.master, self.to_child)
                            del self.to_child[:n]
                        except BlockingIOError:
                            pass
                        except OSError:
                            self.to_child.clear()
                else:
                    c = tag
                    if c.sock not in self.conns:
                        continue
                    if ev & READ:
                        try:
                            d = c.sock.recv(65536)
                        except BlockingIOError:
                            d = None
                        except OSError:
                            d = b""
                        if d == b"":
                            self.close(c)
                            continue
                        if d:
                            for kind, p in c.frames.feed(d):
                                self.on_frame(c, kind, p)
                    if ev & WRITE and c.out:
                        try:
                            n = c.sock.send(c.out)
                            del c.out[:n]
                        except BlockingIOError:
                            pass
                        except OSError:
                            self.close(c)

            # 소켓 파일이 지워졌으면 다시 만든다 (임시 폴더 청소 등)
            if int(time.time()) % 30 == 0:
                try:
                    if os.stat(self.path).st_ino != self.ino:
                        raise FileNotFoundError
                except FileNotFoundError:
                    self.rebind()

        for c in list(self.conns.values()):
            self.close(c)
        try:
            if os.stat(self.path).st_ino == self.ino:
                os.unlink(self.path)
        except OSError:
            pass

    def rebind(self):
        try:
            self.loop.drop(self.lsock)
            self.lsock.close()
            self.lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass
            self.lsock.bind(self.path)
            os.chmod(self.path, 0o600)
            self.lsock.listen(8)
            self.lsock.setblocking(False)
            self.ino = os.stat(self.path).st_ino
            log(f"소켓 다시 만듦 {self.path}")
        except OSError as e:
            log(f"소켓 다시 만들기 실패: {e}")


def cmd_hold(a):
    # 두 번 fork 해서 세션 리더가 아닌 데몬으로 (start_new_session 으로 이미 새 세션)
    if os.fork() > 0:
        os._exit(0)
    meta = json.loads(a.meta or "{}")
    try:
        h = Holder(a.sock, meta, a.rows, a.cols, a.cmd)
    except Exception as e:  # noqa: BLE001
        log(f"보관자 시작 실패 {a.sock}: {e}")
        os._exit(1)
    try:
        h.run()
    except Exception as e:  # noqa: BLE001
        log(f"보관자 오류 {a.sock}: {e!r}")
        try:
            os.kill(h.pid, signal.SIGTERM)
        except OSError:
            pass
    os._exit(0)


# ───────────────────────── 클라이언트 (앱 터미널 안에서 돈다) ─────────────────────────

def spawn_holder(a, rows, cols):
    sockdir = os.path.dirname(a.sock)
    logf = open(os.path.join(sockdir, "ctxpty.log"), "ab")
    p = subprocess.Popen(
        [sys.executable, "-I", os.path.abspath(__file__), "_hold", "--sock", a.sock,
         "--meta", a.meta or "{}", "--rows", str(rows), "--cols", str(cols), "--"] + a.cmd,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=logf,
        start_new_session=True, close_fds=True)
    logf.close()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def cmd_open(a):
    os.makedirs(os.path.dirname(a.sock), mode=0o700, exist_ok=True)
    fresh = False
    conn = connect(a.sock)
    if conn is None:
        if a.attach_only:
            return 3
        lockf = open(a.sock + ".lock", "a")
        try:
            fcntl.flock(lockf, fcntl.LOCK_EX)
            conn = connect(a.sock)
            if conn is None:
                rows, cols = winsize(0)
                spawn_holder(a, rows, cols)
                deadline = time.time() + 8
                while conn is None and time.time() < deadline:
                    time.sleep(0.03)
                    conn = connect(a.sock)
                fresh = True
        finally:
            fcntl.flock(lockf, fcntl.LOCK_UN)
            lockf.close()
        if conn is None:
            sys.stderr.write("ctxpty: 터미널 보관자를 시작하지 못했어요\r\n")
            return 1
    else:
        time.sleep(0.12)   # 앱이 터미널 크기를 막 맞추는 중일 수 있어 잠깐 기다렸다가 다시 그린다
    return relay(conn, fresh)


def relay(conn, fresh):
    conn.setblocking(False)
    old = None
    if os.isatty(0):
        try:
            old = termios.tcgetattr(0)
            tty.setraw(0)
        except termios.error:
            old = None
    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_r, False)
    os.set_blocking(wake_w, False)

    def on_winch(*_):
        try:
            os.write(wake_w, b"w")
        except OSError:
            pass

    signal.signal(signal.SIGWINCH, on_winch)
    os.set_blocking(0, False)
    os.set_blocking(1, False)

    lp = Loop()
    frames = Frames()
    to_holder = bytearray(frame(b"A", struct.pack(">HH", *winsize(0))))
    to_term = bytearray()
    dropping = False
    drop_until = 0.0
    held = bytearray()
    stdin_eof = False
    code = 1
    trace = open(os.environ["CTXPTY_TRACE"], "ab") if os.environ.get("CTXPTY_TRACE") else None   # 진단용: 터미널에 쓴 바이트
    try:
        while True:
            if dropping and time.time() > drop_until:
                dropping = False
                held.clear()
            lp.want(conn, (READ if len(to_term) < HIGH else 0) | (WRITE if to_holder else 0), "conn")
            lp.want(0, 0 if stdin_eof or len(to_holder) > HIGH else READ, "in")
            lp.want(1, WRITE if to_term else 0, "out")
            lp.want(wake_r, READ, "wake")
            done = False
            for key, ev in lp.sel.select(0.5):
                tag = key.data
                if tag == "conn":
                    if ev & READ:
                        try:
                            d = conn.recv(262144)
                        except BlockingIOError:
                            d = None
                        except OSError:
                            d = b""
                        if d == b"":
                            done = True
                            break
                        for kind, p in frames.feed(d or b""):
                            if kind == b"R":
                                to_term += p
                                if p and not fresh:
                                    # 다시 그린 출력 속 질의(색·커서 위치 등)에 터미널이 다시 답하면
                                    # Claude 에 키 입력처럼 들어간다 → 표식(DSR 5) 답이 올 때까지 입력을 버린다
                                    to_term += b"\x1b[5n"
                                    dropping = True
                                    drop_until = time.time() + 3
                            elif kind == b"O":
                                to_term += p
                            elif kind == b"X":
                                code = struct.unpack(">i", p)[0] if len(p) >= 4 else 0
                            elif kind == b"D":
                                code = 4
                    if ev & WRITE and to_holder:
                        try:
                            n = conn.send(to_holder)
                            del to_holder[:n]
                        except BlockingIOError:
                            pass
                        except OSError:
                            done = True
                            break
                elif tag == "in":
                    try:
                        d = os.read(0, 65536)
                    except BlockingIOError:
                        continue
                    except OSError:
                        d = b""
                    if not d:
                        stdin_eof = True
                        done = True      # 앱 터미널이 닫힘 → 떨어지기 (보관자는 계속)
                        break
                    if dropping:
                        held += d
                        i = held.find(b"\x1b[0n")
                        if i < 0:
                            del held[:-3]
                            continue
                        d = bytes(held[i + 4:])
                        held.clear()
                        dropping = False
                        if not d:
                            continue
                    to_holder += frame(b"I", d)
                elif tag == "out":
                    try:
                        n = os.write(1, to_term[:65536])
                        if trace:
                            trace.write(to_term[:n])
                            trace.flush()
                        del to_term[:n]
                    except BlockingIOError:
                        pass
                    except OSError:
                        done = True
                        break
                elif tag == "wake":
                    try:
                        os.read(wake_r, 64)
                    except OSError:
                        pass
                    to_holder += frame(b"W", struct.pack(">HH", *winsize(0)))
            if done:
                break
        # 남은 출력은 터미널에 마저 쓴다
        if not stdin_eof:
            os.set_blocking(1, True)
            try:
                while to_term:
                    n = os.write(1, to_term)
                    del to_term[:n]
            except OSError:
                pass
    finally:
        if old is not None:
            try:
                os.set_blocking(0, True)
                termios.tcsetattr(0, termios.TCSAFLUSH, old)
            except (termios.error, OSError):
                pass
        conn.close()
    return code


# ───────────────────────── 관리 명령 ─────────────────────────

def ask(path, kind, wait=3.0):
    s = connect(path)
    if s is None:
        return None
    try:
        s.settimeout(wait)
        s.sendall(frame(kind))
        fr = Frames()
        while True:
            d = s.recv(65536)
            if not d:
                return b""
            for k, p in fr.feed(d):
                if k == b"S":
                    return p
    except OSError:
        return b""
    finally:
        s.close()


def cmd_probe(a):
    r = ask(a.sock, b"P")
    if not r:
        return 1
    print(r.decode())
    return 0


def cmd_kill(a):
    s = connect(a.sock)
    if s is None:
        return 0
    try:
        s.settimeout(10)
        s.sendall(frame(b"K"))
        while s.recv(65536):
            pass
    except OSError:
        pass
    finally:
        s.close()
    return 0


def cmd_list(a):
    out = []
    try:
        names = sorted(os.listdir(a.dir))
    except FileNotFoundError:
        names = []
    for n in names:
        if n.endswith(".sock.lock") and n[:-5] not in names:
            try:   # 끝난 대화의 잠금 파일 정리
                p = os.path.join(a.dir, n)
                if time.time() - os.lstat(p).st_mtime > 60:
                    os.unlink(p)
            except OSError:
                pass
            continue
        if not n.endswith(".sock"):
            continue
        p = os.path.join(a.dir, n)
        r = ask(p, b"P", 2.0)
        if r:
            try:
                info = json.loads(r)
                info["sock"] = p
                out.append(info)
            except ValueError:
                pass
        elif r is None:
            try:   # 주인 없는 소켓 파일 정리 (막 만들어지는 중일 수 있으니 오래된 것만)
                if time.time() - os.lstat(p).st_mtime > 30:
                    os.unlink(p)
            except OSError:
                pass
    print(json.dumps(out, ensure_ascii=False))
    return 0


def git_branch(d):
    """d 에서 위로 올라가며 .git 을 찾아 현재 브랜치 (분리된 HEAD 면 커밋 앞 7자리)"""
    try:
        d = os.path.realpath(d)
    except OSError:
        return None
    while True:
        g = os.path.join(d, ".git")
        head = None
        if os.path.isdir(g):
            head = os.path.join(g, "HEAD")
        elif os.path.isfile(g):
            try:
                ref = open(g).read().strip()
                if ref.startswith("gitdir:"):
                    gd = ref[7:].strip()
                    head = os.path.join(gd if os.path.isabs(gd) else os.path.join(d, gd), "HEAD")
            except OSError:
                pass
        if head:
            try:
                h = open(head).read().strip()
            except OSError:
                return None
            return h[16:] if h.startswith("ref: refs/heads/") else (h[5:] if h.startswith("ref: ") else h[:7])
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def _run(args, timeout=4):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def cmd_info(a):
    """탭(보관자)마다 지금 폴더·git 브랜치·열린 포트·하위 프로세스 수 (cmux 의 세로 탭 정보처럼)"""
    holders = []
    try:
        names = sorted(os.listdir(a.dir))
    except FileNotFoundError:
        names = []
    for n in names:
        if n.endswith(".sock"):
            r = ask(os.path.join(a.dir, n), b"P", 1.5)
            if r:
                try:
                    holders.append(json.loads(r))
                except ValueError:
                    pass
    kids = {}
    for line in _run(["/bin/ps", "-axo", "pid=,ppid="]).splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            kids.setdefault(int(parts[1]), []).append(int(parts[0]))
    trees = {}
    for h in holders:
        root = h.get("child")
        if not isinstance(root, int):
            continue
        seen, stack = [], list(kids.get(root, []))
        while stack:
            p = stack.pop()
            seen.append(p)
            stack.extend(kids.get(p, []))
        trees[root] = seen
    allp = [p for r, ps in trees.items() for p in [r] + ps]
    ports = {}
    cwds = {}
    if allp:
        pid = None
        for line in _run(["/usr/sbin/lsof", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-Fpn",
                          "-p", ",".join(map(str, allp))]).splitlines():
            if line.startswith("p"):
                pid = int(line[1:]) if line[1:].isdigit() else None
            elif line.startswith("n") and pid is not None:
                port = line.rsplit(":", 1)[-1]
                if port.isdigit():
                    ports.setdefault(pid, set()).add(int(port))
        pid = None
        for line in _run(["/usr/sbin/lsof", "-a", "-d", "cwd", "-Fpn",
                          "-p", ",".join(map(str, trees.keys()))]).splitlines():
            if line.startswith("p"):
                pid = int(line[1:]) if line[1:].isdigit() else None
            elif line.startswith("n") and pid is not None:
                cwds[pid] = line[1:]
    out = []
    for h in holders:
        root = h.get("child")
        if not isinstance(root, int) or root not in trees:
            continue
        cwd = cwds.get(root) or h.get("cwd")
        ps = set()
        for p in [root] + trees[root]:
            ps |= ports.get(p, set())
        out.append({"session": h.get("session"), "cwd": cwd, "branch": git_branch(cwd) if cwd else None,
                    "ports": sorted(ps), "procs": len(trees[root])})
    print(json.dumps(out, ensure_ascii=False))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="ctxpty")
    sub = ap.add_subparsers(dest="cmd_name", required=True)

    p = sub.add_parser("open")
    p.add_argument("--sock", required=True)
    p.add_argument("--meta", default="{}")
    p.add_argument("--attach-only", action="store_true")
    p.add_argument("cmd", nargs=argparse.REMAINDER)

    p = sub.add_parser("_hold")
    p.add_argument("--sock", required=True)
    p.add_argument("--meta", default="{}")
    p.add_argument("--rows", type=int, default=40)
    p.add_argument("--cols", type=int, default=100)
    p.add_argument("cmd", nargs=argparse.REMAINDER)

    for name in ("probe", "kill"):
        p = sub.add_parser(name)
        p.add_argument("--sock", required=True)

    for name in ("list", "info"):
        p = sub.add_parser(name)
        p.add_argument("--dir", required=True)

    a = ap.parse_args(argv)
    if hasattr(a, "cmd") and a.cmd and a.cmd[0] == "--":
        a.cmd = a.cmd[1:]
    if a.cmd_name in ("open", "_hold") and not a.cmd and not getattr(a, "attach_only", False):
        ap.error("실행할 명령이 없음 (-- 뒤에)")
    return {"open": cmd_open, "_hold": cmd_hold, "probe": cmd_probe,
            "kill": cmd_kill, "list": cmd_list, "info": cmd_info}[a.cmd_name](a)


if __name__ == "__main__":
    sys.exit(main())
