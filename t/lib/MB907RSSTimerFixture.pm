package MB907RSSTimerFixture;
use strict;
use warnings;
use Scalar::Util qw(refaddr weaken);
use Time::HiRes ();
use IO::Async::Loop;
use IO::Async::Timer::Countdown;
use Mediabot::RSS::Runtime;

{
    package MB907::Log;
    sub log {push @{$_[0]{lines}},$_[2]}
    package MB907::Pacing;
    sub status {{active=>$_[0]{active}//0,wait=>0}}
    sub rotation_order {$_[2]}
    sub reserve {{allowed=>1}}
    package MB907::IRC;
    sub is_connected {1}
    package MB907::Repo;
    sub is_feed_enabled {1}
    sub paced_pending_items {my ($s,$id)=@_;return [{item_key=>$s->{latest}{$id}}]}
    sub mark_announced {my ($s,$id,$keys)=@_;push @{$s->{acks}},[$id,@$keys];1}
    package MB907::Runtime;
    our @ISA=('Mediabot::RSS::Runtime');
    sub _parent_repo {$_[0]{fixture_repo}}
    package MB907::Timer;
    sub start {my ($s)=@_;$s->{started}++;$s->{cb}->($s) if $s->{inline};die "fixture start failure\n" if $s->{fail};1}
    sub stop {$_[0]{stopped}++;die "fixture stop failure\n" if $_[0]{stop_fail};1}
    package MB907::Loop;
    sub add {my ($s,$t)=@_;push @{$s->{timers}},$t;die "fixture add failure\n" if $s->{add_fail};1}
    sub remove {my ($s,$t)=@_;push @{$s->{removed}},$t;die "fixture remove failure\n" if $s->{remove_fail};my $hook=delete $s->{remove_hook};$hook->() if $hook;1}
}
sub _context {
    my ($native)=@_;
    my $loop=$native ? IO::Async::Loop->new : bless({timers=>[],removed=>[]},'MB907::Loop');
    my $policy=bless {active=>0},'MB907::Pacing';
    my $bot={logger=>bless({lines=>[]},'MB907::Log'),irc=>bless({},'MB907::IRC')};
    my $r=MB907::Runtime->new(bot=>$bot,loop=>$loop,pacing=>$policy,output_delay=>0.1);
    $r->{fixture_repo}=bless {acks=>[],latest=>{}},'MB907::Repo';
    return ($r,$loop,$policy);
}
sub _enqueue {
    my ($r,$channel,@ids)=@_;
    my @items=map {{item_key=>sprintf('%064x',$_),line=>"article $_"}} @ids;
    $r->{fixture_repo}{latest}{1}=$items[0]{item_key} if @items;
    return $r->_enqueue_announcements(feed_id=>1,channel=>$channel,items=>\@items);
}
sub _index_ok {
    my ($r)=@_;my %want;
    for my $q (values %{$r->{outq}}) {$want{$_->{qid}}=1 for @{$q->{items}}}
    return join(',',sort keys %want) eq join(',',sort keys %{$r->{queued}});
}
sub _one {
    my ($case)=@_;
    my ($r,$loop,$policy)=_context($case eq 'native');
    my (@sent,@times,@timers,@warnings,$error,$ok);my $fail='';my $inline=0;
    no warnings qw(redefine once);
    local *Mediabot::Helpers::botPrivmsg=sub {push @sent,$_[2];push @times,Time::HiRes::time();1};
    my $original=IO::Async::Timer::Countdown->can('new');
    local *IO::Async::Timer::Countdown::new=sub {
        return $original->(@_) if $case eq 'native';
        my ($class,%args)=@_;
        die "fixture constructor failure\n" if $fail eq 'new';
        my $t=bless {cb=>$args{on_expire},fail=>$fail eq 'start',inline=>$inline,stop_fail=>$case eq 'cleanup_errors'},'MB907::Timer';
        push @timers,$t;return $t;
    };
    {local $SIG{__WARN__}=sub {push @warnings,@_};
     $ok=eval {
        if ($case eq 'native') {
            my $t0=Time::HiRes::time();_enqueue($r,'#test',1,2,3);
            my $end=$t0+2;
            while (@sent<3 && Time::HiRes::time()<$end) {$loop->loop_once(0.02)}
            @sent==3 && join(',',@sent) eq 'article 1,article 2,article 3'
                && $times[1]-$times[0]>=0.08 && $times[2]-$times[1]>=0.08 && Time::HiRes::time()-$t0>=0.18 && !keys(%{$r->{outq}}) && !keys(%{$r->{queued}})
                && @{$r->{fixture_repo}{acks}}==3;
        }
        elsif ($case =~ /^failure_(new|add|start)$/ || $case eq 'cleanup_errors') {
            $fail=$case eq 'cleanup_errors'?'start':$1;
            $loop->{remove_fail}=1 if $case eq 'cleanup_errors';$loop->{add_fail}=1 if $fail eq 'add';
            my $accepted=eval {_enqueue($r,'#test',1,2,3);1};
            my $contained=$accepted && @sent==1 && !keys(%{$r->{outq}}) && !keys(%{$r->{queued}})
                && @{$r->{fixture_repo}{acks}}==1;
            my $clean=$fail eq 'new' || ($timers[0]{stopped} && @{$loop->{removed}});
            my $old=$timers[0];my $inert=eval {$old->{cb}->($old) if $old;@sent==1};
            $fail='';$loop->{add_fail}=0;$loop->{remove_fail}=0;
            _enqueue($r,'#test',2,3);
            my $fresh=$timers[-1];$fresh->{cb}->($fresh) if $fresh;
            $contained && $clean && $inert && join(',',@sent) eq 'article 1,article 2,article 3'
                && @{$r->{fixture_repo}{acks}}==3 && !keys(%{$r->{outq}}) && _index_ok($r);
        }
        elsif ($case eq 'duplicate_expiry') {
            _enqueue($r,'#test',1,2,3);my $old=$timers[0];
            $old->{cb}->($old);my $next=$r->{outq}{'#test'}{timer};
            $old->{cb}->($old);
            my $kept=@sent==2 && $r->{outq}{'#test'}{timer}==$next;
            $next->{cb}->($next);
            $kept && @sent==3 && @{$r->{fixture_repo}{acks}}==3 && _index_ok($r);
        }
        elsif ($case eq 'stale_mode') {
            _enqueue($r,'#test',1,2);my $old=$timers[0];
            $policy->{active}=1;_enqueue($r,'#test',3);
            $policy->{active}=0;_enqueue($r,'#test',4,5);my $next=$r->{outq}{'#test'}{timer};
            my $n=@sent;$old->{cb}->($old);
            my $kept=@sent==$n && $r->{outq}{'#test'}{timer}==$next;
            $next->{cb}->($next);
            $kept && $sent[-1] eq 'article 5' && _index_ok($r);
        }
        elsif ($case eq 'expiry_cleanup_reentry') {
            _enqueue($r,'#test',1,2,3);my $old=$timers[0];
            $loop->{remove_hook}=sub {_enqueue($r,'#test',4)};
            $old->{cb}->($old);
            @sent==2 && join(',',@sent) eq 'article 1,article 2' && $r->{outq}{'#test'}{timer} && _index_ok($r);
        }
        elsif ($case eq 'failure_cleanup_reentry') {
            $fail='start';
            $loop->{remove_hook}=sub {$fail='';_enqueue($r,'#test',4,5)};
            eval {_enqueue($r,'#test',1,2,3)};
            my $next=$r->{outq}{'#test'}{timer};my $old=$timers[0];$old->{cb}->($old);
            my $kept=$next && $r->{outq}{'#test'}{timer}==$next && join(',',@sent) eq 'article 1,article 4';
            $next->{cb}->($next) if $next;
            $kept && join(',',@sent) eq 'article 1,article 4,article 5' && _index_ok($r);
        }
        elsif ($case eq 'inline_expiry' || $case eq 'inline_expiry_then_throw') {
            $inline=1;$fail='start' if $case eq 'inline_expiry_then_throw';_enqueue($r,'#test',1,2,3);
            @sent==3 && !keys(%{$r->{outq}}) && !keys(%{$r->{queued}});
        }
        elsif ($case eq 'retained_callback_release') {
            _enqueue($r,'#test',1,2);my $old=$timers[0];$old->{cb}->($old);
            my $weak=$r;weaken($weak);undef $r;
            my $released=!defined($weak);$old->{cb}->($old);
            $released && @sent==2;
        }
        elsif ($case eq 'paced_has_no_timer') {
            $policy->{active}=1;_enqueue($r,'#test',1,2,3);
            @sent==1 && !@timers && _index_ok($r);
        }
        else {die 'unknown timer case'}
     };$error=$@;}
    return {case=>$case,ok=>$ok && !@warnings && !$error?1:0,sent=>\@sent,
        (@warnings?(warnings=>\@warnings):()),($error?(error=>$error):())};
}
sub run_contracts {return [map {_one($_)} qw(native failure_new failure_add failure_start cleanup_errors duplicate_expiry stale_mode expiry_cleanup_reentry failure_cleanup_reentry inline_expiry inline_expiry_then_throw retained_callback_release paced_has_no_timer)]}
1;
