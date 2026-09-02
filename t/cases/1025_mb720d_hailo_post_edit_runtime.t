# MB720-D — asynchronous Hailo post-edit orchestration and late authorization.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Hailo::PostEditRuntime;
use Mediabot::Hailo::ReplyQueue;

{
    package MB720D::Editor;
    sub new { bless { pending => [], submitted => [] }, shift }
    sub submit {
        my ($self, %args) = @_;
        push @{ $self->{submitted} }, { %args };
        push @{ $self->{pending} }, $args{on_done};
        return 1;
    }
    sub complete {
        my ($self, $result) = @_;
        my $callback = shift @{ $self->{pending} } or die 'no pending edit';
        $callback->($result);
    }
}

sub _state_1025 {
    my ($generation, $enabled) = @_;
    return {
        enabled            => $enabled ? 1 : 0,
        runtime_active     => 1,
        irc_connected      => 1,
        channel_joined     => 1,
        current_generation => $generation,
    };
}

return sub {
    my ($assert) = @_;

    my $now = 100;
    my $editor = MB720D::Editor->new;
    my $queue = Mediabot::Hailo::ReplyQueue->new(
        max_total       => 4,
        max_per_channel => 3,
        ttl_seconds     => 20,
        typing_coeff    => 0,
        now_cb          => sub { $now },
    );
    my (@sent, @summary, @metrics);
    my $runtime = Mediabot::Hailo::PostEditRuntime->new(
        post_editor       => $editor,
        queue             => $queue,
        clock             => sub { $now },
        max_context_lines => 3,
        max_inflight      => 2,
        typing_enabled    => 0,
        metric_cb         => sub { push @metrics, { %{ $_[0] } } },
    );

    $assert->ok($runtime->observe_public_line(
        channel => '#test', text => 'ancienne phrase utile',
    ), 'ordinary public context is retained');
    $assert->ok(!$runtime->observe_public_line(
        channel => '#test', text => '!secret argument', is_command => 1,
    ), 'commands never enter provider context');
    $assert->ok(!$runtime->observe_public_line(
        channel => '#test', text => 'automated line', from_bot => 1,
    ), 'known bots never enter provider context');
    $runtime->observe_public_line(
        channel => '#test', text => 'question courante',
    );

    my $accepted = $runtime->submit(
        channel            => '#test',
        trigger            => 'question courante',
        candidate          => 'moi aimer cette musique',
        channel_language   => 'fr',
        provider           => 'auto',
        mode               => 'mention',
        request_generation => 7,
        state_cb           => sub { _state_1025(7, 1) },
        send_cb            => sub { push @sent, [@_]; 1 },
        on_done            => sub { push @summary, { %{ $_[0] } } },
    );
    $assert->ok($accepted->{accepted}, 'candidate enters the bounded queue');
    $assert->is(scalar @{ $editor->{submitted} }, 1,
        'candidate is submitted through the asynchronous post-editor');
    $assert->is(join("\0", @{ $editor->{submitted}[0]{context} }), 'ancienne phrase utile',
        'bounded context excludes commands, bots and the duplicated trigger');
    $assert->is($editor->{submitted}[0]{channel_language}, 'fr',
        'channel language crosses the provider boundary');

    $editor->complete({
        ok       => 1,
        line     => 'Moi, j’aime cette musique.',
        edited   => 1,
        reason   => 'edited',
        provider => 'openai',
        language => {
            language           => 'fr',
            channel_language   => 'fr',
            trigger_language   => 'fr',
            candidate_language => 'fr',
        },
    });
    $assert->is(join("\0", @{ $sent[0] }), "#test\0Moi, j’aime cette musique.",
        'validated provider edit is delivered');
    $assert->is($summary[0]{action}, 'sent', 'completion summary records delivery');
    $assert->is($summary[0]{edit_reason}, 'edited',
        'completion summary distinguishes a real edit');
    $assert->ok(!exists($summary[0]{line}) && !exists($summary[0]{candidate}),
        'aggregate summary contains no trigger, draft or edited text');

    my $enabled = 1;
    $runtime->submit(
        channel            => '#late',
        trigger            => 'hello there friend',
        candidate          => 'strange learned phrase',
        request_generation => 11,
        state_cb           => sub { _state_1025(11, $enabled) },
        send_cb            => sub { push @sent, [@_]; 1 },
        on_done            => sub { push @summary, { %{ $_[0] } } },
    );
    $enabled = 0;
    $editor->complete({
        ok       => 1,
        line     => 'strange learned phrase',
        edited   => 0,
        reason   => 'unchanged',
        language => { language => 'en' },
    });
    $assert->is($summary[-1]{reason}, 'disabled',
        'late channel revocation wins over provider completion');
    $assert->is(scalar(@sent), 1, 'revoked candidate is never emitted');

    $runtime->submit(
        channel            => '#fallback',
        trigger            => 'tu comprends ce message',
        candidate          => 'moi comprendre ce message',
        request_generation => 15,
        state_cb           => sub { _state_1025(15, 1) },
        send_cb            => sub { push @sent, [@_]; 1 },
        on_done            => sub { push @summary, { %{ $_[0] } } },
    );
    $editor->complete({
        ok       => 1,
        line     => 'moi comprendre ce message',
        edited   => 0,
        reason   => 'provider_error',
        language => { language => 'fr' },
    });
    $assert->is(join("\0", @{ $sent[-1] }), "#fallback\0moi comprendre ce message",
        'provider failure preserves and delivers the Hailo candidate');
    $assert->is($summary[-1]{edit_reason}, 'provider_error',
        'fallback reason remains aggregate and explicit');

    my $ordered_editor = MB720D::Editor->new;
    my $ordered = Mediabot::Hailo::PostEditRuntime->new(
        post_editor    => $ordered_editor,
        queue          => Mediabot::Hailo::ReplyQueue->new(
            max_total => 8, max_per_channel => 3, ttl_seconds => 30,
            typing_coeff => 0, now_cb => sub { $now },
        ),
        clock          => sub { $now },
        max_inflight   => 2,
        typing_enabled => 0,
    );
    my $submit_ordered = sub {
        my ($channel, $candidate) = @_;
        $ordered->submit(
            channel => $channel, trigger => 'trigger words here',
            candidate => $candidate, request_generation => 20,
            state_cb => sub { _state_1025(20, 1) }, send_cb => sub { 1 },
        );
    };
    $submit_ordered->('#a', 'first candidate phrase');
    $submit_ordered->('#a', 'second candidate phrase');
    $submit_ordered->('#b', 'parallel candidate phrase');
    $assert->is(scalar @{ $ordered_editor->{submitted} }, 2,
        'global concurrency allows two channels');
    $assert->is($ordered_editor->{submitted}[0]{candidate}, 'first candidate phrase',
        'first channel starts with its first candidate');
    $assert->is($ordered_editor->{submitted}[1]{candidate}, 'parallel candidate phrase',
        'busy channel is skipped without blocking another channel');
    $ordered_editor->complete({
        line => 'first candidate phrase', reason => 'unchanged',
        language => { language => 'en' },
    });
    $assert->is(scalar @{ $ordered_editor->{submitted} }, 3,
        'second candidate starts only after its channel becomes idle');
    $assert->is($ordered_editor->{submitted}[2]{candidate}, 'second candidate phrase',
        'per-channel FIFO order is preserved');

    my $disabled_editor = MB720D::Editor->new;
    my @disabled_sent;
    my $disabled = Mediabot::Hailo::PostEditRuntime->new(
        post_editor => $disabled_editor,
        queue => Mediabot::Hailo::ReplyQueue->new(
            typing_coeff => 0, now_cb => sub { $now },
        ),
        clock => sub { $now }, typing_enabled => 0,
    );
    $disabled->submit(
        channel => '#off', trigger => 'trigger words here',
        candidate => 'local guarded fallback', request_generation => 30,
        post_edit_enabled => 0,
        state_cb => sub { _state_1025(30, 1) },
        send_cb => sub { push @disabled_sent, [@_]; 1 },
    );
    $assert->is(scalar @{ $disabled_editor->{submitted} }, 0,
        'emergency kill switch performs no provider request');
    $assert->is(join("\0", @{ $disabled_sent[0] }), "#off\0local guarded fallback",
        'emergency mode keeps the same bounded local fallback path');

    my $delayed_editor = MB720D::Editor->new;
    my (@delayed_sent, @scheduled, @delayed_summary);
    my $delayed = Mediabot::Hailo::PostEditRuntime->new(
        post_editor => $delayed_editor,
        queue => Mediabot::Hailo::ReplyQueue->new(
            ttl_seconds => 30, typing_coeff => 1, now_cb => sub { $now },
        ),
        clock => sub { $now },
        typing_enabled => 1,
        schedule_cb => sub { push @scheduled, [@_]; 1 },
    );
    $delayed->submit(
        channel => '#delay', trigger => 'trigger words here',
        candidate => 'learned delayed phrase', request_generation => 40,
        state_cb => sub { _state_1025(40, 1) },
        send_cb => sub { push @delayed_sent, [@_]; 1 },
        on_done => sub { push @delayed_summary, { %{ $_[0] } } },
    );
    $delayed_editor->complete({
        line => 'learned delayed phrase', reason => 'unchanged',
        language => { language => 'en' },
    });
    $assert->ok($scheduled[0][0] > 0 && ref($scheduled[0][1]) eq 'CODE',
        'typing delay is scheduled after provider completion');
    $assert->is(scalar(@delayed_sent), 0,
        'provider completion does not bypass the scheduled typing delay');
    $scheduled[0][1]->();
    $assert->is(scalar(@delayed_sent), 1,
        'scheduled callback performs the guarded delivery');

    $delayed->submit(
        channel => '#stale', trigger => 'trigger words here',
        candidate => 'stale learned phrase', request_generation => 41,
        state_cb => sub { _state_1025(42, 1) }, send_cb => sub { 1 },
        on_done => sub { push @delayed_summary, { %{ $_[0] } } },
    );
    $delayed_editor->complete({
        line => 'stale learned phrase', reason => 'unchanged',
        language => { language => 'en' },
    });
    $scheduled[1][1]->();
    $assert->is($delayed_summary[-1]{reason}, 'stale_generation',
        'PART, reconnect or rejoin generation changes revoke a late reply');

    $delayed->submit(
        channel => '#unsafe', trigger => 'trigger words here',
        candidate => 'safe learned phrase', request_generation => 43,
        state_cb => sub { _state_1025(43, 1) }, send_cb => sub { 1 },
        command_prefixes => ['!'],
        on_done => sub { push @delayed_summary, { %{ $_[0] } } },
    );
    $delayed_editor->complete({
        line => '!unexpected command', reason => 'edited', edited => 1,
        language => { language => 'en' },
    });
    $scheduled[2][1]->();
    $assert->is($delayed_summary[-1]{reason}, 'command_output',
        'provider output cannot manufacture an IRC command line');

    $assert->ok(scalar(@metrics) >= 3,
        'aggregate metric callback observes completed outcomes');
    my $stats = $runtime->stats;
    $assert->is($stats->{inflight}, 0, 'completed runtime has no leaked inflight job');
    $assert->ok($stats->{sent} >= 2 && $stats->{dropped} >= 1,
        'runtime exposes bounded aggregate delivery counters');
};
