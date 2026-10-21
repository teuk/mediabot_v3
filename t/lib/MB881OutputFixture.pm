package MB881OutputFixture;
use strict;
use warnings;
use utf8;
use Mediabot::Helpers ();

# Only integration seams and IO are replaced. Sender, TextBudget, classification,
# redaction and the deferred queue remain their production implementations.
sub new_bot {
    return bless {
        policy => {}, blocked => 0, events => [],
        logger => bless({rows => []}, 'MB881::Logger'),
        irc => bless({wire => []}, 'MB881::IRC'),
        metrics => bless({counts => {}}, 'MB881::Metrics'),
        dbh => bless({queries => [], finishes => 0, words => []}, 'MB881::DBH'),
    }, 'MB881::Bot';
}
sub with_policy {
    my ($code) = @_;
    no warnings 'redefine';
    local *Mediabot::Helpers::getIdChansetList = sub {$_[1]};
    local *Mediabot::Helpers::getIdChannelSet = sub {$_[0]{policy}{$_[2]} ? 1 : undef};
    local *Mediabot::Helpers::checkAntiFlood = sub {$_[0]{blocked} ? 1 : 0};
    local *Mediabot::Helpers::logBotAction = sub {push @{$_[0]{events}}, ['history', @_[1 .. 5]]; 1};
    local *Mediabot::Helpers::noticeConsoleChan = sub {push @{$_[0]{events}}, ['console', $_[1]]; 1};
    return $code->();
}
package MB881::Bot;
sub getLoop {$_[0]{loop}}
package MB881::Logger;
sub log {push @{$_[0]{rows}}, [$_[1], $_[2]]; 1}
package MB881::IRC;
sub nick_folded {'mediabot'}
sub do_PRIVMSG {my ($s, %args) = @_; push @{$s->{wire}}, {kind => 'privmsg', %args}; 1}
sub do_NOTICE {my ($s, %args) = @_; push @{$s->{wire}}, {kind => 'notice', %args}; 1}
package MB881::Metrics;
sub inc {$_[0]{counts}{$_[1]}++; 1}
package MB881::DBH;
sub prepare {
    my ($self, $sql) = @_;
    push @{$self->{queries}}, {sql => $sql};
    return undef if ($self->{failure} // '') eq 'prepare';
    return bless {dbh => $self, words => [@{$self->{words}}]}, 'MB881::STH';
}
package MB881::STH;
sub execute {
    my ($self, @bind) = @_;
    $self->{dbh}{queries}[-1]{bind} = \@bind;
    return ($self->{dbh}{failure} // '') eq 'execute' ? 0 : 1;
}
sub fetchrow_hashref {my $word = shift @{$_[0]{words}}; defined($word) ? {badword => $word} : undef}
sub finish {$_[0]{dbh}{finishes}++; 1}
package MB881::Timer;
sub new {my ($class, %args) = @_; bless \%args, $class}
sub start {$_[0]{started} = 1; 1}
sub stop {$_[0]{stopped} = 1; 1}
package MB881::Loop;
sub new {bless {pending => [], delays => []}, shift}
sub add {push @{$_[0]{pending}}, $_[1]; push @{$_[0]{delays}}, $_[1]{delay}; 1}
sub remove {$_[1]{removed} = 1; 1}
sub tick {my $t = shift @{$_[0]{pending}}; $t->{on_expire}->() if $t}
sub drain {my ($s) = @_; my $n = 0; while (@{$s->{pending}}) {die 'fixture did not finish' if ++$n > 100; $s->tick}}
1;
