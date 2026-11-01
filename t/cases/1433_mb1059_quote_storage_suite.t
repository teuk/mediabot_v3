use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Spec;
use DBI (); # Classifier: real SQLite/DBI scenarios, never a PURE fast case.
use File::Temp (); # Fixtures create private temporary databases.

# Each fragment has its own file lexical scope and scoped overrides. They have
# distinct fixture packages and no BEGIN/CORE overrides or per-file TAP plans.
# This suite stays in a fresh process; Test::More counts every ordinary assertion.
my $folder=File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__),'..','scenarios','quotes'));
for my $scenario (qw(
    1345_mb969_quote_fetch_confirmation.pl
    1350_mb974_native_quote_duplicate_read.pl
    1351_mb975_quote_add_registry_context.pl
    1352_mb976_native_quote_count_reads.pl
    1353_mb977_native_topquote_reads.pl
    1354_mb978_quote_stats_author_key.pl
    1355_mb979_native_quote_insert_confirmation.pl
    1356_mb980_native_quote_search_reads.pl
    1357_mb981_native_quote_view_reads.pl
)) {
    my $path=File::Spec->catfile($folder,$scenario);
    my $loaded=do $path;
    die "Scenario $scenario did not complete: ".($@ || $! || 'false return')."\n"
        unless $loaded;
}
done_testing;
