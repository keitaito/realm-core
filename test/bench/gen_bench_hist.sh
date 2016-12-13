#!/bin/sh
#
# See ./util/gen_bench_hist.sh --help for documentation.

show_usage () {
  cat <<EOF
Usage: $0 [-h|--help]
EOF
}

show_help () {
  echo ""
  show_usage
  echo ""
  cat <<EOF
./gen_bench_hist.sh

This script runs the benchmarks on each version of core specified in the
file revs_to_benchmark.txt plus the current branch. The benchmarks of a
revision are not run if the benchmarks of that revision are already found in
the results folder. The results are then combined by function using a script
to generate a graph per benchmark function which shows performance across
revisions.

EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help )
      show_help
      exit 0
      ;;
    * )
      break
      ;;
  esac
done

if [ $# -gt 0 ]; then
  show_usage
  exit 1
fi

while read -r p; do
  echo "$p"
  sh gen_bench.sh "$p"
done <revs_to_benchmark.txt

sh gen_bench.sh HEAD

