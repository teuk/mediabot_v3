# MB720-C — local runtime adoption and upgrade-safe chanset split.

use strict;
use warnings;
use utf8;

use File::Spec;

sub _slurp_1024 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $hailo = _slurp_1024(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));
    my $main = _slurp_1024(File::Spec->catfile('.', 'mediabot.pl'));
    my $mediabot = _slurp_1024(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $sample = _slurp_1024(File::Spec->catfile('.', 'mediabot.sample.conf'));
    my $migration = _slurp_1024(File::Spec->catfile(
        '.', 'install', 'migrations', '20260902_hailo_policy_chansets.sql'));
    my $schema = _slurp_1024(File::Spec->catfile('.', 'install', 'mediabot.sql'));
    my $docs = _slurp_1024(File::Spec->catfile('.', 'docs', 'HAILO_3.5.md'));

    $assert->like($hailo, qr/use Mediabot::Hailo::Normalizer/,
        'Hailo owns one normalization boundary');
    $assert->like($hailo, qr/use Mediabot::Hailo::Policy/,
        'Hailo owns one independent policy boundary');
    $assert->like($hailo, qr/use Mediabot::Hailo::ReplyQueue/,
        'Hailo owns one bounded reply queue boundary');
    $assert->like($hailo, qr/sub hailo_process_turn \{/,
        'local Hailo turn has one shared orchestrating helper');
    $assert->like($hailo,
        qr/HailoLearn.*historical \+Hailo.*HailoRespond/s,
        'unmigrated database inherits legacy Hailo learn/respond behaviour');
    $assert->like($hailo,
        qr/normalize_hailo_input\(.*?->decide\(.*?hailo_reply_before_learning\(/s,
        'normalization and policy happen before reply-before-learn execution');
    $assert->like($hailo,
        qr/rehydrate_hailo_output\(.*?record_reply/s,
        'nickname rehydration and output validation happen before reply cooldown commit');

    $assert->is(scalar(() = $main =~ /->hailo_process_turn\(/g), 3,
        'mention, chatter and ambient public paths use the shared local turn');
    $assert->is(scalar(() = $mediabot =~ /hailo_process_turn\(/g), 1,
        'context command fallback also uses the shared local turn');
    $assert->unlike($main, qr/Hailo(?:Chatter)? channel candidate for .*\$sAnswer/,
        'public runtime no longer logs raw Hailo drafts');
    $assert->unlike($mediabot, qr/Hailo channel candidate for .*\$sAnswer/,
        'context fallback no longer logs raw Hailo drafts');

    for my $name (qw(HailoLearn HailoRespond)) {
        $assert->like($migration,
            qr/INSERT INTO CHANSET_LIST \(chanset\)\s+SELECT '\Q$name\E'/s,
            "migration registers $name idempotently");
        $assert->like($schema, qr/'\Q$name\E'/,
            "fresh schema includes $name");
    }
    $assert->is(scalar(() = $migration =~ /master_list[.]chanset = 'Hailo'/g), 2,
        'both new switches inherit only channels already carrying +Hailo');
    $assert->is(scalar(() = $migration =~ /existing_set[.]id_channel_set IS NULL/g), 2,
        'data migration is idempotent for existing channel settings');

    for my $key (qw(
        HAILO_LEARN_INTERVAL_SECONDS
        HAILO_REPLY_INTERVAL_SECONDS
        HAILO_FLOOD_MAX_REPLIES
        HAILO_FLOOD_WINDOW_SECONDS
        HAILO_KEY_REPLY_RATE
        HAILO_REPLY_QUEUE_MAX_TOTAL
        HAILO_REPLY_QUEUE_MAX_PER_CHANNEL
        HAILO_REPLY_QUEUE_TTL_SECONDS
    )) {
        $assert->like($sample, qr/^\Q$key\E=/m,
            "sample documents $key");
    }

    $assert->like($docs, qr/MegaHAL interface compatibility/,
        'design records the exact compatibility target');
    $assert->like($docs,
        qr/force prefixes.*not accepted.*public runtime/is,
        'dangerous force controls remain privilege-bridge gated');
    $assert->like($docs,
        qr/MB720-D:.*asynchronous runtime wiring.*development\s+pilot/is,
        'asynchronous provider wiring and pilot remain explicit MB720-D work');

    my ($turn) = $hailo =~ /(sub hailo_process_turn \{.*?)(?=\n# Generate before learning)/s;
    $turn //= '';
    $assert->unlike($turn, qr/PostEditor|->submit\(/,
        'MB720-C does not prematurely arm the provider in the local IRC path');
};
