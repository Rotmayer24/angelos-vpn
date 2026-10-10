"""Checks probe.py's argument handling and the deadline, without depending on the network."""
import importlib.util, importlib.machinery, os, subprocess, sys, time, io, contextlib

here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, os.pardir, 'probe.py')
spec = importlib.util.spec_from_loader('probe', importlib.machinery.SourceFileLoader('probe', path))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

fails = []
def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)

print("1) a broken port is skipped, never guessed as 443")
got = m.parse_targets(["0", "a.example", "notaport", "1", "b.example", "443", "2", "c.example", "0", "3", "d.example", "70000"])
print("   targets:", got)
check([t[0] for t in got] == ["1"], "the malformed entries are dropped, valid ones kept")
check(not any(t[1] == "a.example" for t in got), "no host silently got port 443")

print("2) out-of-range ports are rejected")
check(m.parse_targets(["0", "h", "0", "1", "h", "65536"]) == [], "port 0 and 65536 rejected")

print("3) an incomplete trailing triple is ignored (this used to run off the end)")
check(len(m.parse_targets(["0", "a", "443", "1", "b"])) == 1, "dangling index/host pair ignored")
check(len(m.parse_targets(["0", "a"])) == 0, "a single pair ignored")

print("4) empty input is not an error")
sys.argv = ['probe.py', '1']
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = m.main()
check(rc == 0, "returns 0 with no targets")

print("5) a normal run answers every target")
m.probe = lambda host, port, timeout: 42
sys.argv = ['probe.py', '1'] + [x for i in range(50) for x in (str(i), "h%d" % i, "443")]
out = io.StringIO()
t0 = time.perf_counter()
with contextlib.redirect_stdout(out):
    m.main()
elapsed = time.perf_counter() - t0
lines = out.getvalue().strip().splitlines()
check(len(lines) == 50, "all 50 answered")
check(all(l.endswith("42") for l in lines), "with the stub's value")
check(elapsed < 3, "finished quickly (%.2fs)" % elapsed)

print("6) the deadline cuts off probes that hang (separate process: it calls os._exit)")
t0 = time.perf_counter()
p = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'probe_deadline.py')],
                   capture_output=True, text=True, timeout=90)
elapsed = time.perf_counter() - t0
out = p.stdout.strip()
print("   elapsed %.1fs, exit %s" % (elapsed, p.returncode))
print("   %s" % (out.replace("\n", " | ")[:120] or "(no output)"))
check(elapsed < 30, "returned on the deadline, not after 120s of hanging probes (took %.1fs)" % elapsed)
check("UNREACHABLE" not in out, "it returned rather than falling through")
check(len(out.strip().splitlines()) == 300, "every target got a line, so the UI never waits")

print()
print("FAILURES: %d" % len(fails))
sys.exit(1 if fails else 0)