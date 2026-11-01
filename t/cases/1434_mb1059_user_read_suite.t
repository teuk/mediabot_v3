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
my $folder=File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__),'..','scenarios','users'));
for my $scenario (qw(
    1375_mb1000_birthday_write_errors.pl
    1377_mb1002_greet_read_errors.pl
    1379_mb1004_user_statistics_reads.pl
    1380_mb1005_userinfo_read_errors.pl
    1402_mb1029_activity_counter_consistency.pl
    1424_mb1051_seen_channel_prefix_scope.pl
)) {
    my $path=File::Spec->catfile($folder,$scenario);
    my $loaded=do $path;
    die "Scenario $scenario did not complete: ".($@ || $! || 'false return')."\n"
        unless $loaded;
}
done_testing;
