use strict;
use warnings;
use Test::More;
use File::Basename qw(basename);
use ConsolidatedCases qw(run_suite);
# Conservative classifier: DBI, IO::Async, File::Temp. This suite keeps its
# own process and is neither PURE nor certified parallel-safe.
run_suite(basename(__FILE__));
done_testing;
