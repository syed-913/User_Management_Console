# E-06 · Disk full at every possible moment of a commit

| | |
|---|---|
| **Claim** | When the filesystem fills up at any point of a transaction, UMC stops with a clear message and the account files are left exactly as they were (or, if the commit finished, exactly as intended) - never half-written. |
| **Method** | The sandbox lives on a 3 MB tmpfs. For every amount of free space from 0 to 200 KB (in 4 KB steps) the disk is filled to that point and "umc user create" is attempted; the outcome and the state of the files are checked each time. |
| **Environment** | Debian GNU/Linux 12 (bookworm) · bash 5.2.15 · flock from util-linux 2.38.1 · 12 CPU(s) · UMC `41699b1` · 2026-09-30 |
| **Reproduce** | `UMC_POC_DISTRO=debian12 poc/run.sh E-06` |
| **Verdict** | ✅ PASS |

## Output

```text
free(KB)   exit   outcome
0          1      refused, files unchanged: cannot create /sb/umc-sb
4          1      refused, files unchanged: cannot create /sb/umc-sb
8          1      refused, files unchanged: cannot create /sb/umc-sb
12         1      refused, files unchanged: cannot create /sb/umc-sb
16         1      refused, files unchanged: cannot stage /sb/umc-sb
20         1      refused, files unchanged: cannot stage /sb/umc-sb
24         1      refused, files unchanged: cannot write the staged copy of /sb/umc-sb
28         1      refused, files unchanged: cannot write the staged copy of GR (disk full?)
32         1      refused, files unchanged: cannot write the staged copy of GS (disk full?)
36         1      refused, files unchanged: cannot write the staged copy of SP (disk full?)
40         1      refused, files unchanged: cannot write the staged copy of PW (disk full?)
44         1      refused, files unchanged: cannot journal /sb/umc-sb
48         1      refused, files unchanged: cannot journal /sb/umc-sb
52         1      refused, files unchanged: cannot journal /sb/umc-sb
56         1      refused, files unchanged: cannot journal /sb/umc-sb
60         1      refused, files unchanged: cannot journal /sb/umc-sb
64         1      refused, files unchanged: cannot journal /sb/umc-sb
68         1      refused, files unchanged: cannot journal /sb/umc-sb
72         1      refused, files unchanged: cannot journal /sb/umc-sb
76         1      refused, files unchanged: cannot journal /sb/umc-sb
80         1      refused, files unchanged: cannot journal /sb/umc-sb
84         1      refused, files unchanged: cannot journal /sb/umc-sb
88         1      refused, files unchanged: cannot journal /sb/umc-sb
92         1      refused, files unchanged: cannot journal /sb/umc-sb
96         1      refused, files unchanged: cannot journal /sb/umc-sb
100        1      refused, files unchanged: cannot checksum journal /sb/umc-sb
104        1      refused, files unchanged: cannot write journal /sb/umc-sb
108        1      refused, files unchanged: cannot write journal /sb/umc-sb
112        1      refused, files unchanged: cannot write journal /sb/umc-sb
116        1      refused, files unchanged: cannot write journal /sb/umc-sb
120        8      refused, files unchanged: could not install /sb/umc-sb
124        8      refused, files unchanged: could not install /sb/umc-sb
128        8      refused, files unchanged: could not install /sb/umc-sb
132        8      refused, files unchanged: could not install /sb/umc-sb
136        8      refused, files unchanged: could not install /sb/umc-sb
140        8      refused, files unchanged: could not install /sb/umc-sb
144        0      created
148        0      created
152        0      created
156        0      created
160        0      created
164        0      created
168        0      created
172        0      created
176        0      created
180        0      created
184        0      created
188        0      created
192        0      created
196        0      created
200        0      created

inconsistent outcomes: 0
```
