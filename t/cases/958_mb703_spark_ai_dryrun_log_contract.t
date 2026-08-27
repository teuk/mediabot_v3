# t/cases/958_mb703_spark_ai_dryrun_log_contract.t
# =============================================================================
# MB703-E — Spark AI runtime logs are bounded metadata, not generated content.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::DryRun;

return sub {
    my ($assert) = @_;

    my $ready = Mediabot::Spark::DryRun::format_ai_dryrun_log('#teuk', {
        action => 'ready', reason => 'generated', kind => 'callback',
        generation => 42, provider => 'openai', model => 'gpt-test',
        provider_fallback => 0, model_fallback => 1, content_fields => 1,
        content => { line => 'this must never be logged' },
    });
    $assert->like($ready, qr/^\[SPARK_AI_DRYRUN\] channel=#teuk /,
        'mb703-958: Spark AI dry-run uses dedicated marker');
    $assert->like($ready, qr/generation=42.*provider=openai.*model=gpt-test/,
        'mb703-958: operational provider metadata is visible');
    $assert->unlike($ready, qr/this must never be logged/,
        'mb703-958: generated content is excluded from application log');

    my $revoked = Mediabot::Spark::DryRun::format_ai_dryrun_log('#teuk', {
        action => 'revoked', reason => 'stale_generation', kind => 'portal',
        generation => 43,
    });
    $assert->like($revoked, qr/action=revoked.*reason=stale_generation.*kind=portal/,
        'mb703-958: revoked late completions remain diagnosable');

    my $bad = Mediabot::Spark::DryRun::format_ai_dryrun_log('#teuk', {
        action => 'ready', reason => 'generated', kind => 'callback',
        provider => "openai\nPRIVMSG",
    });
    $assert->unlike($bad // '', qr/PRIVMSG/,
        'mb703-958: unsafe provider metadata cannot inject log lines');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/Spark/DryRun.pm"
            or die "open DryRun.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->unlike($src, qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG|Net::Async::IRC)\b/,
        'mb703-958: dry-run generation boundary owns no IRC emission primitive');
    $assert->unlike($src, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST)\b/,
        'mb703-958: dry-run generation boundary owns no database/chanset access');
};
