# t/cases/582_mb363_liquidsoap_line_injection_guard.t
# =============================================================================
# mb363 — Une commande Liquidsoap Telnet doit rester sur une seule ligne.
#
# command() ajoutait "\nquit\n" à une chaîne fournie par les wrappers. Un CR/LF
# dans un chemin MP3 ou dans LIQUIDSOAP_QUEUE_ID pouvait donc injecter une
# deuxième commande avant quit. Le garde doit rejeter CR, LF et NUL avant même
# toute tentative de connexion, tout en conservant les commandes normales.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP ();
use Mediabot::Liquidsoap;

sub _slurp_582 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $liq = Mediabot::Liquidsoap->new(
        host     => '127.0.0.1',
        port     => 9,
        queue_id => 'mediabot_queue',
        timeout  => 1,
    );

    my $socket_attempts = 0;
    {
        no warnings 'redefine';
        local *IO::Socket::INET::new = sub {
            $socket_attempts++;
            die "network must not be reached for rejected commands\n";
        };

        my ($ok_lf, $err_lf) = $liq->command("mediabot_queue.queue\nserver.shutdown");
        $assert->ok(!$ok_lf, 'LF injection is rejected');
        $assert->like($err_lf, qr/unsafe Liquidsoap command/,
            'LF rejection returns an explicit error');

        my ($ok_cr, $err_cr) = $liq->command("mediabot_queue.queue\rserver.shutdown");
        $assert->ok(!$ok_cr, 'CR injection is rejected');
        $assert->like($err_cr, qr/CR, LF and NUL/,
            'CR rejection names the forbidden controls');

        my ($ok_nul, $err_nul) = $liq->command("mediabot_queue.push /tmp/a\x00.mp3");
        $assert->ok(!$ok_nul, 'NUL injection is rejected');
        $assert->like($err_nul, qr/CR, LF and NUL/,
            'NUL rejection uses the same central guard');

        my ($ok_uri, $err_uri) = $liq->push("/srv/radio/song.mp3\nmediabot_queue.skip");
        $assert->ok(!$ok_uri, 'push wrapper cannot bypass the line guard');
        $assert->like($err_uri, qr/unsafe Liquidsoap command/,
            'malicious URI is rejected by command()');

        my $bad_qid = Mediabot::Liquidsoap->new(
            host     => '127.0.0.1',
            port     => 9,
            queue_id => "mediabot_queue\nserver.shutdown",
            timeout  => 1,
        );
        my ($ok_qid, $err_qid) = $bad_qid->queue();
        $assert->ok(!$ok_qid, 'malicious queue id cannot inject another command');
        $assert->like($err_qid, qr/unsafe Liquidsoap command/,
            'queue-id injection is rejected centrally');
    }

    $assert->is($socket_attempts, 0,
        'all unsafe commands are rejected before opening a socket');

    my ($ok_empty, $err_empty) = $liq->command('');
    $assert->ok(!$ok_empty, 'empty-command guard remains active');
    $assert->is($err_empty, 'empty Liquidsoap command',
        'empty-command error remains unchanged');

    my $src = _slurp_582(File::Spec->catfile('.', 'Mediabot', 'Liquidsoap.pm'));
    $assert->like($src, qr/mb363-B1/,
        'tag mb363-B1 is present in Liquidsoap.pm');
    $assert->like($src, qr/if \$command =~ \/\[\\r\\n\\x00\]\//,
        'central command guard checks CR, LF and NUL');

    my $guard_pos  = index($src, q{if $command =~ /[\r\n\x00]/;});
    my $socket_pos = index($src, 'IO::Socket::INET->new(');
    $assert->ok($guard_pos >= 0 && $socket_pos > $guard_pos,
        'line-injection guard runs before socket creation');

    $assert->like($src,
        qr/my \$payload = \$command \. "\\nquit\\n";/,
        'normal protocol payload remains command plus quit');

    # MB915: use real loopback TCP sockets and the real command write/read.
    # A reset is staged at the constructor boundary; only the probe process
    # can receive the default SIGPIPE. The surrounding test runner stays alive.
    my $probe=<<'MB915_PROBE';
