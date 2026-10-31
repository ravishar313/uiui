"""How often does real (reference) text repeat an n-gram (n=3..6) back-to-back k times?  -> picks max_repeats for the guard."""
import sys
from collections import Counter
def maxrun(t, nmin=3, nmax=6):
    best = 1
    for n in range(nmin, nmax + 1):
        i = 0
        while i + 2 * n <= len(t):
            k = 1
            while t[i:i + n] == t[i + k * n:i + (k + 1) * n] and i + (k + 1) * n <= len(t): k += 1
            best = max(best, k); i += 1
    return best
c = Counter(); N = 0
for l in open(sys.argv[1]):
    t = l.split(); N += 1; c[maxrun(t)] += 1
print(N, "sentences; max consecutive copies of a 3-6-gram:", dict(sorted(c.items())))
