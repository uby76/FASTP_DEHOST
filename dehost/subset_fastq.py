#!/usr/bin/env python3
import gzip
import sys

source, output, records = sys.argv[1], sys.argv[2], int(sys.argv[3])
with gzip.open(source, "rt") as inp, gzip.open(output, "wt") as out:
    for _ in range(records * 4):
        line = inp.readline()
        if not line:
            break
        out.write(line)

