use strict;
use warnings;
use Test::More;
use Mediabot::Hailo::PostEditRuntime;
use Mediabot::Hailo::ReplyQueue;

{
    package MB942Editor;
    sub new { bless { requests => [], pending => [] }, shift }
    sub submit {
        my ($self, %args) = @_;
        push @{ $self->{requests} }, { %args };
        push @{ $self->{pending} }, $args{on_done};
        return 1;
    }
    sub complete {
        my ($self) = @_;
        my $callback = shift @{ $self->{pending} } or die 'missing request';
        $callback->({ ok => 1, line => 'A recent reply.', reason => 'unchanged' });
    }
}

my $now = 100;
my $editor = MB942Editor->new;
my $runtime = Mediabot::Hailo::PostEditRuntime->new(
    post_editor => $editor, clock => sub { $now }, typing_enabled => 0,
);
$runtime->observe_public_line(channel => '#test', text => 'old topic');
$now = 399;
is_deeply($runtime->recent_context(channel => '#TEST'), ['old topic'],
    'a turn younger than five minutes remains useful through the channel casemap');
$now = 400;
is_deeply($runtime->recent_context(channel => '#test'), [],
    'a calm channel cannot reuse a turn at the five-minute expiry boundary');
$now = 500;
$runtime->observe_public_line(channel => '#test', text => 'new topic');
is_deeply($runtime->recent_context(channel => '#test'), ['new topic'],
    'a new topic starts with fresh context after silence');

$now = 600;
$runtime->observe_public_line(channel => '#mixed', text => 'previous subject');
$now = 899;
$runtime->observe_public_line(channel => '#mixed', text => 'current subject');
$now = 900;
is_deeply($runtime->recent_context(channel => '#mixed'), ['current subject'],
    'a new line does not refresh the age of older lines in the same channel');
$runtime->observe_public_line(channel => '#mixed', text => 'current question');
is_deeply($runtime->recent_context(channel => '#mixed', trigger => 'current question'), ['current subject'],
    'the trigger is still omitted from the provider context');
$runtime->observe_public_line(channel => '#mixed', text => '!secret', is_command => 1);
$runtime->observe_public_line(channel => '#mixed', text => 'bot output', from_bot => 1);
is_deeply($runtime->recent_context(channel => '#mixed'), ['current subject', 'current question'],
    'command and bot exclusions remain in force');
is_deeply($runtime->recent_context(channel => '#other'), [],
    'context is never borrowed from another channel');

$now = 1000;
$runtime->observe_public_line(channel => '#clock', text => 'future after rollback');
$now = 999;
is_deeply($runtime->recent_context(channel => '#clock'), [],
    'a clock rollback cannot make future-dated context eligible');
$now = 1001;
is_deeply($runtime->recent_context(channel => '#clock'), [],
    'discarded context does not reappear when the clock catches up');

my $queued_editor = MB942Editor->new;
my $queued = Mediabot::Hailo::PostEditRuntime->new(
    post_editor => $queued_editor, clock => sub { $now }, max_inflight => 1,
    typing_enabled => 0,
    queue => Mediabot::Hailo::ReplyQueue->new(now_cb => sub { $now }),
);
my @sent;
sub submit_942 {
    my ($channel) = @_;
    return $queued->submit(channel => $channel, trigger => 'current question',
        candidate => 'A recent reply.', request_generation => 1,
        state_cb => sub { +{ enabled => 1, runtime_active => 1, irc_connected => 1,
            channel_joined => 1, current_generation => 1 } },
        send_cb => sub { push @sent, [@_]; 1 });
}
$now = 2000;
$queued->observe_public_line(channel => '#test', text => 'expires while queued');
$now = 2298;
ok(submit_942('#hold')->{accepted}, 'another channel occupies the editor slot');
ok(submit_942('#test')->{accepted}, 'the target turn queues with still-fresh context');
is(scalar @{ $queued_editor->{requests} }, 1, 'the second request has not reached the provider yet');
$now = 2301;
$queued->observe_public_line(channel => '#test', text => 'later human turn');
$queued_editor->complete;
is(scalar @{ $queued_editor->{requests} }, 2, 'completion opens the queued provider request');
is_deeply($queued_editor->{requests}[1]{context}, [],
    'context expiring in the queue is removed before the actual provider request');
$queued_editor->complete;
is(scalar @sent, 2, 'context expiry does not suppress otherwise authorized replies');
is_deeply($queued->recent_context(channel => '#test'), ['later human turn', 'A recent reply.'],
    'later context is retained locally but was not inserted into an older queued request');
is($queued->stats->{inflight}, 0, 'completion still releases all runtime slots');
done_testing;
