#!/bin/sh
# dvd_telem_poll.sh -- runs ON THE MISTER. Sample /tmp/dvd_telem.json every 100 ms
# for $1 seconds into $2. Shipped as a FILE (scp) rather than built from a shell
# string, because the string went through mister.py shell -> ssh -> bash -s and one
# extra layer of escaping silently ate `$i`, producing an empty log with no error.
n=$(( ${1:-120} * 10 ))
out=${2:-/tmp/dosetel.jsonl}
rm -f "$out"
i=0
while [ $i -lt $n ]; do
  cat /tmp/dvd_telem.json 2>/dev/null
  sleep 0.1
  i=$((i+1))
done > "$out"
