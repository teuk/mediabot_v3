use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Spec;
# Conservative classification: File::Temp, IPC::Open3, HTTP::Tiny and DBI
# describe the retained native scenarios; this is never a PURE fast case.
# Each fragment keeps its own lexical scope and scoped overrides. Cold-load
# probes inside fragments still use fresh child interpreters. Ordinary TAP
# assertions are counted individually; only the final plan is shared.
my $folder=File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__),'..','scenarios','external'));
for my $scenario (qw(
    1292_mb874_horoscope_sign_contract.pl
    1293_mb874_horoscope_text_budget.pl
    1294_mb875_fortnite_status_contract.pl
    1295_mb875_fortnite_display_scalars.pl
    1297_mb876_external_entrypoint_compatibility.pl
    1298_mb877_tmdb_optional_fields.pl
    1299_mb877_tmdb_utf8_budget.pl
    1301_mb878_tmdb_compatibility_and_tls.pl
)) {
    my $path=File::Spec->catfile($folder,$scenario);
    note("MB1061 scenario: $scenario");
    my $loaded=do $path;
    die "Scenario $scenario did not complete: ".($@ || $! || 'false return')."\n"
        unless $loaded;
}
done_testing;
