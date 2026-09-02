# MB720-D — every public Hailo candidate crosses the asynchronous post-editor.

use strict;
use warnings;
use utf8;

use File::Spec;

sub _slurp_1026 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $hailo = _slurp_1026(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));
    my $runtime = _slurp_1026(File::Spec->catfile(
        '.', 'Mediabot', 'Hailo', 'PostEditRuntime.pm'));
    my $post = _slurp_1026(File::Spec->catfile(
        '.', 'Mediabot', 'Hailo', 'PostEditor.pm'));
    my $main = _slurp_1026(File::Spec->catfile('.', 'mediabot.pl'));
    my $mediabot = _slurp_1026(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    my $metrics = _slurp_1026(File::Spec->catfile('.', 'Mediabot', 'Metrics.pm'));
    my $sample = _slurp_1026(File::Spec->catfile('.', 'mediabot.sample.conf'));
    my $docs = _slurp_1026(File::Spec->catfile('.', 'docs', 'HAILO_3.5.md'));

    $assert->like($hailo, qr/use Mediabot::Hailo::PostEditor/,
        'shared provider-neutral post-editor is instantiated by Hailo');
    $assert->like($hailo, qr/use Mediabot::Hailo::PostEditRuntime/,
        'dedicated bounded asynchronous runtime is instantiated by Hailo');
    $assert->is(scalar(() = $hailo =~ /^sub _hailo_conf_int\s*\{/gm), 1,
        'post-editor reuses the single shared bounded integer config helper');
    $assert->like($hailo,
        qr/_hailo_conf_int\(\s*\$self, 'hailo[.]HAILO_POST_EDIT_CONTEXT_LINES'/s,
        'post-editor passes a fully qualified key to the shared config helper');
    $assert->like($runtime, qr/\{post_editor\}->submit\(/,
        'runtime submits through the asynchronous editor interface');
    $assert->unlike($runtime, qr/\{post_editor\}->execute\(/,
        'runtime cannot fall back to synchronous provider execution');

    $assert->is(scalar(() = $main =~ /->hailo_observe_public_line\(/g), 1,
        'public handler records one bounded Hailo context observation');
    $assert->is(scalar(() = $main =~ /->hailo_submit_candidate\(/g), 2,
        'mention and chatter candidates use the post-edit queue');
    $assert->is(scalar(() = $mediabot =~ /hailo_submit_candidate\(/g), 1,
        'context-command fallback also uses the post-edit queue');
    $assert->unlike($main,
        qr/\$mediabot->botPrivmsg\(\$where\s*,\s*\$sAnswer\)/,
        'public candidate branches contain no direct raw-draft emission');
    $assert->unlike($mediabot,
        qr/botPrivmsg\(\$self\s*,\s*\$sChannel\s*,\s*\$sAnswer\)/,
        'fallback candidate branch contains no direct raw-draft emission');

    $assert->like($hailo,
        qr/capture_generation\(\$channel\).*?snapshot\(\$channel\)/s,
        'channel generation is captured and re-read after provider completion');
    $assert->like($hailo,
        qr/hailo_channel_policy\(\$self, \$channel, fresh => 1\)/,
        'late delivery bypasses the optional-chanset cache');
    $assert->like($runtime,
        qr/disabled.*?runtime_inactive.*?irc_disconnected.*?not_joined.*?stale_generation/s,
        'late gate covers revocation, runtime, connection, JOIN and generation');
    $assert->like($runtime, qr/typing_delay_seconds.*?schedule_cb/s,
        'typing delay is scheduled only after provider completion');
    $assert->like($runtime, qr/queue_expired|expired/,
        'queue and late delivery both enforce expiration');

    $assert->like($post, qr/reason\s*=>\s*'provider_error'.*?line\s*=>\s*\$fallback/s,
        'provider failure returns the original Hailo candidate');
    $assert->like($post, qr/_preserves_anchor\(\$fallback, \$edited\)/,
        'provider rewrite still crosses the lexical-anchor validator');
    $assert->like($post, qr/resolve_hailo_language\(/,
        'language resolver combines channel, trigger and draft');

    for my $key (qw(
        HAILO_POST_EDIT_ENABLED
        HAILO_POST_EDIT_PROVIDER
        HAILO_POST_EDIT_CONTEXT_LINES
        HAILO_POST_EDIT_MAX_INFLIGHT
        HAILO_TYPING_DELAY_ENABLED
        HAILO_TYPING_DELAY_COEFFICIENT_PERCENT
        HAILO_TYPING_DELAY_OFFSET_MS
    )) {
        $assert->like($sample, qr/^\Q$key\E=/m,
            "sample exposes $key");
    }
    $assert->like($sample, qr/^HAILO_POST_EDIT_ENABLED=1$/m,
        'normal development runtime sends every reply to post-edit by default');
    $assert->like($sample, qr/^HAILO_POST_EDIT_PROVIDER=auto$/m,
        'provider-neutral auto selection remains explicit');

    for my $name (qw(
        mediabot_hailo_post_edit_total
        mediabot_hailo_post_edit_inflight
        mediabot_hailo_post_edit_queue_depth
    )) {
        $assert->like($metrics, qr/'\Q$name\E'/,
            "aggregate metric $name is declared");
    }
    my ($finish) = $runtime =~ /(sub _finish_job \{.*?)(?=\nsub stats \{)/s;
    $finish //= '';
    $assert->unlike($finish,
        qr/\b(?:trigger|candidate|line)\s*=>/,
        'public completion summary does not copy conversational payloads');
    $assert->like($docs,
        qr/Provider completion never grants permission to send/s,
        'architecture records late authorization as mandatory');
    $assert->like($docs,
        qr/requires\s+at least one live edited reply.*focused runtime contract then deterministically completes a provider after\s+channel disable.*requires the late `disabled` outcome.*proves that no candidate\s+is emitted.*injects provider failure.*original\s+learned draft/s,
        'development qualification combines live editing with deterministic revocation and fallback evidence');
};
