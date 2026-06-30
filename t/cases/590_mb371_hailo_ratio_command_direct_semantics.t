# t/cases/590_mb371_hailo_ratio_command_direct_semantics.t
#
# mb371 — The hailo_chatter command must read and write the direct percentage
# consumed by mb370.  A requested 97% must never be stored/displayed as 3%.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

BEGIN {
    unshift @INC, "$Bin/../..";

    # Minimal stubs for dependencies unavailable in the isolated audit image.
    package JSON::MaybeXS;
    sub import { }
    $INC{'JSON/MaybeXS.pm'} = __FILE__;

    package IO::Async::Timer::Countdown;
    sub import { }
    $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;

    package IO::Async::Stream;
    sub import { }
    $INC{'IO/Async/Stream.pm'} = __FILE__;

    package Hailo;
    sub new { bless {}, shift }
    $INC{'Hailo.pm'} = __FILE__;
}

require Mediabot::Hailo;

{
    package MB371::User;
    sub new { bless {}, shift }
    sub is_authenticated { 1 }
    sub has_level { $_[1] eq 'Master' ? 1 : 0 }
    sub nickname { 'Teuk' }
    sub level_description { 'Master' }
}

{
    package MB371::Context;
    sub new {
        my ($class, %args) = @_;
        return bless \%args, $class;
    }
    sub bot     { $_[0]{bot} }
    sub nick    { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub message { $_[0]{message} }
    sub args    { $_[0]{args} }
    sub user    { $_[0]{user} }
}

{
    package MB371::Logger;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{entries} }, [$level, $message];
        return 1;
    }
}

my $bot = bless {
    logger => MB371::Logger->new,
}, 'MB371::Bot';
my $user = MB371::User->new;

my @notices;
my @logs;
my @stored;
my $db_ratio = 97;

{
    no warnings qw(redefine once);
    local *Mediabot::Hailo::botNotice = sub {
        my ($self, $nick, $text) = @_;
        push @notices, [$nick, $text];
        return 1;
    };
    local *Mediabot::Hailo::noticeConsoleChan = sub { return 1 };
    local *Mediabot::Hailo::logBot = sub {
        push @logs, [@_];
        return 1;
    };
    local *Mediabot::Hailo::getIdChansetList = sub { return 123 };
    local *Mediabot::Hailo::getIdChannelSet = sub { return 456 };
    local *Mediabot::Hailo::get_hailo_channel_ratio = sub {
        return $db_ratio;
    };
    local *Mediabot::Hailo::set_hailo_channel_ratio = sub {
        my ($self, $channel, $ratio) = @_;
        push @stored, [$channel, $ratio];
        $db_ratio = $ratio;
        return 0;
    };

    my $query = MB371::Context->new(
        bot     => $bot,
        user    => $user,
        nick    => 'Teuk',
        channel => '#teuk',
        message => undef,
        args    => [],
    );

    is(Mediabot::Hailo::hailo_chatter_ctx($query), 1,
        'query succeeds for a configured channel');
    is($notices[-1][1],
        'Hailo chatter reply chance on #teuk is currently 97%.',
        'query displays the direct stored percentage');
    unlike($notices[-1][1], qr/\b3%\b/,
        'query does not invert 97 into 3');

    for my $ratio (97, 3, 0, 100) {
        my $set = MB371::Context->new(
            bot     => $bot,
            user    => $user,
            nick    => 'Teuk',
            channel => '#teuk',
            message => undef,
            args    => [$ratio],
        );

        is(Mediabot::Hailo::hailo_chatter_ctx($set), 1,
            "setting ${ratio}% succeeds");
        is($stored[-1][0], '#teuk',
            "setting ${ratio}% targets the requested channel");
        is($stored[-1][1], $ratio,
            "setting ${ratio}% stores the direct percentage");
        is($notices[-1][1],
            "HailoChatter's ratio is now set to ${ratio}% on #teuk",
            "setting ${ratio}% reports the same percentage");
    }
}

open my $fh, '<', "$Bin/../../Mediabot/Hailo.pm" or die $!;
local $/;
my $source = <$fh>;
close $fh;

like($source, qr/mb371-B1/, 'MB371 marker is present');
unlike($source, qr/100\s*-\s*\$stored_ratio/,
    'query source contains no stored-ratio inversion');
unlike($source, qr/100\s*-\s*\$ratio/,
    'set source contains no requested-ratio inversion');
like($source,
    qr/set_hailo_channel_ratio\(\$self,\s*\$target_chan,\s*\$ratio\)/,
    'command passes the direct requested percentage to persistence');

open my $cfh, '<', "$Bin/../../Mediabot/ChannelCommands.pm" or die $!;
my $channel_source = <$cfh>;
close $cfh;
like($channel_source,
    qr/set_hailo_channel_ratio\(\$self,\s*\$target_channel,\s*97\)/,
    'enabling HailoChatter keeps the direct 97% default');

done_testing();
