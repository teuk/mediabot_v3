# t/cases/603_mb385_private_notice_debug_redaction.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../..";
use Mediabot::Helpers ();

my @action_logs;
no warnings 'redefine';
local *Mediabot::Helpers::logBotAction = sub { push @action_logs, [@_]; return 1; };

{
    package MB385::Logger;
    sub new { bless { rows => [] }, shift }
    sub log { my ($self, $level, $text) = @_; push @{ $self->{rows} }, [$level, $text]; 1 }
}
{
    package MB385::IRC;
    sub new { bless { sent => [] }, shift }
    sub nick_folded { 'mediabot' }
    sub do_NOTICE {
        my ($self, %args) = @_;
        $self->{requested_result}++ if defined wantarray;
        push @{ $self->{sent} }, { %args };
        return 1;
    }
}
{
    package MB385::Metrics;
    sub new { bless { inc => [] }, shift }
    sub inc { my ($self, @args) = @_; push @{ $self->{inc} }, \@args; 1 }
}

my $logger  = MB385::Logger->new;
my $irc     = MB385::IRC->new;
my $metrics = MB385::Metrics->new;
my $bot = bless {
    logger  => $logger,
    irc     => $irc,
    metrics => $metrics,
}, 'MB385::Bot';

my $secret = 'SWORD-FISH-PRIVATE-385';
my $account = 'account-' . ('x' x 430);
my $wire_text = "identify $account $secret";

Mediabot::Helpers::botNotice($bot, 'NickServ', $wire_text);

my $all_logs = join("\n", map { $_->[1] // '' } @{ $logger->{rows} });
my $wire = join('', map { $_->{text} // '' } @{ $irc->{sent} });

ok($wire eq $wire_text,
    'private NOTICE wire payload is unchanged across chunks');
ok(index($all_logs, $secret) < 0,
    'private NOTICE secret is absent from every log level');
ok(index($all_logs, '****') >= 0,
    'private NOTICE logs contain the redaction marker');
ok(scalar(@{ $irc->{sent} }) > 1,
    'long private NOTICE is split on the wire');
ok(
    !grep({ ($_->[0] // -1) == 4 && index($_->[1] // '', $secret) >= 0 } @{ $logger->{rows} }),
    'level-4 diagnostic never contains the private secret'
);

my $normal_logger = MB385::Logger->new;
my $normal_irc = MB385::IRC->new;
my $normal_bot = bless {
    logger  => $normal_logger,
    irc     => $normal_irc,
    metrics => MB385::Metrics->new,
}, 'MB385::Bot';

Mediabot::Helpers::botNotice($normal_bot, 'Te[u]K', 'ordinary private reply');
my $normal_logs = join("\n", map { $_->[1] // '' } @{ $normal_logger->{rows} });
ok(index($normal_logs, 'ordinary private reply') >= 0,
    'ordinary private NOTICE visibility is preserved');

my $channel_logger = MB385::Logger->new;
my $channel_irc = MB385::IRC->new;
my $channel_bot = bless {
    logger  => $channel_logger,
    irc     => $channel_irc,
    metrics => MB385::Metrics->new,
}, 'MB385::Bot';

Mediabot::Helpers::botNotice($channel_bot, '#teuk', 'identify public-demo-value');
my $channel_logs = join("\n", map { $_->[1] // '' } @{ $channel_logger->{rows} });
ok(index($channel_logs, 'identify public-demo-value') >= 0,
    'channel NOTICE logs retain visible channel text');
ok(scalar(@action_logs) == 1,
    'channel NOTICE action logging remains active');

ok(!$irc->{requested_result} && !$normal_irc->{requested_result}
        && !$channel_irc->{requested_result},
    'ordinary NOTICE does not request a transport Future');

done_testing;
