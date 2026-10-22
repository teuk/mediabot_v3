package MB900PipeFixture;
use strict;
use warnings;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use JSON::PP ();
use File::Basename qw(dirname);

our ($surface,$mode,$last_pid,$resolver_launches);

# Installed only in the fresh probe interpreter, before loading real owners.
# Replace the external DNS producer, retaining its real Perl '-|' pipe and
# every parent-side stream, timer, wait and signal operation.
sub install_open_hook {
    return unless @ARGV && $ARGV[0] =~ /\A(?:resolve|reverse-dns)\z/;
    no warnings qw(redefine once);
    *CORE::GLOBAL::open = sub (*;$@) {
        if (@_ >= 5 && defined($_[1]) && $_[1] eq '-|'
                && $_[2] eq $^X && $_[3] eq '-e'
                && $_[4] =~ /gethostby(?:name|addr)/) {
            $resolver_launches++;
            my $program = q{
                use strict; use warnings; use POSIX (); use Time::HiRes qw(sleep);
                my ($surface,$mode)=@ARGV;
                if ($mode eq 'early-eof') {
                    $SIG{TERM}='IGNORE';close STDOUT;sleep 5;POSIX::_exit(0);
                }
                print $surface eq 'resolve' ? '192.0.2.1' : 'resolved.invalid';
                exit($mode eq 'exit-failure' ? 2 : 0);
            };
            my $result=CORE::open($_[0], '-|', $^X, '-e', $program, $surface, $mode);
            $last_pid=$result if defined($result) && $result>0;
            return $result;
        }
        my $result = @_ == 1 ? CORE::open($_[0])
                   : @_ == 2 ? CORE::open($_[0], $_[1])
                   : CORE::open($_[0], $_[1], @_[2..$#_]);
        $last_pid=$result if @_>=2 && defined($_[1]) && $_[1] eq '-|'
            && defined($result) && $result>0;
        return $result;
    };
}

sub probe {
    my ($surface,$mode)=@_;
    my $err=gensym;
    my $pid=open3(undef,my $out,$err,$^X,'-I.','-It/lib','-I'.dirname(__FILE__),
        '-MMB900PipeFixture','-e',
        'BEGIN {MB900PipeFixture::install_open_hook()} MB900PipeFixture::child_main(@ARGV)',
        $surface,$mode);
    my $stdout=do {local $/;<$out>//''};
    my $stderr=do {local $/;<$err>//''};
    waitpid($pid,0);
    my $status=$?;
    my $data=eval {JSON::PP::decode_json($stdout)};
    return {ok=>0,detail=>"status=$status stderr=$stderr stdout=$stdout"}
        if $status || length($stderr) || ref($data) ne 'HASH';
    return $data;
}

{
    package MB900PipeFixture::Log;
    sub log {my($s,@m)=@_;push @{$s->{lines}},\@m;1}
    package MB900PipeFixture::Conf;
    sub get {$_[1] eq 'main.PARTYLINE_EVAL_ENABLED' ? 1
        : $_[1] eq 'main.PARTYLINE_EVAL_TIMEOUT_SECONDS' ? 1 : undef}
    package MB900PipeFixture::Bot;
    sub getLoop {$_[0]{loop}}
    package MB900PipeFixture::Context;
    sub bot {$_[0]{bot}}
    sub nick {'probe'}
    sub channel {'#test'}
    sub args {['host.invalid']}
    sub message {undef}
    package MB900PipeFixture::Stream;
    sub write {my($s,$text)=@_;push @{$s->{lines}},$text;1}
    package MB900PipeFixture::Party;
    sub _broadcast {1}
    sub _write_runtime_status {1}
}

sub child_main {
    ($surface,$mode)=@_;
    require IO::Async::Loop;
    require IO::Async::Timer::Countdown;
    require Time::HiRes;
    require POSIX;
    require Mediabot::Helpers;
    require Mediabot::External::Country;
    require Mediabot::UserCommands if $surface eq 'define';
    require Mediabot::External::YouTube if $surface eq 'youtube';
    require Mediabot::Partyline::Privileged if $surface eq 'eval';
    require Mediabot::Partyline::SessionAuth if $surface eq 'reverse-dns';

    my $loop=IO::Async::Loop->new;
    my $bot=bless {loop=>$loop,conf=>bless({},'MB900PipeFixture::Conf'),
        logger=>bless({lines=>[]},'MB900PipeFixture::Log')},'MB900PipeFixture::Bot';
    my (@callbacks,@warnings,@ticks,@lines,$return,$exception,$party);
    local $SIG{__WARN__}=sub {push @warnings,@_};
    my $start=Time::HiRes::time();
    my $heartbeat=IO::Async::Timer::Countdown->new(delay=>0.05,on_expire=>sub {
        push @ticks,Time::HiRes::time()-$start;
    });
    $loop->add($heartbeat);$heartbeat->start;
    my $producer=sub {
        if ($mode eq 'early-eof') {
            $SIG{TERM}='IGNORE';close STDOUT;Time::HiRes::sleep(5);POSIX::_exit(0);
        }
        return $surface eq 'country' ? 'FR'
             : $surface eq 'define' ? 'definition accepted'
             : {ok=>1,status=>'ok',entries=>[{id=>'abcdefghijk',title=>'accepted'}]};
    };
    {
        no warnings qw(redefine once);
        local *Mediabot::Helpers::whereis=$producer;
        local *Mediabot::UserCommands::_define_lookup_sync=$producer;
        local *Mediabot::External::YouTube::_youtube_search_fetch_sync=$producer;
        local *Mediabot::Helpers::botPrivmsg=sub {push @lines,$_[2]};
        local *Mediabot::Helpers::logBot=sub {1};
        eval {
            if ($surface eq 'country') {
                $return=Mediabot::Helpers::whereis_async($bot,'unused.invalid',
                    sub {push @callbacks,[@_]},timeout=>($mode eq 'nominal'?2:0.1));
            }
            elsif ($surface eq 'define') {
                $return=Mediabot::UserCommands::_define_lookup_async($bot,'probe','en',
                    sub {push @callbacks,[@_]},timeout=>($mode eq 'nominal'?2:0.1));
            }
            elsif ($surface eq 'youtube') {
                $return=Mediabot::External::YouTube::_youtube_search_fetch_async($bot,'fixture','probe',
                    sub {push @callbacks,[@_]},timeout=>($mode eq 'nominal'?2:0.1));
            }
            elsif ($surface eq 'resolve') {
                my $ctx=bless {bot=>$bot},'MB900PipeFixture::Context';
                $return=Mediabot::Helpers::resolve_ctx($ctx);
            }
            elsif ($surface eq 'reverse-dns') {
                $party=bless {loop=>$loop,bot=>$bot,users=>{probe=>{peer_host=>'192.0.2.1'}}},'MB900PipeFixture::Party';
                $return=Mediabot::Partyline::SessionAuth::_schedule_reverse_dns_lookup(
                    $party,'probe','192.0.2.1',$mode eq 'early-eof'?0.25:2);
            }
            elsif ($surface eq 'eval') {
                my $output=bless {lines=>\@lines},'MB900PipeFixture::Stream';
                $party=bless {bot=>$bot,streams=>{probe=>$output},users=>{probe=>{level=>0,login=>'probe'}}},'MB900PipeFixture::Party';
                my $code=$mode eq 'early-eof'
                    ? q{alarm 0; $SIG{ALRM}='IGNORE'; $SIG{TERM}='IGNORE'; close STDOUT; close STDERR; select undef,undef,undef,5; POSIX::_exit(0)}
                    : q{'eval accepted'};
                Mediabot::Partyline::Privileged::_cmd_eval($party,$output,'probe',$code);
                @lines=();
                $return=Mediabot::Partyline::Privileged::_cmd_eval($party,$output,'probe',$code);
            }
            else {die 'unknown surface'}
            1;
        } or $exception=$@;

        my $deadline=Time::HiRes::time()+7;
        while (Time::HiRes::time()<$deadline && !$exception) {
            my $done=$surface eq 'reverse-dns'
                ? !keys %{$party->{_reverse_dns_lookups}//{}}
                : $surface eq 'eval'
                    ? scalar(grep {/--- (?:ok|error|timeout) ---/} @lines)
                    : $surface eq 'resolve' ? scalar(@lines) : scalar(@callbacks);
            last if $done;
            $loop->loop_once(0.02);
        }
        my $grace_end=Time::HiRes::time()+($surface eq 'eval' && $mode eq 'early-eof' ? 0.65 : 0.08);
        $loop->loop_once(0.01) while Time::HiRes::time()<$grace_end;
    }
    my $elapsed=Time::HiRes::time()-$start;
    my $reap=waitpid(-1,POSIX::WNOHANG());
    my $success;
    if ($surface eq 'country') {
        $success=@callbacks==1 && $callbacks[0][0] eq ($mode eq 'nominal'?'FR':'N/A');
    }
    elsif ($surface eq 'define') {
        $success=@callbacks==1 && $callbacks[0][0] eq ($mode eq 'nominal'
            ? 'definition accepted' : "define: could not fetch definition for 'probe'.");
    }
    elsif ($surface eq 'youtube') {
        $success=@callbacks==1 && ref($callbacks[0][0]) eq 'HASH'
            && $callbacks[0][0]{status} eq ($mode eq 'nominal'?'ok':'worker_timeout');
    }
    elsif ($surface eq 'resolve') {
        $success=@lines==1 && $lines[0] eq ($mode eq 'nominal'
            ? '(probe) host.invalid => 192.0.2.1'
            : $mode eq 'exit-failure' ? '(probe) DNS lookup failed for: host.invalid'
            : '(probe) DNS lookup timed out for: host.invalid');
    }
    elsif ($surface eq 'reverse-dns') {
        $success=$party->{users}{probe}{peer_host} eq ($mode eq 'nominal'?'resolved.invalid':'192.0.2.1')
            && !keys %{$party->{_reverse_dns_lookups}//{}};
    }
    elsif ($surface eq 'eval') {
        $success=$mode eq 'nominal' ? (grep {/eval accepted/} @lines) && (grep {/--- ok ---/} @lines)
            : (grep {/Eval timed out after 1s/} @lines) && !(grep {/--- ok ---/} @lines);
    }
    my $ok=$success && !defined($exception) && !@warnings && $reap==-1 && @ticks==1 && $ticks[0]<1;
    $ok&&=$elapsed<($surface eq 'resolve' && $mode eq 'early-eof'?4.3:3);
    $ok&&=$resolver_launches==1 if $surface eq 'resolve' || $surface eq 'reverse-dns';
    # A failing probe must still clean up its own surviving child.
    if ($reap==0 && $last_pid) {kill 'KILL',$last_pid;waitpid($last_pid,0)}
    my $data={ok=>$ok?1:0,surface=>$surface,mode=>$mode,callbacks=>\@callbacks,lines=>\@lines,
        exception=>$exception,warnings=>\@warnings,child_check=>$reap,elapsed=>$elapsed,
        heartbeat=>\@ticks,peer_host=>$party ? $party->{users}{probe}{peer_host} : undef,
        resolver_launches=>$resolver_launches//0};
    $data->{detail}=JSON::PP->new->canonical->encode($data);
    print JSON::PP->new->canonical->encode($data);
}

1;
