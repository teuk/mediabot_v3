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
my $folder=File::Spec->rel2abs(File::Spec->catdir(dirname(__FILE__),'..','scenarios','ai'));
for my $scenario (qw(
    1184_mb818_meta_providers.pl
    1185_mb818_meta_memory.pl
    1186_mb818_meta_chat_web.pl
    1188_mb818_meta_parallel_workers.pl
    1193_mb821_researched_answer_quality.pl
    1198_mb824_passage_catalogue.pl
    1206_mb829_maintenance_state.pl
    1225_mb839_hailo_completion_ownership.pl
    1248_mb851_hailo_unicode_brains.pl
    1249_mb851_hailo_unicode_nicks.pl
    1316_mb942_hailo_context_freshness.pl
    1319_mb945_hailo_handoff_authority.pl
    1418_mb1045_hailo_nick_identity.pl
    1419_mb1046_ai_context_cache.pl
    1420_mb1047_ai_reset_pending.pl
    1421_mb1048_meta_stage_ownership.pl
    1422_mb1049_ai_shared_limits.pl
)) {
    my $path=File::Spec->catfile($folder,$scenario);
    note("MB1061 scenario: $scenario");
    my $loaded=do $path;
    die "Scenario $scenario did not complete: ".($@ || $! || 'false return')."\n"
        unless $loaded;
}
done_testing;
