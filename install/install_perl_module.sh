#!/bin/bash
set -eu

if [ $# -ne 1 ]; then
    echo "Usage: $0 <Perl::Module::Name>" >&2
    exit 1
fi

MODULE="$1"

# Install without running upstream test suites.
# This makes the installation path much more reliable on fresh systems
# such as Debian 13 where some CPAN distributions have flaky tests.
cpan -T -i "$MODULE"