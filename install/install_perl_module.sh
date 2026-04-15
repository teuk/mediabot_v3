#!/bin/bash
set -eu

if [ $# -ne 1 ]; then
    echo "Usage: $0 <Perl::Module::Name>" >&2
    exit 1
fi

MODULE="$1"

# Install without upstream tests to avoid flaky CPAN failures on fresh systems
cpan -T -i "$MODULE"