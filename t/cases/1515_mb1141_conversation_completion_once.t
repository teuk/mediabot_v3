use strict;
use warnings;
use Test::More;
# All clients are injected: keep this unit test independent of transport setup.
BEGIN { $INC{'Mediabot/AI/Client.pm'} = __FILE__ unless exists $INC{'Mediabot/AI/Client.pm'}; }
use Mediabot::AI::ConversationExecutor;
{
    package MB1141::Client;
    sub new { bless { run => $_[1] }, $_[0] }
    sub execute { die 'unexpected synchronous execution' }
    sub submit { my ($self, $request, %opts) = @_; $self->{run}->($opts{on_done}) }
}
my $reply = {ok => 1, answer => 'REPLY: A quiet spell.'};
for my $mode (qw(duplicate reply_then_die throw_before deferred late_after_throw)) {
    my ($later, @results);
    my $client = MB1141::Client->new(sub {
        my ($done) = @_;
        $later = $done;
        die "launch failed\n" if $mode eq 'throw_before' || $mode eq 'late_after_throw';
        return 1 if $mode eq 'deferred';
        $done->($reply);
        die "post-completion failure\n" if $mode eq 'reply_then_die';
        $done->({ok => 0, error => 'duplicate'});
        return 1;
    });
    my $executor = Mediabot::AI::ConversationExecutor->new(client => $client);
    my $started = $executor->submit_dryrun(message => 'Hello', on_done => sub {push @results, $_[0]});
    if ($mode eq 'deferred') {
        is(scalar @results, 0, 'deferred submission does not complete early');
        $later->($reply);
        $later->($reply);
    }
    $later->($reply) if $mode eq 'late_after_throw';
    is(scalar @results, 1, "$mode completes exactly once");
    is($results[0]{action}, $mode =~ /throw/ ? 'no_reply' : 'reply', "$mode preserves the first result");
    is($started, $mode =~ /throw|die/ ? 0 : 1, "$mode preserves launch return semantics");
}
my $calls = 0;
my $client = MB1141::Client->new(sub { $_[0]->($reply); return 1 });
my $executor = Mediabot::AI::ConversationExecutor->new(client => $client);
my $started = eval { $executor->submit_dryrun(message => 'Hello', on_done => sub { ++$calls; die "consumer failed\n" }) };
is($calls, 1, 'throwing consumer is never invoked again as a provider failure');
is($@, '', 'synchronous consumer failure stays contained by submission boundary');
is($started, 0, 'failed synchronous submission returns false');
# Completion state belongs to one submission, not to the executor instance.
my @next;
is($executor->submit_dryrun(message => 'Again', on_done => sub {push @next, $_[0]}), 1, 'next submission starts');
is(scalar @next, 1, 'next submission has its own completion state');
done_testing;
