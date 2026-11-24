#!/bin/sh
# Print dialog PDF service: $1 title, $2 options, $3 PDF. Copy it (the print system deletes
# its temp file when we return) and hand it to Tearoff, which prints it right away.
dest="/tmp/tearoff-print-$$.pdf"; touch "$dest" 2>/dev/null || dest="${TMPDIR:-/tmp}/tearoff-print-$$.pdf"
cp "$3" "$dest" && open -b com.au12.tearoff "$dest"
