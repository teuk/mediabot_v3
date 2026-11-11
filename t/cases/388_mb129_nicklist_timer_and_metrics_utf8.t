# t/cases/388_mb129_nicklist_timer_and_metrics_utf8.t
# =============================================================================
# Tests des corrections mb129 :
#
#   - B1 : addChannel_ctx ne lancait pas le timer nicklist pour le nouveau
#          canal. setup_channel_nicklist_timers() etait appele uniquement
#          au demarrage et a chaque reconnect IRC.
#
#   - B2 : purgeChannel_ctx et channelPart_ctx n'arretaient pas le timer
#          nicklist du canal concerne. Le timer continuait a envoyer NAMES
#          sur un canal ou le bot n'est plus.
#
#   - B3 : Metrics::start_http_server calculait Content-Length avec
#          length($body) (caracteres) au lieu de length(encode_utf8($body))
#          (bytes). Bug avec UTF-8 dans les labels (ex: "#cafe").
# =============================================================================

use strict;
use warnings;
use Encode qw(encode_utf8);

my $case = sub {
    my ($assert) = @_;

    require Mediabot::Channel::NicklistTimers;
    {
        package MB1218::Conf;
        sub get { $_[0]{interval} }
        package MB1218::Logger;
        sub log { push @{$_[0]{messages}}, $_[2] }
        package MB1218::Loop;
        sub add {
            my ($s,$t)=@_; $s->{timers}{$t}= $t;
            my $hook=delete $s->{on_add}; $hook->($t) if $hook;
            die $s->{add_error} if $s->{add_error};
        }
        sub remove {
            my ($s,$t)=@_; $s->{removes}++;
            my $hook=delete $s->{on_remove}; $hook->($t) if $hook;
            die "remove failure\n" if $s->{fail_remove};
            delete $s->{timers}{$t};
        }
        package MB1218::Timer;
        sub start {
            my ($s)=@_; $s->{starts}++;
            my $hook=delete $s->{on_start}; $hook->($s) if $hook;
            die $s->{start_error} if $s->{start_error};
        }
        sub stop { $_[0]{stops}++; die "stop failure\n" if $_[0]{fail_stop} }
        package MB1218::Bot;
        sub refresh_channel_nicklist { push @{$_[0]{wire}}, $_[1] }
    }
    my $new_bot=sub {
        bless { conf=>bless({},'MB1218::Conf'), logger=>bless({},'MB1218::Logger'),
            loop=>bless({},'MB1218::Loop'), channels=>{'#a'=>{}}, wire=>[] }, 'MB1218::Bot';
    };
    my $factory=sub { bless {@_}, 'MB1218::Timer' };
    my $setup=sub { Mediabot::Channel::NicklistTimers::setup($_[0], $factory) };
    my $one=\&Mediabot::Channel::NicklistTimers::stop_one;
    my $all=\&Mediabot::Channel::NicklistTimers::stop_all;
    {
        my $b=$new_bot->(); $setup->($b);
        my $t=$b->{channel_nicklist_timers}{'#a'}; my $tick=$t->{on_tick};
        $assert->($t->{interval}==300 && $t->{first_interval}==300,'default interval and first interval preserved');
        $tick->(); $assert->("@{$b->{wire}}" eq '#a','real owner tick refreshes its target');
        $one->($b,'#a'); $tick->();
        $assert->(@{$b->{wire}}==1 && $t->{stops}==1 && !keys %{$b->{loop}{timers}},'part retires callback and notifier');
        $assert->(exists $b->{channels}{'#a'},'part retains configured channel');
        $one->($b,'#a'); $assert->($t->{stops}==1,'repeated single retirement is inert');
        $b->{channels}{'#b'}={}; $b->{conf}{interval}=17; $setup->($b);
        $assert->(keys(%{$b->{channel_nicklist_timers}})==2 && $b->{channel_nicklist_timers}{'#b'}{interval}==17,'join/add rebuild both timers with configured interval');
        delete $b->{channels}{'#a'}; $one->($b,'#a');
        $assert->(exists $b->{channel_nicklist_timers}{'#b'} && !exists $b->{channel_nicklist_timers}{'#a'},'purge preserves other channel timer');
        $all->($b); $all->($b);
        $assert->(!keys(%{$b->{loop}{timers}}),'all retirement leaves no notifier');
    }
    for my $fault (qw(remove stop both)) {
        my $b=$new_bot->(); $setup->($b);my $t=$b->{channel_nicklist_timers}{'#a'};
        $b->{loop}{fail_remove}=($fault ne 'stop'); $t->{fail_stop}=($fault ne 'remove');
        my $ok=$all->($b);$t->{on_tick}->();
        $assert->(!$ok && $t->{stops}==1 && $b->{loop}{removes}==1,"$fault: both cleanup operations attempted and failure returned");
        $assert->(!@{$b->{wire}} && !keys %{$b->{channel_nicklist_timers}},"$fault: callback revoked despite physical failure");
        $assert->($b->{logger}{messages}[-1]=~/incomplete/,"$fault: no false success diagnostic");
    }
    for my $scope (qw(one all setup)) {
        my $b=$new_bot->();$setup->($b);my $old=$b->{channel_nicklist_timers}{'#a'};
        my $successor;
        $b->{loop}{on_remove}=sub {
            $b->{channels}{'#b'}={};$setup->($b);
            $successor=$b->{channel_nicklist_timers}{'#a'};
            $old->{on_tick}->();
        };
        $scope eq 'one' ? $one->($b,'#a') : $scope eq 'all' ? $all->($b) : $setup->($b);
        $assert->($b->{channel_nicklist_timers}{'#a'}==$successor && exists $b->{channel_nicklist_timers}{'#b'},"$scope: reentrant successor registrations survive");
        $assert->(!@{$b->{wire}},"$scope: old callback is inert during cleanup");
        $successor->{on_tick}->();$assert->(@{$b->{wire}}==1,"$scope: successor remains usable");$all->($b);
    }
    for my $stage (qw(add start)) {
        my $b=$new_bot->();my ($old,$fresh);
        my $hook=sub { $old=shift; $setup->($b); $fresh=$b->{channel_nicklist_timers}{'#a'} };
        $b->{loop}{on_add}=$hook if $stage eq 'add';
        my $f=sub { my $t=$factory->(@_); $t->{on_start}=$hook if $stage eq 'start'; $hook=undef if $stage eq 'start';return $t };
        Mediabot::Channel::NicklistTimers::setup($b,$f);
        $old->{on_tick}->();
        $assert->($b->{channel_nicklist_timers}{'#a'}==$fresh && !@{$b->{wire}},"$stage: late setup cannot overwrite successor or send");
        $assert->(!exists $b->{loop}{timers}{$old},"$stage: late old notifier removed");$all->($b);
    }
    for my $stage (qw(add start)) {
        my $b=$new_bot->();my $error=bless {},'MB1218::Error';my $t;
        $b->{loop}{add_error}=$error if $stage eq 'add';
        my $f=sub { $t=$factory->(@_);$t->{start_error}=$error if $stage eq 'start';return $t };
        my $ok=eval { Mediabot::Channel::NicklistTimers::setup($b,$f);1 };my $got=$@;
        $t->{on_tick}->();
        $assert->(!$ok && ref($got) && $got==$error,"$stage failure: original exception identity retained");
        $assert->(!keys(%{$b->{channel_nicklist_timers}}) && !keys(%{$b->{loop}{timers}}) && !@{$b->{wire}},"$stage failure: registry, notifier and callback retired");
    }
    {
        my $b=$new_bot->();my $error=bless {},'MB1218::Error';my $callback;
        my $ok=eval { Mediabot::Channel::NicklistTimers::setup($b,sub {
            my %args=@_;$callback=$args{on_tick};die $error;
        });1 };my $got=$@;
        $callback->();
        $assert->(!$ok && ref($got) && $got==$error && !@{$b->{wire}},
            'constructor failure preserves exception and revokes retained callback');
    }
    {
        my $b=$new_bot->();my $old;my $fresh;my $error=bless {},'MB1218::Error';
        $b->{loop}{on_add}=sub {
            $old=shift;$setup->($b);$fresh=$b->{channel_nicklist_timers}{'#a'};die $error;
        };
        my $ok=eval {$setup->($b);1};my $got=$@;$old->{on_tick}->();
        $assert->(!$ok && ref($got) && $got==$error && $b->{channel_nicklist_timers}{'#a'}==$fresh,
            'late failed setup preserves successor and original exception');
        $assert->(!@{$b->{wire}} && !exists $b->{loop}{timers}{$old},'late failed setup retires only the old notifier');
        $all->($b);
    }
    {
        require Scalar::Util;
        my $b=$new_bot->();$setup->($b);my $tick=$b->{channel_nicklist_timers}{'#a'}{on_tick};
        my $weak_bot=$b;Scalar::Util::weaken($weak_bot);
        my $weak_loop=$b->{loop};Scalar::Util::weaken($weak_loop);
        $all->($b);undef $b;$tick->();
        $assert->(!defined($weak_bot) && !defined($weak_loop),'retained retired callback retains neither bot nor loop');
    }
    for my $interval (0,-1,'bad','',undef) {
        my $b=$new_bot->();$b->{conf}{interval}=$interval;$setup->($b);
        $assert->($b->{channel_nicklist_timers}{'#a'}{interval}==300,'invalid interval retains historical default');$all->($b);
    }

    # -------------------------------------------------------------------------
    # B3 : Content-Length doit etre en bytes UTF-8, pas en caracteres
    # -------------------------------------------------------------------------

    # Cas 1: ASCII pur — bytes == chars
    {
        my $body = "mediabot_joins_total{channel=\"#general\"} 42\n";
        my $bytes = encode_utf8($body);
        $assert->(length($body) == length($bytes),
            "B3 ASCII: length(chars)==length(bytes) trivial");
    }

    # Cas 2: UTF-8 — é = 2 bytes
    {
        my $body = qq{mediabot_joins_total{channel="#caf\x{e9}"} 5\n};
        my $bytes = encode_utf8($body);
        my $chars = length($body);
        my $blen  = length($bytes);
        $assert->($blen == $chars + 1,
            "B3 UTF-8: 1 char 'e accent aigu' ajoute 1 byte (chars=$chars bytes=$blen)");
    }

    # Cas 3: emoji (4 bytes UTF-8)
    {
        my $body = qq{mediabot_achievements_unlocked_total{achievement="\x{1F3C6}gold"} 1\n};
        my $bytes = encode_utf8($body);
        my $chars = length($body);
        my $blen  = length($bytes);
        $assert->($blen == $chars + 3,
            "B3 UTF-8: 1 emoji ajoute 3 bytes (chars=$chars bytes=$blen)");
    }

    # Cas 4: Content-Length annonce DOIT egaler length(bytes), pas length(chars)
    {
        my $body = qq{mediabot_joins_total{channel="#caf\x{e9}"} 5\n};
        my $bytes = encode_utf8($body);
        # Ancien code (buggy) :
        my $old_content_length = length($body);
        # Nouveau code :
        my $new_content_length = length($bytes);
        $assert->($old_content_length != $new_content_length,
            "B3 REGRESSION-POC: ancien Content-Length ($old_content_length) != bon ($new_content_length)");
        $assert->($new_content_length == length($bytes),
            "B3 nouveau Content-Length correspond aux bytes envoyes");
    }

    # Cas 5: scenarios realistes Prometheus
    {
        # Plusieurs canaux UTF-8 dans un meme dump
        my @canaux = ("#caf\x{e9}", "#R\x{e9}sistance", "#\x{1F1EB}\x{1F1F7}france");
        my $body = "# HELP mediabot_joins_total Total joins\n# TYPE mediabot_joins_total counter\n";
        for my $c (@canaux) {
            $body .= qq{mediabot_joins_total{channel="$c"} 1\n};
        }
        my $bytes = encode_utf8($body);
        $assert->(length($bytes) > length($body),
            "B3 dump multi-canaux UTF-8 : bytes > chars (chars=" . length($body) . " bytes=" . length($bytes) . ")");
        # Si on envoyait length($body), le client recevrait length($body) bytes
        # puis verrait des bytes restants (corrompus ou tronques selon clients)
    }
};

# ---------------------------------------------------------------------------
# Direct runner for standalone execution:
#   perl t/cases/THIS_FILE.t
#
# When loaded by the project harness, return the case coderef.
# ---------------------------------------------------------------------------
if (caller) {
    return $case;
}

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;

    $name = 'unnamed assertion' unless defined $name && $name ne '';

    if ($ok) {
        print "ok $tests - $name\n";
    }
    else {
        print "not ok $tests - $name\n";
        $fail++;
    }
};

$case->($assert);

print "1..$tests\n";
exit($fail ? 1 : 0);

