use strict;
use warnings;
use Mediabot::VDM::Runtime;
use Mediabot::AsyncWorker ();
use IO::Async::Loop;
use Time::HiRes ();

{
    package MB848::RuntimeFetcher;
    sub new {bless {calls => [], launch => undef}, shift}
    sub fetch {
        my ($self, %args) = @_;
        push @{$self->{calls}}, \%args;
        return $self->{launch} ? $self->{launch}->($args{on_done}) : 1;
    }
    package MB848::VDMCtx;
    sub channel {'#maintenance'}
    sub nick {'Tester'}
    sub args {[]}
    package MB848::VDMLogger;
    sub log {push @{$_[0]{lines}}, $_[2]}
}
sub mb848_runtime_result {
    return {ok => 1, items => [{id => $_[0], story => 'Offline maintenance story. VDM'}]};
}
return sub {
    my ($a) = @_;
    for my $mode (qw(manual spark)) {
        for my $ending (qw(throw refuse)) {
            my (@sent, @notices, @logs);
            my $bot = {enabled => 1, connected => 1, joined => 1,
                logger => bless({lines => \@logs}, 'MB848::VDMLogger')};
            my $fetcher = MB848::RuntimeFetcher->new;
            my $runtime = Mediabot::VDM::Runtime->new(bot => $bot, fetcher => $fetcher,
                now_cb => sub {1000}, chanset_cb => sub {$_[0]{enabled}},
                connected_cb => sub {$_[0]{connected}}, joined_cb => sub {$_[0]{joined}},
                notice_cb => sub {push @notices, $_[2]; 1}, send_cb => sub {push @sent, $_[2]; 1});
            my $ctx = bless {}, 'MB848::VDMCtx';
            my $start = sub {
                return $runtime->request_manual($ctx) if $mode eq 'manual';
                return $runtime->request_spark(channel => '#maintenance',
                    activity_current_cb => sub {1}, spark_enabled_cb => sub {1},
                    deliver_cb => sub {push @sent, $_[0]{id}; return {action => 'sent'}});
            };
            $fetcher->{launch} = sub {die "secret synthetic source launch failure\n" if $ending eq 'throw'; return 0};
            my $returned;
            my $ok = eval {$returned = $start->(); 1};
            $a->ok($ok, "mb848: $mode $ending is contained at the runtime boundary");
            $a->is($returned // -1, $mode eq 'manual' ? 1 : 0, "mb848: $mode $ending preserves handled/refused contract");
            $a->ok(!$runtime->channel_pending('#maintenance'), "mb848: $mode $ending releases channel reservation");
            $a->is(scalar @sent, 0, "mb848: $mode $ending emits no public story");
            $a->is(scalar @notices, $mode eq 'manual' ? 1 : 0, "mb848: $mode $ending has one bounded manual refusal only");
            $a->unlike(join('\n', @logs, @notices), qr/secret synthetic/, "mb848: $mode $ending never exposes exception text");
            my $old = $fetcher->{calls}[0]{on_done};
            $fetcher->{launch} = undef;
            $a->ok($start->(), "mb848: $mode $ending permits immediate next request");
            $a->is(scalar @{$fetcher->{calls}}, 2, "mb848: $mode $ending recovery reaches fetcher");
            $old->(mb848_runtime_result(10));
            $a->is(scalar @sent, 0, "mb848: $mode $ending late failed callback stays silent");
            $a->ok($runtime->channel_pending('#maintenance'), "mb848: $mode $ending old callback preserves successor slot");
            $fetcher->{calls}[-1]{on_done}->(mb848_runtime_result(11));
            $a->is(scalar @sent, 1, "mb848: $mode $ending successor delivers normally");
            $a->ok(!$runtime->channel_pending('#maintenance'), "mb848: $mode $ending successor frees channel");
        }

        # A completed callback may start another request before the launcher's
        # return or exception. The outer failure cannot disturb that successor.
        for my $ending (qw(refuse throw)) {
            my (@sent, @notices);
            my $bot = {enabled => 1}; my $fetcher = MB848::RuntimeFetcher->new;
            my ($start, $reenter, $successor);
            my $runtime = Mediabot::VDM::Runtime->new(bot => $bot, fetcher => $fetcher,
                chanset_cb => sub {$_[0]{enabled}}, connected_cb => sub {1}, joined_cb => sub {1},
                notice_cb => sub {push @notices, $_[2]; 1},
                send_cb => sub {push @sent, $_[2]; if ($reenter) {$reenter = 0; $successor = $start->()} 1});
            $start = sub {
                return $runtime->request_manual(bless({}, 'MB848::VDMCtx')) if $mode eq 'manual';
                return $runtime->request_spark(channel => '#maintenance', activity_current_cb => sub {1},
                    spark_enabled_cb => sub {1}, deliver_cb => sub {
                        push @sent, $_[0]{id}; if ($reenter) {$reenter = 0; $successor = $start->()} return {action => 'sent'};
                    });
            };
            $reenter = 1;
            $fetcher->{launch} = sub {
                my ($done) = @_; $fetcher->{launch} = undef;
                $done->(mb848_runtime_result(20));
                die 'private post-completion exception' if $ending eq 'throw'; return 0;
            };
            my $ok = eval {$start->(); 1};
            $a->ok($ok, "mb848: $mode inline/$ending contains terminal launcher failure");
            $a->ok($successor && $runtime->channel_pending('#maintenance'), "mb848: $mode inline/$ending keeps reentrant successor");
            $a->is(scalar @sent, 1, "mb848: $mode inline/$ending delivers original exactly once");
            $a->is(scalar @notices, 0, "mb848: $mode inline/$ending avoids a contradictory failure notice");
            $fetcher->{calls}[0]{on_done}->(mb848_runtime_result(21));
            $a->is(scalar @sent, 1, "mb848: $mode inline/$ending replay cannot consume successor");
            # Final rights still apply to recovered work.
            $bot->{enabled} = 0;
            $fetcher->{calls}[-1]{on_done}->(mb848_runtime_result(22));
            $a->is(scalar @sent, 1, "mb848: $mode inline/$ending revocation blocks successor output");
            $a->ok(!$runtime->channel_pending('#maintenance'), "mb848: $mode inline/$ending revoked successor releases capacity");
            undef $start;
        }
    }

    # Actual Runtime -> AsyncFetcher -> fork/pipe -> final delivery boundary.
    # Two channels share the feed, but revocation remains per requesting channel.
    my $loop = IO::Async::Loop->new; my @delivered;
    my $real = Mediabot::VDM::AsyncFetcher->new(loop => $loop,
        fetch_cb => sub {return mb848_runtime_result(81)});
    my $bot = {enabled => {'#first' => 1, '#second' => 1}};
    my $runtime = Mediabot::VDM::Runtime->new(bot => $bot, fetcher => $real,
        chanset_cb => sub {$_[0]{enabled}{$_[1]}}, connected_cb => sub {1}, joined_cb => sub {1},
        notice_cb => sub {die 'unexpected manual path'}, send_cb => sub {die 'unexpected direct output'});
    for my $channel ('#first', '#second') {
        $a->ok($runtime->request_spark(channel => $channel, activity_current_cb => sub {1},
            spark_enabled_cb => sub {1}, deliver_cb => sub {
                push @delivered, [$channel, $_[0]{id}]; return {action => 'sent'};
            }), 'mb848: actual Spark request starts on permitted channel');
    }
    $a->is($real->waiter_count, 2, 'mb848: actual runtime requests share feed with distinct waiters');
    $bot->{enabled}{'#first'} = 0;
    my $deadline = Time::HiRes::time() + 5;
    $loop->loop_once(0.02) while $real->inflight && Time::HiRes::time() < $deadline;
    $a->is(scalar @delivered, 1, 'mb848: only still-permitted channel receives child story');
    $a->is(join(',', @{$delivered[0] || []}), '#second,81', 'mb848: coalesced result reaches correct channel only');
    $a->ok(!$runtime->channel_pending('#first') && !$runtime->channel_pending('#second'),
        'mb848: delivered and revoked real requests both release channel reservations');
    $a->ok(!$real->inflight && !$real->waiter_count, 'mb848: integrated completion releases all worker capacity');
};
