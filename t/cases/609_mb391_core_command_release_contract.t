# t/cases/609_mb391_core_command_release_contract.t
# =============================================================================
# MB391: release-critical core commands must answer locally, report one process
# uptime, and queue multi-line help output instead of producing NOTICE bursts.
# =============================================================================

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

BEGIN {
    no warnings 'redefine';
    # mb525-B2: fallbacks installed through runtime glob assignments only.
    # Named `sub` declarations inside a stub `package` block are compiled
    # unconditionally and used to overwrite the real modules (notably
    # IO::Async::Timer::Countdown) for every later test in the shared harness.
    no strict 'refs';

    eval { require JSON::MaybeXS; 1 } or do {
        require JSON::PP;
        *{'JSON::MaybeXS::import'} = sub {
            my $caller = caller;
            *{"${caller}::encode_json"} = \&JSON::PP::encode_json;
            *{"${caller}::decode_json"} = \&JSON::PP::decode_json;
        };
        $INC{'JSON/MaybeXS.pm'} = __FILE__;
    };

    eval { require Try::Tiny; 1 } or do {
        *{'Try::Tiny::import'} = sub { return 1 };
        $INC{'Try/Tiny.pm'} = __FILE__;
    };

    eval { require IO::Async::Timer::Countdown; 1 } or do {
        *{'IO::Async::Timer::Countdown::new'}   = sub { bless { @_[1 .. $#_] }, $_[0] };
        *{'IO::Async::Timer::Countdown::start'} = sub { $_[0]->{started} = 1; 1 };
        *{'IO::Async::Timer::Countdown::stop'}  = sub { $_[0]->{stopped} = 1; 1 };
        $INC{'IO/Async/Timer/Countdown.pm'} = __FILE__;
    };

    eval { require IO::Async::Stream; 1 } or do {
        *{'IO::Async::Stream::new'} = sub { bless {}, shift };
        $INC{'IO/Async/Stream.pm'} = __FILE__;
    };
}

sub _slurp_mb391 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb391 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $quote;
    my $escape  = 0;
    my $comment = 0;

    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }

        if (defined $quote) {
            if ($escape) {
                $escape = 0;
            }
            elsif ($ch eq '\\') {
                $escape = 1;
            }
            elsif ($ch eq $quote) {
                undef $quote;
            }
            $pos++;
            next;
        }

        if ($ch eq '#') {
            $comment = 1;
        }
        elsif ($ch eq q{'}) {
            $quote = q{'};
        }
        elsif ($ch eq q{"}) {
            $quote = q{"};
        }
        elsif ($ch eq '{') {
            $depth++;
        }
        elsif ($ch eq '}') {
            $depth--;
            return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $root = abs_path('.');
    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');
    my $main_file    = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    my $admin_file   = File::Spec->catfile($root, 'Mediabot', 'AdminCommands.pm');
    my $channel_file = File::Spec->catfile($root, 'Mediabot', 'ChannelCommands.pm');
    my $context_file = File::Spec->catfile($root, 'Mediabot', 'Context.pm');
    my $party_file   = File::Spec->catfile($root, 'Mediabot', 'Partyline.pm');

    my $helpers = _slurp_mb391($helpers_file);
    my $main    = _slurp_mb391($main_file);
    my $admin   = _slurp_mb391($admin_file);
    my $channel = _slurp_mb391($channel_file);
    my $context = _slurp_mb391($context_file);
    my $party   = _slurp_mb391($party_file);

    my $version = _extract_sub_mb391($helpers, 'versionCheck');
    my $queue   = _extract_sub_mb391($helpers, 'queueBotNotices');
    my $uptime  = _extract_sub_mb391($main, 'mbUptime_ctx');
    my $status  = _extract_sub_mb391($admin, 'mbStatus_ctx');
    my $showcmd = _extract_sub_mb391($channel, 'userShowcommandsChannel_ctx');
    my $helpq   = _extract_sub_mb391($main, '_mbHelpSendNoticeQueue');
    my $pl_up   = _extract_sub_mb391($party, '_cmd_uptime');

    $assert->ok(defined $version, 'versionCheck body found');
    $assert->ok(defined $queue, 'shared NOTICE queue body found');
    $assert->ok(defined $uptime, 'public uptime body found');
    $assert->ok(defined $status, 'status body found');
    $assert->ok(defined $showcmd, 'showcommands body found');
    $assert->ok(defined $helpq, 'help queue adapter body found');
    $assert->ok(defined $pl_up, 'Partyline uptime body found');

    my $reply_pos = index($version // '', '$ctx->reply("$bot_name version: $local_version")');
    my $async_pos = index($version // '', 'getVersion_async(');
    $assert->ok(
        $reply_pos >= 0 && $async_pos > $reply_pos,
        'version replies from local identity before scheduling GitHub work'
    );

    $assert->like(
        $version // '',
        qr/update available: \$remote_version/,
        'remote update information is a separate follow-up'
    );

    $assert->like(
        $uptime // '',
        qr/getProcessStartTimestamp\(\$self\)/,
        'm uptime uses the shared process start timestamp'
    );
    $assert->like(
        $status // '',
        qr/getProcessStartTimestamp\(\$self\)/,
        'm status uses the same process start timestamp'
    );
    $assert->like(
        $pl_up // '',
        qr/getProcessStartTimestamp\(\$bot,\s*\$now\)/,
        'Partyline uptime uses the same process start timestamp'
    );

    $assert->like(
        $showcmd // '',
        qr/return\s+queueBotNotices\(\$self,\s*\$nick,\s*\@lines\)/,
        'level-filtered command listing is sent through the shared queue'
    );
    $assert->unlike(
        $showcmd // '',
        qr/botNotice\(\$self,\s*\$nick,\s*"Level\s+500:/,
        'showcommands no longer emits one immediate NOTICE per access level'
    );
    $assert->like(
        $helpq // '',
        qr/return\s+queueBotNotices\(\$self,\s*\$nick,\s*\@lines\)/,
        'all categorized help output delegates to the same queue'
    );
    $assert->like(
        $queue // '',
        qr/my\s+\$max_lines\s*=\s*16/,
        'NOTICE queue has a strict per-request line budget'
    );
    $assert->like(
        $queue // '',
        qr/my\s+\$base_delay\s*=.*?\@\$timers/s,
        'concurrent help requests are serialized after pending lines'
    );

    $assert->like(
        $context,
        qr/return\s+\$chan\s*!~\s*\/\^\[#&!\+\]\//,
        'Context recognizes every standard IRC channel prefix'
    );

    require $helpers_file;
    require $context_file;

    my $start_bot = {
        metrics              => { started => 100 },
        _start_time          => 200,
        iConnectionTimestamp => 900,
    };
    $assert->is(
        Mediabot::Helpers::getProcessStartTimestamp($start_bot, 1000),
        100,
        'process uptime prefers Metrics start over reconnect timestamp'
    );

    delete $start_bot->{metrics};
    $assert->is(
        Mediabot::Helpers::getProcessStartTimestamp($start_bot, 1000),
        200,
        'process uptime falls back to explicit process start'
    );

    my $ctx_plus = Mediabot::Context->new(channel => '+modeless');
    my $ctx_local = Mediabot::Context->new(channel => '&local');
    my $ctx_priv = Mediabot::Context->new(channel => 'SomeNick');
    $assert->ok(!$ctx_plus->is_private, '+channel is routed as a channel');
    $assert->ok(!$ctx_local->is_private, '&channel is routed as a channel');
    $assert->ok($ctx_priv->is_private, 'nickname target remains private');

    {
        package MB391::Loop;
        sub new { bless { added => [], removed => [] }, shift }
        sub add { push @{ $_[0]->{added} }, $_[1]; 1 }
        sub remove { push @{ $_[0]->{removed} }, $_[1]; 1 }
    }
    {
        package MB391::Bot;
        sub getLoop { $_[0]->{loop} }
    }
    {
        package MB391::Timer;
        sub new { my ($class, %args) = @_; bless \%args, $class }
        sub start { $_[0]->{started} = 1; 1 }
        sub stop { $_[0]->{stopped} = 1; 1 }
    }

    my $loop = MB391::Loop->new;
    my $queue_bot = bless { loop => $loop }, 'MB391::Bot';
    my @sent;

    no warnings 'redefine';
    local *IO::Async::Timer::Countdown::new = sub {
        shift;
        return MB391::Timer->new(@_);
    };
    local *Mediabot::Helpers::botNotice = sub {
        my ($bot, $nick, $line) = @_;
        push @sent, "$nick:$line";
        return 1;
    };

    Mediabot::Helpers::queueBotNotices($queue_bot, 'Teuk', qw(one two three));
    $assert->is(scalar(@sent), 0, 'queued help does not burst immediately');
    $assert->is(scalar(@{ $loop->{added} }), 3, 'one timer is scheduled per help line');
    $assert->is($loop->{added}[0]{delay}, 0, 'first queued line is immediate');
    $assert->is($loop->{added}[1]{delay}, 1.5, 'second queued line is delayed');
    $assert->is($loop->{added}[2]{delay}, 3, 'third queued line is delayed again');

    Mediabot::Helpers::queueBotNotices($queue_bot, 'Teuk', qw(four five));
    $assert->is($loop->{added}[3]{delay}, 4.5, 'second request starts after pending lines');
    $assert->is($loop->{added}[4]{delay}, 6, 'second request remains rate-limited');

    for my $timer (sort { $a->{delay} <=> $b->{delay} } @{ $loop->{added} }) {
        $timer->{on_expire}->();
    }
    $assert->is(join(',', @sent), 'Teuk:one,Teuk:two,Teuk:three,Teuk:four,Teuk:five',
        'queued lines preserve order');
    $assert->is(scalar(@{ $queue_bot->{_notice_queue_timers} }), 0,
        'expired queue timers are removed from tracking');
};
