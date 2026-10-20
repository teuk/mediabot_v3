package MB858NewsFixture;
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(refaddr);
our @EXPORT_OK = qw(new_bot queue fire active);
our $clock = 100;

sub new_bot {
    return bless {
        irc => bless({connected => 1}, 'MB858NewsIRC'),
        loop => bless({timers => {}, made => []}, 'MB858NewsLoop'),
        logger => bless({lines => []}, 'MB858NewsLogger'),
        sent => [],
    }, 'MB858NewsBot';
}
sub queue {
    my ($bot, @lines) = @_;
    return Mediabot::CommandAsync::_replay_intents($bot,
        [map { ['privmsg', '#test', $_] } @lines], 'actualites', $bot->{irc});
}
sub fire { $_[0]{on_expire}->($_[0]) }
sub active { scalar keys %{$_[0]{loop}{timers}} }
sub install {
    no warnings qw(redefine once);
    *Mediabot::CommandAsync::_news_output_now = sub { $clock };
    *IO::Async::Timer::Countdown::new = sub {
        my ($class, %args) = @_;
        return bless \%args, 'MB858NewsTimer';
    };
    *Mediabot::Helpers::botPrivmsg = sub {
        my ($bot, $target, $text) = @_;
        push @{$bot->{sent}}, [$clock, $target, $text];
        $bot->{during_send}->($text) if $bot->{during_send};
        return 1;
    };
}
package MB858NewsIRC;
sub is_connected { $_[0]{connected} }
package MB858NewsBot;
sub getLoop { $_[0]{loop} }
sub getQuit { $_[0]{quit} || 0 }
package MB858NewsLogger;
sub log { push @{$_[0]{lines}}, $_[2] }
package MB858NewsLoop;
sub add {
    my ($self, $timer) = @_;
    $timer->{loop} = $self;
    Scalar::Util::weaken($timer->{loop});
    push @{$self->{made}}, $timer;
    $self->{timers}{Scalar::Util::refaddr($timer)} = $timer;
    $self->{on_add}->($timer) if $self->{on_add};
    die "private add failure\n" if ($self->{fail} // '') eq 'add';
    return $timer;
}
sub remove {
    my ($self, $timer) = @_;
    delete $self->{timers}{Scalar::Util::refaddr($timer)};
    $self->{on_remove}->($timer) if $self->{on_remove};
    return $timer;
}
package MB858NewsTimer;
sub start {
    my ($self) = @_;
    $self->{started} = 1;
    my $loop = $self->{loop};
    $loop->{on_start}->($self) if $loop && $loop->{on_start};
    die "private start failure\n" if $loop && ($loop->{fail} // '') eq 'start';
    return $self;
}
sub stop { $_[0]{started} = 0; return $_[0] }
1;
