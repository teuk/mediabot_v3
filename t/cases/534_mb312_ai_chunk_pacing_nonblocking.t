# t/cases/534_mb312_ai_chunk_pacing_nonblocking.t
# =============================================================================
# MB312:
#   - OpenAI/Claude IRC chunk pacing must not sleep in the event loop;
#   - chunks remain ordered and serialized per target;
#   - Partyline callback output remains synchronous;
#   - no-loop fallback remains compatible with lightweight tests.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb312 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb312 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;

    while ($pos < length($src)) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        $depth-- if $char eq '}';
        return substr($src, $start, $pos + 1 - $start)
            if $depth == 0;
        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb312(
        File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm')
    );

    my $queue  = _extract_sub_mb312($src, '_queue_irc_chunks');
    my $openai = _extract_sub_mb312($src, 'chatGPT');
    my $claude = _extract_sub_mb312($src, 'claudeAI');

    $assert->ok(defined $queue, '_queue_irc_chunks helper found');
    $assert->ok(defined $openai, 'chatGPT body found');
    $assert->ok(defined $claude, 'claudeAI body found');

    $assert->unlike(
        $src,
        qr/\b(?:u?sleep)\s*\(/,
        'Claude/OpenAI module no longer sleeps while pacing IRC messages'
    );

    $assert->like(
        $queue // '',
        qr/IO::Async::Timer::Countdown->new/,
        'pacing uses an IO::Async countdown timer'
    );

    $assert->like(
        $queue // '',
        qr/_external_ai_output_queues/,
        'pacing keeps a per-target output queue'
    );

    $assert->like(
        $openai // '',
        qr/_queue_irc_chunks\(/,
        'OpenAI IRC output uses the asynchronous pacing queue'
    );

    $assert->like(
        $claude // '',
        qr/_queue_irc_chunks\(/,
        'Claude IRC output uses the asynchronous pacing queue'
    );

    $assert->like(
        $claude // '',
        qr/if\s*\(\$output_fn\).*?\$_out->\(\$chunk\[\$i\]\)/s,
        'Partyline callback output remains synchronous'
    );

    # Exercise the actual helper body in isolation with a deterministic fake
    # loop and fake countdown timers.
    my $probe = <<'PROBE';
use strict;
use warnings;

BEGIN {
    $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;
}

{
    package IO::Async::Timer::Countdown;
    our @PENDING;

    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }

    sub start {
        my ($self) = @_;
        push @PENDING, $self;
        return 1;
    }

    sub stop { return 1 }

    sub fire {
        my ($self) = @_;
        $self->{on_expire}->();
        return 1;
    }
}

{
    package MB312::Loop;
    sub new { return bless {}, shift }
    sub add { return 1 }
    sub remove { return 1 }
}

{
    package MB312::Logger;
    sub new { return bless { messages => [] }, shift }
    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{messages} }, [$level, $message];
        return 1;
    }
}

{
    package Mediabot::Helpers;
    our @SENT;
    sub botPrivmsg {
        my ($self, $target, $message) = @_;
        push @SENT, "$target:$message";
        return 1;
    }
}

{
    package MB312::Probe;
HELPER_BODY
}

my $bot = bless {
    loop   => MB312::Loop->new,
    logger => MB312::Logger->new,
}, 'MB312::Bot';

my $count = MB312::Probe::_queue_irc_chunks(
    $bot,
    '#test',
    ['one', 'two', 'three'],
    750_000,
    'probe',
);

print "count=$count\n";
print "step1=" . join(',', @Mediabot::Helpers::SENT) . "\n";

shift(@IO::Async::Timer::Countdown::PENDING)->fire;
print "step2=" . join(',', @Mediabot::Helpers::SENT) . "\n";

shift(@IO::Async::Timer::Countdown::PENDING)->fire;
print "step3=" . join(',', @Mediabot::Helpers::SENT) . "\n";

@Mediabot::Helpers::SENT = ();
@IO::Async::Timer::Countdown::PENDING = ();

MB312::Probe::_queue_irc_chunks(
    $bot, '#serial', ['a1', 'a2'], 100_000, 'first'
);
MB312::Probe::_queue_irc_chunks(
    $bot, '#serial', ['b1', 'b2'], 100_000, 'second'
);

while (@IO::Async::Timer::Countdown::PENDING) {
    shift(@IO::Async::Timer::Countdown::PENDING)->fire;
}

print "serial=" . join(',', @Mediabot::Helpers::SENT) . "\n";
print "queue_left=" . (exists($bot->{_external_ai_output_queues}{'#serial'}) ? 1 : 0) . "\n";

@Mediabot::Helpers::SENT = ();
my $fallback = bless { logger => MB312::Logger->new }, 'MB312::Bot';
MB312::Probe::_queue_irc_chunks(
    $fallback, '#fallback', ['x', 'y'], 750_000, 'fallback'
);
print "fallback=" . join(',', @Mediabot::Helpers::SENT) . "\n";
PROBE

    $probe =~ s/HELPER_BODY/$queue/;

    open my $fh, '-|', $^X, '-e', $probe
        or die "could not start MB312 probe: $!";

    local $/;
    my $output = <$fh> // '';
    close $fh;

    my $rc = $? >> 8;
    $output =~ s/\s+\z//;

    $assert->is($rc, 0, 'isolated pacing probe exits successfully');

    $assert->like(
        $output,
        qr/^count=3\nstep1=#test:one\nstep2=#test:one,#test:two\nstep3=#test:one,#test:two,#test:three/m,
        'chunks are emitted one at a time as timers fire'
    );

    $assert->like(
        $output,
        qr/^serial=#serial:a1,#serial:a2,#serial:b1,#serial:b2$/m,
        'concurrent batches remain serialized per IRC target'
    );

    $assert->like(
        $output,
        qr/^queue_left=0$/m,
        'completed target queue is removed'
    );

    $assert->like(
        $output,
        qr/^fallback=#fallback:x,#fallback:y$/m,
        'missing event loop falls back to immediate compatible delivery'
    );
};
