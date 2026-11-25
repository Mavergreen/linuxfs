#!/usr/bin/env python
# platform: host-agnostic -- Python 2.7 (the 10.9 guest's /usr/bin/python) and Python 3, standard library only
#   usage: fisher.py A B C D
#          Prints the two-sided Fisher's exact p for the 2x2 table [[A, B], [C, D]] to 4 places: the sum of the
#          probabilities of every table with the same margins that is no likelier than this one. census_stall's
#          decision rule (spec item 3): the stall counts differ when p < 0.05.
import sys


def comb(n, k):
    if k < 0 or k > n:
        return 0
    k = min(k, n - k)
    c = 1
    for i in range(1, k + 1):
        c = c * (n - k + i) // i
    return c


def fisher(a, b, c, d):
    row1, col1, n = a + b, a + c, a + b + c + d
    total = comb(n, col1)
    # exact integer weights: P(x) = comb(row1, x) * comb(n - row1, col1 - x) / total
    weight = lambda x: comb(row1, x) * comb(n - row1, col1 - x)
    seen = weight(a)
    lo, hi = max(0, col1 - (n - row1)), min(row1, col1)
    # the weights are exact integers, so "no likelier" needs none of the tolerance floating point would
    tail = sum(weight(x) for x in range(lo, hi + 1) if weight(x) <= seen)
    return float(tail) / total


def main(argv):
    if len(argv) != 5:
        sys.stderr.write("usage: fisher.py A B C D\n")
        return 2
    try:
        cells = [int(x) for x in argv[1:]]
    except ValueError:
        cells = [-1]
    if min(cells) < 0:
        sys.stderr.write("fisher.py: the four counts are whole numbers, 0 or more\n")
        return 2
    sys.stdout.write("%.4f\n" % fisher(*cells))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
