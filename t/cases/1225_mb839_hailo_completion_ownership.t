use strict;
use warnings;
use Test::More;
use Mediabot::Hailo::PostEditor;
use Mediabot::Hailo::PostEditRuntime;
use Mediabot::Hailo::ReplyQueue;

{
    package MB839Client;
    sub new { bless { mode => $_[1] }, $_[0] }
    sub submit {
        my ($self, $request, %args) = @_;
        $self->{done} = $args{on_done};
        return 1 if $self->{mode} eq 'async';
        return 0 if $self->{mode} eq 'refuse';
        die "client refused\n" if $self->{mode} eq 'throw';
        $args{on_done}->({ok => 1, answer => 'I like this music.', provider => 'openai'});
        die "after completion\n" if $self->{mode} eq 'complete_throw';
        return 0 if $self->{mode} eq 'complete_false';
        $args{on_done}->({ok => 0, error => 'late failure'});
        return 1;
    }
}

my %request = (channel_language => 'en', trigger => 'do you like this music?',
    candidate => 'i like this music', context => []);
for my $mode (qw(complete_twice complete_throw complete_false refuse throw async)) {
    my $client = MB839Client->new($mode);
    my $editor = Mediabot::Hailo::PostEditor->new(client => $client);
    my @done;
    my $accepted = $editor->submit(%request, on_done => sub { push @done, $_[0] });
    if ($mode eq 'async') {
        is(scalar @done, 0, 'accepted asynchronous request waits for its callback');
        $client->{done}->({ok => 1, answer => 'I like this music.', provider => 'openai'});
    }
    is(scalar @done, 1, "$mode: exactly one completion decision");
    my $expected = $mode eq 'refuse' || $mode eq 'throw' ? 'provider_error' : 'edited';
    is($done[0] ? $done[0]{reason} : '', $expected, "$mode: the first terminal decision wins");
    is($accepted ? 1 : 0, $expected eq 'edited' ? 1 : 0, "$mode: submission result reflects accepted completion or refusal");
    $client->{done}->({ok => 0, error => 'duplicate'});
    is(scalar @done, 1, "$mode: a late client callback cannot reopen completion");
}

{
    my $client = MB839Client->new('async');
    my $editor = Mediabot::Hailo::PostEditor->new(client => $client);
    my @done;
    ok(!$editor->submit(candidate => undef, on_done => sub { push @done, $_[0] }), 'invalid input stays a refusal');
    is(scalar @done, 1, 'invalid input completes once');
    is($done[0]{reason}, 'invalid_input', 'invalid-input fallback remains explicit');
    ok(!$client->{done}, 'invalid input is never submitted to the client');
}

{
    my $client = MB839Client->new('complete_throw');
    my $editor = Mediabot::Hailo::PostEditor->new(client => $client);
    my $attempts = 0;
    eval { $editor->submit(%request, on_done => sub { $attempts++; die "consumer failed\n" }) };
    is($attempts, 1, 'consumer exception cannot trigger another terminal callback');
}

{
    package MB839Editor;
    sub new { bless {}, $_[0] }
    sub submit {
        my ($self, %args) = @_;
        $self->{done} = $args{on_done};
        $args{on_done}->({ok => 1, line => 'I like this music.', edited => 1,
            reason => 'edited', language => {language => 'en'}});
        die "editor exception after callback\n";
    }
}

{
    my $now = 100;
    my (@timers, @sent, @summary);
    my $editor = MB839Editor->new;
    my $queue = Mediabot::Hailo::ReplyQueue->new(now_cb => sub {$now}, typing_coeff => 1);
    my $runtime = Mediabot::Hailo::PostEditRuntime->new(post_editor => $editor, queue => $queue,
        clock => sub {$now}, schedule_cb => sub { push @timers, $_[1]; return 1 });
    my $result = $runtime->submit(channel => '#test', %request, request_generation => 1,
        state_cb => sub {{enabled => 1, runtime_active => 1, irc_connected => 1,
            channel_joined => 1, current_generation => 1}},
        send_cb => sub { push @sent, $_[1]; return 1 },
        on_done => sub { push @summary, $_[0] });
    ok($result->{accepted}, 'runtime accepts the edited response');
    is(scalar @timers, 1, 'editor callback followed by throw arms one typing timer');
    is(scalar @sent, 0, 'typing delay is respected');
    $timers[0]->();
    is_deeply(\@sent, ['I like this music.'], 'post-callback exception cannot replace the accepted edit with raw fallback');
    is(scalar @summary, 1, 'runtime reports a single terminal outcome');
    is($summary[0]{edit_reason}, 'edited', 'accepted edit metadata is retained');
    is($runtime->stats->{inflight}, 0, 'completion releases the runtime slot');
    $editor->{done}->({ok => 0});
    $_->() for @timers;
    is(scalar @sent, 1, 'late editor and timer callbacks cannot repeat the IRC reply');
    is(scalar @summary, 1, 'late callbacks cannot inflate terminal counters');
}

done_testing;
