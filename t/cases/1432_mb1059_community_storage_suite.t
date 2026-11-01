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
my $folder=File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__),'..','scenarios','community'));
for my $scenario (qw(
    1341_mb965_notes_storage_consistency.pl
    1342_mb966_factoid_forget_identity.pl
    1343_mb967_factoid_fetch_error.pl
    1344_mb968_factoid_write_confirmation.pl
    1346_mb970_factoid_learn_identity.pl
    1347_mb971_native_factoid_reads.pl
    1348_mb972_native_factoid_store.pl
    1349_mb973_factoid_recall_identity.pl
)) {
    my $path=File::Spec->catfile($folder,$scenario);
    my $loaded=do $path;
    die "Scenario $scenario did not complete: ".($@ || $! || 'false return')."\n"
        unless $loaded;
}
done_testing;
