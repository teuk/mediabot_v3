# t/cases/535_mb313_partyline_async_reverse_dns.t
# =============================================================================
# MB313:
#   - Partyline reverse DNS must not run synchronously in the IRC event loop;
#   - telnet and DCC sessions keep the IP immediately, then update peer_host;
#   - resolver children are timeout-bounded and reaped with WNOHANG;
#   - stale callbacks cannot update a reused file descriptor.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb313 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb313 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my $start = $-[0];
    my $pos   = pos($src);
    my $depth = 1;

    while ($pos < length($src)) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        $depth-- if $char eq '}';
        return substr($src, $start, $pos + 1 - $start)
            if $depth == 0;
        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb313(
        File::Spec->catfile('.', 'Mediabot', 'Partyline.pm')
    );

    my $compat = _extract_sub_mb313($src, '_reverse_dns_timeout');
    my $async  = _extract_sub_mb313($src, '_schedule_reverse_dns_lookup');
    my $dcc    = _extract_sub_mb313($src, '_init_dcc_session');
    my $listen = _extract_sub_mb313($src, '_start_listener');

    $assert->ok(defined $compat, 'compatibility reverse-DNS helper found');
    $assert->ok(defined $async, 'asynchronous reverse-DNS helper found');
    $assert->ok(defined $dcc, 'DCC session initializer found');
    $assert->ok(defined $listen, 'telnet listener found');

    $assert->unlike(
        $compat // '',
        qr/gethostbyaddr\s*\(/,
        'compatibility helper no longer performs blocking reverse DNS'
    );

    $assert->like(
        $async // '',
        qr/gethostbyaddr\s*\(/,
        'blocking resolver call is isolated inside the child program'
    );

    $assert->like(
        $async // '',
        qr/open\s*\(\s*my\s+\$pipe\s*,\s*'-\|'/s,
        'reverse DNS is executed through a child-process pipe'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Stream->new/,
        'resolver output is consumed asynchronously'
    );

    $assert->like(
        $async // '',
        qr/waitpid\(\$child_pid,\s*WNOHANG\)/,
        'resolver child is reaped without blocking'
    );

    $assert->unlike(
        $async // '',
        qr/waitpid\(\$child_pid,\s*0\)/,
        'resolver helper contains no unconditional blocking waitpid'
    );

    $assert->like(
        $async // '',
        qr/IO::Async::Timer::Countdown->new/,
        'resolver timeout and reap polling use asynchronous timers'
    );

    $assert->like(
        $async // '',
        qr/kill\s+'TERM',\s*\$child_pid/,
        'resolver timeout first sends TERM'
    );

    $assert->like(
        $async // '',
        qr/kill\s+'KILL',\s*\$child_pid/,
        'resolver timeout can escalate to KILL'
    );

    $assert->like(
        $async // '',
        qr/\$current\s*==\s*\$state->\{session_ref\}/,
        'callback verifies that the session object is still the same'
    );

    $assert->like(
        $async // '',
        qr/reverse_dns_lookup_key/,
        'callback uses a unique lookup key to guard fd reuse'
    );

    $assert->like(
        $async // '',
        qr/\$current->\{peer_host\}\s*=\s*\$host/,
        'successful lookup updates the existing peer_host field'
    );

    $assert->like(
        $dcc // '',
        qr/peer_host\s*=>\s*\$peer_host/,
        'DCC session exposes the peer IP immediately'
    );

    $assert->like(
        $dcc // '',
        qr/_schedule_reverse_dns_lookup\(\$id,\s*\$peer_host,\s*2\)/,
        'DCC session schedules reverse DNS asynchronously'
    );

    $assert->like(
        $listen // '',
        qr/peer_host\s*=>\s*\$peer_ip/,
        'telnet session exposes the peer IP immediately'
    );

    $assert->like(
        $listen // '',
        qr/_schedule_reverse_dns_lookup\(\$id,\s*\$peer_ip,\s*2\)/,
        'telnet session schedules reverse DNS asynchronously'
    );

    my @legacy_calls = ($src =~ /(?<!sub )_reverse_dns_timeout\s*\(/g);
    $assert->is(
        scalar @legacy_calls,
        1,
        'only the compatibility declaration comment mentions the old helper call syntax'
    );

    my ($resolver_code) = ($async // '') =~
        /my\s+\$resolver_code\s*=\s*<<'RESOLVER';\n(.*?)\nRESOLVER/s;

    $assert->ok(
        defined($resolver_code) && length($resolver_code),
        'embedded resolver child program extracted'
    );

    if (defined $resolver_code) {
        open my $fh, '-|', $^X, '-c', '-e', $resolver_code
            or die "could not compile resolver child: $!";
        local $/;
        my $compile_output = <$fh> // '';
        close $fh;
        my $rc = $? >> 8;

        $assert->is($rc, 0, 'embedded resolver child program compiles');
        $assert->like(
            $resolver_code,
            qr/use\s+Socket\s+qw\(inet_aton\s+AF_INET\)/,
            'resolver child imports only supported Socket symbols'
        );
    }
    else {
        $assert->ok(0, 'embedded resolver child program compiles');
        $assert->ok(0, 'resolver child imports only supported Socket symbols');
    }
};
