# t/cases/336_antiflood_nickflood_sliding_notice.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub _slurp_336 {
    open my $fh, '<:raw', $_[0] or die $!;
    local $/;
    return <$fh>;
}

sub _sub_336 {
    my ($src, $name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;
    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

package MB897ThrottleConf;
sub get { $_[0]{$_[1]} }
package MB897ThrottleLog;
sub log { push @{$_[0]{calls}}, [@_[1..$#_]]; 1 }
package MB897ThrottleMetrics;
sub inc { $_[0]{$_[1]}++; 1 }
package main;

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;
    require Mediabot::IRC::CommandThrottle;

    for my $order (
        [qw(IRC::CommandThrottle)],
        [qw(IRC::CommandThrottle Helpers)],
        [qw(Helpers IRC::CommandThrottle)],
    ) {
        my $code = q{our $now = 1_700_000_000;
            BEGIN { *CORE::GLOBAL::time = sub { $main::now }; }
        } . join('', map { "require Mediabot::$_;\n" } @$order);
        $code .= q{
            package ColdThrottleConf897;
            sub get { return 1 if $_[1] =~ /(?:CHANFLOOD_MAX_COMMANDS|NICKFLOOD_MAX_COMMANDS)$/; undef }
            package ColdThrottleLog897;
            sub log { 1 }
            package ColdThrottleDB897;
            sub prepare { die 'unexpected SQL' }
            package main;
            my $cold = !exists $INC{'Mediabot/Helpers.pm'};
            Mediabot::IRC::CommandThrottle->import(qw(_af_conf_int checkCmdCooldown checkChanFlood checkNickFlood));
            my (@console, @notice);
            my $bot = {conf=>bless({}, 'ColdThrottleConf897'),
                logger=>bless({}, 'ColdThrottleLog897'), dbh=>bless({}, 'ColdThrottleDB897')};
            {
            no warnings qw(redefine once);
            local *Mediabot::Helpers::noticeConsoleChan = sub { push @console, [@_[1..$#_]]; 1 };
            local *Mediabot::Helpers::botNotice = sub { push @notice, [@_[1..$#_]]; 1 };
            die 'config reader failed' unless _af_conf_int($bot, 'CHANFLOOD_MAX_COMMANDS', 8, 1, 1000) == 1;
            die 'channel threshold failed' unless checkChanFlood($bot, '#test') == 0
                && checkChanFlood($bot, '#test') == 1 && @console == 1;
            $now += 29;
            die 'channel silence failed' unless checkChanFlood($bot, '#test') == 1
                && @{$bot->{_chan_flood}{'#test'}{hits}} == 2;
            $now++;
            die 'channel expiry failed' unless checkChanFlood($bot, '#test') == 0;
            die 'nick threshold failed' unless checkNickFlood($bot, 'Reader', '#test') == 0;
            for (1..3) {die 'nick burst allowed' unless checkNickFlood($bot, 'READER', '#test') == 1;}
            die 'nick mute or notice failed' unless $bot->{_nick_mute}{reader} == $now + 300
                && checkNickFlood($bot, 'reader', '#test') == 1 && @notice == 1;
            $now += 300;
            die 'nick expiry failed' unless checkNickFlood($bot, 'reader', '#test') == 0
                && !exists $bot->{_nick_mute}{reader};
            die 'news bucket failed' unless checkCmdCooldown($bot, '#test', 'actualites') == 0
                && checkCmdCooldown($bot, '#TEST', 'news') == 45;
            die 'unexpected dependency load' if $cold && (exists $INC{'Mediabot/Helpers.pm'}
                || exists $INC{'HTTP/Tiny.pm'} || exists $INC{'DBI.pm'});
            }
            require Mediabot::Helpers;
            die 'legacy state diverged' unless Mediabot::Helpers::checkCmdCooldown($bot, '#test', 'actu') == 45;
            print 'loaded';
        };
        my $err = gensym;
        my $pid = open3(undef, my $out, $err, $^X, '-I.', '-It/lib', '-we', $code);
        my $stdout = do { local $/; <$out> } // '';
        my $stderr = do { local $/; <$err> } // '';
        waitpid($pid, 0);
        $assert->ok($? == 0 && $stdout eq 'loaded' && $stderr eq '',
            'throttle thresholds/expiry work in load order: ' . join('/', @$order)
                . ($stderr eq '' ? '' : ": $stderr"));
    }
    {
        no warnings 'redefine';
        my (@keys, @console);
        local *Mediabot::Helpers::_af_conf_int = sub {
            push @keys, $_[1]; return 1 if $_[1] eq 'CHANFLOOD_MAX_COMMANDS';
            return 1_000_000 if $_[1] eq 'CHANFLOOD_WINDOW'; return $_[2];
        };
        local *Mediabot::Helpers::noticeConsoleChan = sub {push @console, [@_[1..$#_]]; 1};
        my $bot = {logger=>bless({calls=>[]}, 'MB897ThrottleLog')};
        my @r = (Mediabot::IRC::CommandThrottle::checkChanFlood($bot, '#test'),
            Mediabot::Helpers::checkChanFlood($bot, '#test'));
        $assert->ok(join(',', @r) eq '0,1' && @console == 1
                && $console[0][0] =~ /Chan flood detected on #test/
                && join('|', @keys) eq join('|', (qw(CHANFLOOD_WINDOW CHANFLOOD_MAX_COMMANDS CHANFLOOD_SILENCE CHANFLOOD_NOTIFY_COOLDOWN)) x 2),
            'canonical channel guard keeps legacy config/console hooks and shares state with Helpers');
    }
    {
        no warnings 'redefine';
        my @notice;
        local *Mediabot::Helpers::botNotice = sub {push @notice, ['first', @_[1..$#_]]; 1};
        my $bot = {conf=>bless({'antiflood.NICKFLOOD_MAX_COMMANDS'=>1,
                    'antiflood.NICKFLOOD_WINDOW'=>3600}, 'MB897ThrottleConf'),
            logger=>bless({calls=>[]}, 'MB897ThrottleLog'),
            metrics=>bless({}, 'MB897ThrottleMetrics')};
        my @r = (Mediabot::IRC::CommandThrottle::checkNickFlood($bot, 'Reader', '#test'),
            Mediabot::Helpers::checkNickFlood($bot, 'READER', '#test'));
        $bot->{_nick_flood}{reader}{notified_at} = 0;
        local *Mediabot::Helpers::botNotice = sub {push @notice, ['second', @_[1..$#_]]; 1};
        push @r, Mediabot::IRC::CommandThrottle::checkNickFlood($bot, 'reader', '#test');
        push @r, Mediabot::Helpers::checkNickFlood($bot, 'Reader', '#test');
        push @r, Mediabot::IRC::CommandThrottle::checkNickFlood($bot, 'READER', '#test');
        $assert->ok(join(',', @r) eq '0,1,1,1,1' && @notice == 2
                && $notice[0][0] eq 'first' && $notice[1][0] eq 'second'
                && $notice[0][1] eq 'READER' && $notice[1][1] eq 'reader'
                && $bot->{metrics}{mediabot_nickflood_blocks_total} == 3
                && $bot->{metrics}{mediabot_nickflood_mutes_total} == 1
                && @{$bot->{_nick_flood}{reader}{hits}} == 4,
            'nick guard preserves late notice replacement, shared lowercase strikes/mute and metrics');
    }
    {
        my $bot = {logger=>bless({calls=>[]}, 'MB897ThrottleLog')};
        my @r = (Mediabot::IRC::CommandThrottle::checkCmdCooldown($bot, '#test', 'actualites'),
            Mediabot::Helpers::checkCmdCooldown($bot, '#TEST', 'news'),
            Mediabot::IRC::CommandThrottle::checkCmdCooldown($bot, '#test', 'actu'));
        $assert->ok($r[0] == 0 && $r[1] > 0 && $r[1] <= 45 && $r[2] > 0
                && keys(%{$bot->{_cmd_cooldown}}) == 1
                && exists $bot->{_cmd_cooldown}{'actualites:#test'},
            'canonical and historical cooldowns keep the single parent-side news alias bucket');
    }

    my $helpers = _slurp_336(File::Spec->catfile('.', 'Mediabot', 'IRC', 'CommandThrottle.pm'));
    my $body = _sub_336($helpers, 'checkNickFlood');

    $assert->ok(defined $body, 'checkNickFlood body found');
    $assert->like($body // '', qr/NICKFLOOD_WINDOW/, 'checkNickFlood reads NICKFLOOD_WINDOW');
    $assert->like($body // '', qr/NICKFLOOD_MAX_COMMANDS/, 'checkNickFlood reads NICKFLOOD_MAX_COMMANDS');
    $assert->like($body // '', qr/NICKFLOOD_NOTIFY_COOLDOWN/, 'checkNickFlood reads NICKFLOOD_NOTIFY_COOLDOWN');
    $assert->like($body // '', qr/NICKFLOOD_STATE_TTL/, 'checkNickFlood reads NICKFLOOD_STATE_TTL');
    $assert->like($body // '', qr/push\s+\@\{\s*\$state->\{hits\}\s*\},\s*\$now/s,
        'checkNickFlood pushes timestamps into sliding window');
    $assert->like($body // '', qr/grep\s*\{\s*\(\$now\s*-\s*\$_\)\s*<\s*\$window\s*\}/s,
        'checkNickFlood prunes timestamps outside sliding window');
    $assert->like($body // '', qr/botNotice\(\$self,\s*\$nick/s,
        'checkNickFlood notifies user on cooldown');
    $assert->like($body // '', qr/mediabot_nickflood_blocks_total/,
        'checkNickFlood increments metric');
};