use strict;
use warnings;
use IO::Socket::INET;
use Socket qw(SOL_SOCKET SO_LINGER);
use Scalar::Util qw(refaddr);
use JSON::PP qw(encode_json);
use Mediabot::Liquidsoap;
{
    package MB915Logger;
    sub log { push @{$_[0]{rows}}, [$_[1],$_[2]]; }
}
my $kind=shift(@ARGV) // die 'method required';
my @methods=qw(command push queue skip flush_and_skip);
my @rows;
my $constructor=IO::Socket::INET->can('new');
for my $method ($kind eq 'healthy' ? @methods : ($kind)) {
    for my $mode (qw(DEFAULT IGNORE callback)) {
        my $signal_calls=0;
        my $handler=$mode eq 'callback' ? sub {$signal_calls++} : $mode;
        local $SIG{PIPE}=$handler;
        local $SIG{ALRM}=sub {die "MB915 socket probe deadline\n"};
        alarm 8;
        my $listener=$constructor->('IO::Socket::INET', LocalAddr=>'127.0.0.1',
            LocalPort=>0,Proto=>'tcp',Listen=>1) or die "listen: $!";
        my $port=$listener->sockport;
        my ($client,$peer);
        my $healthy=$kind eq 'healthy';
        my %body=(command=>'custom reply',push=>'0',queue=>'37 38',skip=>'',flush_and_skip=>'ERROR: queue unavailable');
        my %command=(command=>'custom.status',push=>'mediabot_queue.push /fixture/track.mp3',
            queue=>'mediabot_queue.queue',skip=>'mediabot_queue.skip',flush_and_skip=>'mediabot_queue.flush_and_skip');
        my $log=bless {rows=>[]},'MB915Logger';
        my (@warnings,@reply);
        {
            no warnings 'redefine';
            local *IO::Socket::INET::new=sub {
                my ($class,%args)=@_;
                # accept() also creates an empty socket via new().
                return $constructor->(@_) unless exists $args{PeerHost};
                $client=$constructor->(@_) or die "connect: $!";
                $peer=$listener->accept or die "accept: $!";
                if ($healthy) {
                    $peer->autoflush(1);
                    print {$peer} $body{$method}."\r\nEND\r\nBye!\r\nEND\r\n" or die "reply: $!";
                    shutdown($peer,1) or die "half-close: $!";
                } else {
                    setsockopt($peer,SOL_SOCKET,SO_LINGER,pack('ii',1,0)) or die "linger: $!";
                    close $peer;
                    # Consume the reset before returning the real client socket.
                    # The command's real print then encounters EPIPE deterministically.
                    my $n=sysread($client,my $ignored,1);
                    die 'reset returned data' if defined($n) && $n;
                }
                return $client;
            };
            local $SIG{__WARN__}=sub {push @warnings,@_};
            my $liq=Mediabot::Liquidsoap->new(host=>'127.0.0.1',port=>$port,timeout=>1,logger=>$log);
            @reply=$method eq 'command' ? $liq->command('custom.status')
                : $method eq 'push' ? $liq->push('/fixture/track.mp3') : $liq->$method();
        }
        my $after=$SIG{PIPE};
        my $restored=ref($handler) ? ref($after) eq 'CODE' && refaddr($after)==refaddr($handler)
            : defined($after) && !ref($after) && $after eq $handler;
        my $wire='';
        if ($healthy) {
            while (1) {my $n=sysread($peer,my $chunk,4096);die "capture: $!" unless defined $n;last unless $n;$wire.=$chunk;}
            close $peer;
        }
        close $listener;
        alarm 0;
        my $ok=$restored && !$signal_calls && !@warnings && @reply==2 && !defined(fileno($client));
        if ($healthy) {
            $ok &&= $wire eq $command{$method}."\nquit\n" && $reply[1] eq $body{$method}
                && $reply[0]==($method eq 'flush_and_skip' ? 0 : 1) && !@{$log->{rows}};
        } else {
            $ok &&= !$reply[0] && $reply[1]=~/\Awrite failed to 127\.0\.0\.1:\Q$port\E:/
                && @{$log->{rows}}==1 && $log->{rows}[0][0]==1
                && $log->{rows}[0][1] eq 'Liquidsoap: '.$reply[1];
        }
        push @rows,{method=>$method,signal=>$mode,ok=>$ok?1:0};
    }
}
print encode_json({rows=>\@rows});
MB915_PROBE
    my $root=dirname(dirname(abs_path($INC{'Mediabot/Liquidsoap.pm'})));
    for my $method (qw(command push queue skip flush_and_skip healthy)) {
        open my $run,'-|',$^X,'-I'.$root,'-e',$probe,$method or die $!;
        my $raw=do {local $/;<$run> // ''};
        close $run;my $status=$?;
        my $result=eval {JSON::PP::decode_json($raw)};
        my $rows=ref($result) eq 'HASH' ? $result->{rows} : undef;
        my $count=$method eq 'healthy' ? 15 : 3;
        my $ok=$status==0 && ref($rows) eq 'ARRAY' && @$rows==$count
            && !grep {!$_->{ok}} @$rows;
        $assert->ok($ok,"mb915: $method preserves socket outcomes and caller signal handlers")
            or warn "MB915 probe $method failed: status=$status\n";
    }
};
