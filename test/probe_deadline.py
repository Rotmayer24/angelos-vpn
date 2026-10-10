"""Run as a subprocess: proves the deadline actually cuts a probe short.

probe() is stubbed to hang, so this cannot pass by accident on a fast machine.
Kept separate from the other checks because the code under test calls os._exit() on the
deadline path, which would take the whole test process with it.
"""
import importlib.util, importlib.machinery, sys, time

path = '/home/sugarjora/.config/angelos/plugins/vpn/probe.py'
spec = importlib.util.spec_from_loader('probe', importlib.machinery.SourceFileLoader('probe', path))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

HANG = 120          # each fake probe would take two minutes
m.probe = lambda host, port, timeout: (time.sleep(HANG), -1)[1]

n = 300
sys.argv = ['probe.py', '5'] + [x for i in range(n) for x in (str(i), "h%d" % i, "443")]
t0 = time.perf_counter()
m.main()
print("UNREACHABLE: the run did not return")