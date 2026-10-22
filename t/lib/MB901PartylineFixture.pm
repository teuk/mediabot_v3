package MB901PartylineFixture;

# Run in a fresh Perl process: older catalogue cases install IO::Async stubs.
# Only listener acceptance, credentials, logging and status publication are fixtures.
# Transport callbacks, dispatcher, SQL login lookup, streams, timers and cleanup are real.
use strict;
use warnings;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Scalar::Util qw(weaken);
use IO::Async::Loop;
use IO::Async::Stream;
use Future;
use DBI;
use Mediabot::Partyline;

{
    package MB901::Logger;
    sub log { push @{$_[0]{lines}}, $_[2] }
    sub remove_console_hook { push @{$_[0]{removed}}, $_[1] }
    package MB901::Metrics;
    sub get { $_[0]{$_[1]} // 0 }
    sub add { $_[0]{$_[1]} += $_[2] }
    sub inc { $_[0]{$_[1]}++ }
    package MB901::Conf;
    sub get_int { my ($s, $key, %opt) = @_; return $key eq 'main.PARTYLINE_LOGIN_MAX_FAILURES' ? 1 : $opt{default} }
    package MB901::Auth;
    sub verify_credentials {
        my ($s, $id, $login, $pass) = @_;
        $s->{calls}++;
        return $id == 1 && $login eq 'tester' && $pass eq 'fixture-password';
    }
    package MB901::Partyline;
    our @ISA = ('Mediabot::Partyline');
    sub _write_runtime_status { $_[0]{status_writes}++ }
    package MB901::Stream;
    our @ISA = ('IO::Async::Stream');
    sub configure {
        my ($s, %args) = @_;
        $s->{test_read} = $args{on_read} if $args{on_read};
        $s->{test_closed} = $args{on_closed} if $args{on_closed};
        return $s->SUPER::configure(%args);
    }
    sub write {
        my $s = shift;
        push @{$s->{test_writes}}, $_[0];
        return $s->SUPER::write(@_);
    }
}

sub _pair {
    socketpair(my $server, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
    return (MB901::Stream->new(handle => $server), $peer, fileno($server));
}

sub _run_one {
    my ($transport, $case, $chunks) = @_;
    my $loop = IO::Async::Loop->new;
    my ($stream, $peer, $id) = _pair();
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1, PrintError => 0 });
    $dbh->do('CREATE TABLE USER (id_user INTEGER, nickname TEXT, id_user_level INTEGER)');
    $dbh->do('CREATE TABLE USER_LEVEL (id_user_level INTEGER, level INTEGER, description TEXT)');
    $dbh->do("INSERT INTO USER VALUES (1, 'tester', 1)");
    $dbh->do("INSERT INTO USER_LEVEL VALUES (1, 0, 'Owner')");
    my $log = bless { lines => [], removed => [] }, 'MB901::Logger';
    my $metrics = bless {}, 'MB901::Metrics';
    my $auth = bless { calls => 0 }, 'MB901::Auth';
    my $p = bless {
        loop => $loop, users => {}, streams => {}, motd => [],
        bot => { logger => $log, metrics => $metrics, dbh => $dbh,
                 auth => $auth, conf => bless({}, 'MB901::Conf') },
    }, 'MB901::Partyline';
    if ($transport eq 'telnet') {
        no warnings 'redefine';
        local *IO::Async::Loop::listen = sub {
            my (undef, %args) = @_;
            $args{on_stream}->($stream);
            return Future->done;
        };
        $p->_start_listener;
    }
    else {
        $p->_init_dcc_session($stream, 'tester', 'dcc');
    }
    my $gauge = 'mediabot_partyline_sessions_current';
    my $deliver = sub {
        my ($text, $eof) = @_;
        $stream->{test_read}->($stream, \$text, $eof // 0);
        return $text;
    };
    my $login_case = $case =~ /^(?:pipeline|fragment|legacy|session_limit|ip_limit)$/;
    unless ($login_case) {
        @{$p->{users}{$id}}{qw(authenticated login level)} = (1, 'tester', 0);
    }
    my ($ok, $detail, $replacement, $other_peer);
    if ($case eq 'tools') {
        require Encode;
        $p->{users}{$id}{history} = _tools_history();
        $p->{bot}{dbh} = bless {}, 'MB903::NoIO';
        $p->{bot}{db} = bless {}, 'MB903::NoIO';
        $p->{bot}{irc} = bless {}, 'MB903::NoIO';
        my $observer = bless {out => ''}, 'MB903::Buffer';
        $p->{users}{9999} = {authenticated=>1,login=>'observer',level=>1,history=>['11:00 .ping']};
        $p->{streams}{9999} = $observer;
        my $input = Encode::encode('UTF-8', ".help plugins\n.history 2\n.history find CAF\x{c9}\n.history clear\n");
        syswrite($peer,$input)==length($input) or die "short native tools write: $!";
        $loop->loop_once(0.01) for 1..10;
        my $out = join '', @{$stream->{test_writes}};
        $ok = $out =~ /Command help:/ && $out =~ /plugin lifecycle \(v2\)/
            && $out =~ /Recent commands:/ && $out =~ /Matching commands:/
            && $out =~ /Session command history cleared/
            && index($out, _tools_history()->[5]) >= 0
            && !exists($p->{users}{$id}{history}) && !$auth->{calls}
            && (()=$observer->{out}=~/\[tester\@/g)==1
            && $observer->{out} !~ /history/i
            && $p->{users}{9999}{history}[0] eq '11:00 .ping';
        delete $p->{users}{9999}; delete $p->{streams}{9999};
    }
    elsif ($case =~ /^(?:quit|flood|quit_oversize|wire_quit|wire_flood)$/) {
        my $input = $case =~ /flood$/ ? (".unknown901\n" x 30) . "NEVER-DISPATCH\n"
                  : $case eq 'quit_oversize' ? ".quit\n" . ('x' x 4097) . "\n"
                  : ".quit\nNEVER-DISPATCH\nfixture-password\n";
        if ($case =~ /^wire_/) {
            # Also drive the installed callback through IO::Async's real read path.
            syswrite($peer, $input) == length($input) or die "short fixture write: $!";
            for (1 .. 20) {
                $loop->loop_once(0.01);
                last unless $stream->read_handle;
            }
        }
        else { $deliver->($input) }
        my $out = join '', @{$stream->{test_writes}};
        my $logs = join "\n", @{$log->{lines}};
        $ok = !exists($p->{users}{$id}) && !exists($p->{streams}{$id})
            && $metrics->get($gauge) == 0 && ($p->{status_writes} // 0) == 1
            && @{$log->{removed}} == 1 && !$auth->{calls}
            && $logs !~ /NEVER-DISPATCH|fixture-password|exception/
            && $out !~ /Internal error|Input line too long|Enter your password/;
        $ok &&= $case =~ /flood$/
            ? (($p->{_rate_stats}{flood_boots} // 0) == 1
                && ($p->{_rate_stats}{silent_drops} // 0) == 18
                && (() = $out =~ /Rate limit exceeded/g) == 1
                && (() = $out =~ /Flood protection: disconnecting/g) == 1)
            : (() = $out =~ /Goodbye/g) == 1;
    }
    elsif ($case =~ /^(?:absent_read|replaced_read|replaced_eof|replaced_closed)$/) {
        $p->_close_session($id);
        if ($case ne 'absent_read') {
            ($replacement, $other_peer) = _pair();
            $p->{users}{$id} = { authenticated => 1, login => 'replacement', level => 0 };
            $p->{streams}{$id} = $replacement;
            $p->{"_eval_pending_$id"} = { marker => 'replacement' };
            $metrics->add($gauge, 1);
        }
        my $before_logs = @{$log->{lines}};
        my $before_writes = @{$stream->{test_writes}};
        if ($case eq 'replaced_closed') { $stream->{test_closed}->($stream) }
        elsif ($case eq 'replaced_eof') { $deliver->('', 1) }
        else { $deliver->(".quit\nNEVER-DISPATCH\n") }
        $ok = @{$log->{lines}} == $before_logs && @{$stream->{test_writes}} == $before_writes
            && @{$log->{removed}} == 1 && ($p->{status_writes} // 0) == 1 && !$auth->{calls};
        $ok &&= $case eq 'absent_read'
            ? (!exists($p->{users}{$id}) && !exists($p->{streams}{$id}) && $metrics->get($gauge) == 0)
            : (($p->{users}{$id}{login} // '') eq 'replacement'
                && ($p->{streams}{$id} // 0) == $replacement && $metrics->get($gauge) == 1
                && ($p->{"_eval_pending_$id"}{marker} // '') eq 'replacement');
    }
    elsif ($case eq 'normal_closed' || $case eq 'normal_eof') {
        if ($case eq 'normal_closed') { $stream->close_now }
        else { $deliver->(".unknown901\n", 1); $stream->close_now }
        $ok = !exists($p->{users}{$id}) && !exists($p->{streams}{$id})
            && $metrics->get($gauge) == 0 && ($p->{status_writes} // 0) == 1
            && @{$log->{removed}} == 1;
        # Catch an accidental stream -> on_closed -> stream reference cycle.
        $stream->{test_read} = undef;
        $stream->{test_closed} = undef;
        $deliver = undef;
        my $weak = $stream;
        weaken($weak);
        $stream = undef;
        $ok &&= !defined($weak);
    }
    elsif ($case eq 'session_limit' || $case eq 'ip_limit') {
        if ($case eq 'ip_limit') {
            $p->{users}{$id}{peer_ip} = '192.0.2.1';
            $p->{_pl_login_fail_by_ip}{'192.0.2.1'} = { count => 15, first_ts => time() };
        }
        $deliver->("login tester wrong\nlogin tester wrong\nlogin tester fixture-password\nNEVER-DISPATCH\n");
        my $out = join '', @{$stream->{test_writes}};
        my $logs = join "\n", @{$log->{lines}};
        $ok = !exists($p->{users}{$id}) && !exists($p->{streams}{$id})
            && $metrics->get($gauge) == 0 && ($p->{status_writes} // 0) == 1
            && $auth->{calls} == ($case eq 'session_limit' ? 1 : 0)
            && $out =~ /Too many authentication failures/ && $out !~ /Connected to Mediabot/
            && $logs !~ /NEVER-DISPATCH|fixture-password|exception/;
    }
    else {
        if ($chunks) {
            my $buffer = '';
            for my $chunk (@$chunks) { $buffer = $deliver->($buffer . $chunk) }
        }
        elsif ($case eq 'legacy') { $deliver->("login tester fixture-password\n.unknown901\n") }
        elsif ($case eq 'fragment') {
            my $rest = $deliver->('tes');
            $rest = $deliver->($rest . "ter\r\nfixture-");
            $deliver->($rest . "password\r\n.unknown901\r\n");
        }
        else { $deliver->("tester\r\nfixture-password\r\n.unknown901\r\n") }
        my $out = join '', @{$stream->{test_writes}};
        my $logs = join "\n", @{$log->{lines}};
        $ok = $p->{users}{$id}{authenticated} && $p->{streams}{$id} == $stream
            && $metrics->get($gauge) == 1 && $auth->{calls} == 1
            && ($p->{status_writes} // 0) == 1 && $out =~ /Connected to Mediabot Partyline/
            && $out =~ /Unknown command/ && $logs !~ /fixture-password|exception/
            && !exists($p->{users}{$id}{auth_timeout_timer});
    }
    $detail = { logs => $log->{lines}, writes => $stream ? $stream->{test_writes} : [],
        gauge => $metrics->get($gauge), auth_calls => $auth->{calls},
        user_exists => exists($p->{users}{$id}) ? 1 : 0 } unless $ok;
    # Close the original only after evaluating the assertions, especially stale callbacks.
    $stream->close_now if $stream;
    $p->_close_session($id);
    $replacement->close_now if $replacement;
    close $peer;
    close $other_peer if $other_peer;
    $dbh->disconnect;
    return { transport => $transport, case => $case, ok => $ok ? 1 : 0,
             ($detail ? (detail => $detail) : ()) };
}

sub run_all {
    my @results;
    for my $transport (qw(telnet dcc)) {
        for my $case (qw(quit flood quit_oversize wire_quit wire_flood absent_read replaced_read replaced_eof
                         replaced_closed normal_closed normal_eof pipeline fragment legacy
                         session_limit ip_limit)) {
            my (@warnings, $result);
            {
                local $SIG{__WARN__} = sub { push @warnings, @_ };
                $result = eval { _run_one($transport, $case) };
                $result = { transport => $transport, case => $case, ok => 0, error => "$@" } unless $result;
            }
            if (@warnings) { $result->{ok} = 0; $result->{warnings} = \@warnings }
            push @results, $result;
        }
    }
    return \@results;
}

# MB902: reuse the native session fixtures for incremental Telnet input.
{
    package MB902::Capture;
    our @ISA = ('MB901::Partyline');
    sub _handle_line { push @{$_[0]{frames}}, $_[3] }
}

sub _telnet_frames {
    my ($chunks, $transport, $wire) = @_;
    $transport //= 'telnet';
    my $loop = IO::Async::Loop->new;
    my ($stream, $peer, $id) = _pair();
    my $metrics = bless {}, 'MB901::Metrics';
    my $p = bless { loop => $loop, users => {}, streams => {}, frames => [],
        bot => { logger => bless({lines => [], removed => []}, 'MB901::Logger'),
                 metrics => $metrics } }, 'MB902::Capture';
    if ($transport eq 'dcc') { $p->_init_dcc_session($stream, 'tester', 'dcc') }
    else {
        no warnings 'redefine';
        local *IO::Async::Loop::listen = sub {
            my (undef, %args) = @_;
            $args{on_stream}->($stream);
            return Future->done;
        };
        $p->_start_listener;
    }
    my $callback = $stream->{test_read};
    $stream->configure(on_read => sub {
        my ($io) = @_;
        $io->{wire_reads}++;
        goto &$callback;
    }) if $wire;
    my $buffer = '';
    for my $chunk (@$chunks) {
        if ($wire) {
            next unless length $chunk;
            my $before = $stream->{wire_reads} // 0;
            syswrite($peer, $chunk) == length($chunk) or die "short Telnet fixture write: $!";
            for (1 .. 30) {
                $loop->loop_once(0.01);
                last if ($stream->{wire_reads} // 0) > $before;
            }
            die 'native Telnet read not observed' unless ($stream->{wire_reads} // 0) > $before;
        }
        else {
            $buffer .= $chunk;
            $callback->($stream, \$buffer, 0);
        }
    }
    my $result = { frames => $p->{frames}, alive => exists($p->{users}{$id}) ? 1 : 0,
                   gauge => $metrics->get('mediabot_partyline_sessions_current') };
    $stream->close_now;
    $p->_close_session($id);
    close $peer;
    return $result;
}

sub run_telnet {
    my $sb = "\xff\xfa\x1f\x00\x50\x00\x0a\xff\xf0";
    my $fake_commands = "\xff\xfa\x18\nlogin tester fixture-password\n.quit\n\xff\xf0";
    my $controls = join '', map { "\xff" . chr($_) } 240 .. 249;
    my $negotiations = join '', map { "\xff" . chr($_) . "\x0a" } 251 .. 254;
    my $utf8 = "caf\xc3\xa9";
    my $all_data = join '', map { chr($_) } grep { $_ != 10 && $_ != 13 } 0 .. 254;
    my @specs = (
        ['plain_chunks', ['tes', "ter\r", "\nnext\n"], ['tester', 'next']],
        ['negotiations', [split //, $negotiations . "tester\n"], ['tester']],
        ['subnegotiation_lf', [$sb . "tester\n"], ['tester']],
        ['subnegotiation_commands', [$fake_commands . "tester\n"], ['tester']],
        ['escaped_iac_repeated', ["a\xff\xff", "\xff\xff", "b\n"], ["a\xff\xffb"]],
        ['escaped_iac_data', ["a\xff\xff", "\xfb\x01b\n"], ["a\xff\xfb\x01b"]],
        ['escaped_iac_in_sb', ["\xff\xfa\x18\xff\xff\xf0\n.quit\n\xff\xf0tester\n"], ['tester']],
        ['two_byte_controls', [split //, "tes" . $controls . "ter\n"], ['tester']],
        ['unknown_iac_pair', ["a\xff", "\x01b\n"], ["a\xff\x01b"]],
        ['transparent_data_bytes', [split //, $all_data . "\n"], [$all_data]],
        ['utf8_chunks', [split //, $utf8 . "\xff\xfb\x01\n"], [$utf8]],
        ['exact_byte_limit', [('x' x 4095) . "\xff", "\xff\r", "\n"], [('x' x 4095) . "\xff"]],
        ['over_byte_limit', [('x' x 4096), "x\n"], [], 0],
        ['discard_large_sb', ["\xff\xfa\x18", (('p' x 8192) x 32), "\xff\xf0tester\n"], ['tester']],
        ['native_subnegotiation', [split //, $sb . "tester\n"], ['tester'], 1, 'telnet', 1],
        ['dcc_raw_data', [$sb . "tester\n"], ["\xff\xfa\x1f\x00\x50\x00", "\xff\xf0tester"], 1, 'dcc'],
    );
    my @results;
    for my $spec (@specs) {
        my ($name, $chunks, $expected, $alive, $transport, $wire) = @$spec;
        $alive //= 1;
        my (@warnings, $r, $error);
        { local $SIG{__WARN__} = sub { push @warnings, @_ };
          $r = eval { _telnet_frames($chunks, $transport, $wire) }; $error = $@; }
        my $same = $r && @{$r->{frames}} == @$expected;
        if ($same) {
            for my $i (0 .. $#$expected) { $same &&= $r->{frames}[$i] eq $expected->[$i] }
        }
        push @results, { case => $name,
            ok => $same && $r->{alive} == $alive && $r->{gauge} == $alive && !@warnings && !$error ? 1 : 0,
            (@warnings ? (warnings => \@warnings) : ()), ($error ? (error => $error) : ()) };
    }
    # Every two-chunk split of two literal protocol examples must yield the same text.
    my $split_ok = 1;
    for my $wire ($sb . "tester\n", "a\xff\xff\xff\xffb\n") {
        my $expected = $wire eq $sb . "tester\n" ? 'tester' : "a\xff\xffb";
        for my $offset (0 .. length($wire)) {
            my $r = _telnet_frames([substr($wire, 0, $offset), substr($wire, $offset)]);
            $split_ok &&= $r->{alive} && @{$r->{frames}} == 1 && $r->{frames}[0] eq $expected;
        }
    }
    push @results, { case => 'all_two_chunk_splits', ok => $split_ok ? 1 : 0 };
    my $first = _telnet_frames(["\xff\xfa\x18unfinished"]);
    my $second = _telnet_frames(["tester\n"]);
    push @results, { case => 'independent_connections',
        ok => !@{$first->{frames}} && @{$second->{frames}} == 1 && $second->{frames}[0] eq 'tester' ? 1 : 0 };
    for my $spec (
        ['login_plain', ["tester\nfixture-password\n.unknown901\n"]],
        ['login_negotiation', [split //, "\xff\xfb\x01tester\nfixture-password\n.unknown901\n"]],
        ['login_nop', ["tes\xff\xf1ter\nfixture-password\n.unknown901\n"]],
        ['login_sb', [$sb . "tester\nfixture-password\n.unknown901\n"]],
        ['login_sb_commands', [$fake_commands . "tester\nfixture-password\n.unknown901\n"]],
        ['login_sb_fragmented', [split //, $sb . "tester\nfixture-password\n.unknown901\n"]],
    ) {
        my (@warnings, $r);
        { local $SIG{__WARN__} = sub { push @warnings, @_ };
          $r = eval { _run_one('telnet', 'pipeline', $spec->[1]) };
          $r ||= { ok => 0, error => "$@" }; }
        $r->{case} = $spec->[0];
        if (@warnings) { $r->{ok} = 0; $r->{warnings} = \@warnings }
        push @results, $r;
    }
    return \@results;
}

# MB903: help/history features operate on existing per-session state only.
{
    package MB903::Buffer;
    sub write { $_[0]{out} .= $_[1]; 1 }
    package MB903::NoIO;
    our $AUTOLOAD;
    sub AUTOLOAD { die "Unexpected external operation: $AUTOLOAD\n" }
    sub DESTROY { }
}

sub _tools_history {
    require Encode;
    return [
        '10:00 .ping', '10:01 .status', '10:02 .channels',
        '10:03 .say #test literal .*', '10:04 .unknown903',
        Encode::encode('UTF-8', "10:05 .say #test caf\x{e9}"),
        '10:06 .metrics', '10:07 .ping', '10:08 .whom', '10:09 .help',
    ];
}

sub _tools_context {
    my $out = bless {out => ''}, 'MB903::Buffer';
    my $other = bless {out => ''}, 'MB903::Buffer';
    my $p = bless {
        users => {7 => {authenticated=>1,login=>'tester',level=>1,history=>_tools_history()},
                  8 => {authenticated=>1,login=>'other',level=>0,history=>['11:00 .ping']}},
        streams => {7=>$out,8=>$other},
        bot => {logger=>bless({lines=>[],removed=>[]},'MB901::Logger'),
                metrics=>bless({},'MB901::Metrics'),
                dbh=>bless({},'MB903::NoIO'),db=>bless({},'MB903::NoIO'),
                irc=>bless({},'MB903::NoIO')},
    }, 'MB901::Partyline';
    return ($p, $out, $other);
}

sub run_tools {
    my @specs = (
        ['help_full', ['.help'], sub {
            my ($p,$s)=@_; my $x=$s->{out};
            my $seen=()=$x=~/^  \.seen /mg; my $top=()=$x=~/^  \.top /mg; my $remind=()=$x=~/^  \.remind /mg;
            $x =~ /^Available commands:/ && $x =~ /\.help search <text>/ && $x =~ /\.history \[1-10\|find/
                && $seen==1 && $top==1 && $remind==1 && $x =~ /plugin lifecycle \(v2\)/;
        }],
        ['help_command', ['.help plugins'], sub {$_[1]{out}=~/^Command help:/ && (()=$_[1]{out}=~/^  \.plugins /mg)==6 && $_[1]{out}!~/^  \.whois /m}],
        ['help_case_dot', ['.HeLp .PiNg'], sub {$_[1]{out}=~/^Command help:\r\n  \.ping / && $_[1]{out}!~/Unknown command/}],
        ['help_alias', ['.help dcc'], sub {$_[1]{out}=~/^Command help:\r\n  \.dccstat /}],
        ['help_search', ['.help search TiMeR'], sub {$_[1]{out}=~/^Command help:/ && $_[1]{out}=~/\.timers / && $_[1]{out}=~/\.scriptdryrun / && $_[1]{out}!~/^  \.raw /m}],
        ['help_literal', ['.help search .*'], sub {$_[1]{out}=~/^No matching command help\./}],
        ['help_bounded', ['.help search -'], sub {(()=$_[1]{out}=~/^  \./mg)==12 && $_[1]{out}=~/Showing 12 of \d+ matches; refine/}],
        ['help_missing_search', ['.help search'], sub {$_[1]{out}=~/^Usage: \.help /}],
        ['help_query_limit', ['.help search '.('x'x129)], sub {$_[1]{out}=~/^Usage: \.help /}],
        ['help_unknown', ['.help unknown903'], sub {$_[1]{out}=~/^No matching command help\./}],
        ['help_corrected_usage', ['.help top','.help remind'], sub {$_[1]{out}=~/\.top <#chan\|all> \[n\]/ && $_[1]{out}=~/\.remind <nick> <msg>/ && $_[1]{out}!~/\.remind <nick> <#chan>/}],
        ['history_default', ['.history'], sub {
            my $expected="Recent commands:\r\n"; my $i=1;
            $expected.=sprintf("  %2d  %s\r\n",$i++,$_) for @{_tools_history()};
            $_[1]{out} eq $expected;
        }],
        ['history_recent', ['.history 2'], sub {$_[1]{out} eq "Recent commands:\r\n   1  10:08 .whom\r\n   2  10:09 .help\r\n"}],
        ['history_search', ['.history find PiNg'], sub {$_[1]{out} eq "Matching commands:\r\n   1  10:00 .ping\r\n   2  10:07 .ping\r\n"}],
        ['history_utf8', [Encode::encode('UTF-8',".history find CAF\x{c9}")], sub {
            $_[1]{out} eq "Matching commands:\r\n   1  "._tools_history()->[5]."\r\n";
        }],
        ['history_literal', ['.history find .*'], sub {$_[1]{out} eq "Matching commands:\r\n   1  10:03 .say #test literal .*\r\n"}],
        ['history_no_match', ['.history find unknown-no-match'], sub {$_[1]{out} eq "No matching commands in this session's history.\r\n"}],
        ['history_bad_arguments', [map {'.history '.$_} ('0','11','-1','replay 1','clear now')], sub {(()=$_[1]{out}=~/Usage: \.history/g)==5}],
        ['history_clear', ['.history clear'], sub {$_[1]{out} eq "Session command history cleared.\r\n" && !exists $_[0]{users}{7}{history}}],
        ['history_empty', ['.history clear','.history','.history find ping'], sub {$_[1]{out} eq "Session command history cleared.\r\nNo command history for this session.\r\nNo matching commands in this session's history.\r\n"}],
        ['history_limit', ['.history find '.('x'x129)], sub {$_[1]{out} eq "History search is limited to 128 characters.\r\n"}],
        ['history_retention', [(map {'.unknown'.$_} 1..12),'.history 2'], sub {
            my $h=$_[0]{users}{7}{history};
            @$h==10 && $h->[0]=~/\.unknown3$/ && $h->[-1]=~/\.unknown12$/
                && $_[1]{out}=~/Recent commands:\r\n   1  \d\d:\d\d \.unknown11\r\n   2  \d\d:\d\d \.unknown12\r\n$/;
        }],
    );
    my @results;
    for my $spec (@specs) {
        my ($name,$lines,$check)=@$spec;
        my ($p,$out,$other)=_tools_context();
        my $before=join "\0", @{$p->{users}{7}{history}};
        my (@warnings,$ok,$error);
        { local $SIG{__WARN__}=sub {push @warnings,@_};
          $ok=eval {
            for my $line (@$lines) {
                # Exercise history capacity without intentionally triggering the separate flood policy.
                $p->{users}{7}{rate_count}=0 if $name eq 'history_retention';
                $p->_handle_line($out,7,$line);
            }
            $check->($p,$out,$other);
          }; $error=$@; }
        $ok &&= join("\0",@{$p->{users}{8}{history}}) eq '11:00 .ping';
        if ($name =~ /^history_/ && $name ne 'history_retention') {
            $ok &&= $other->{out} eq '';
            $ok &&= join("\0",@{$p->{users}{7}{history}//[]}) eq $before
                unless $name eq 'history_clear' || $name eq 'history_empty';
        }
        push @results,{case=>$name,ok=>$ok && !@warnings && !$error ? 1:0,
            (@warnings?(warnings=>\@warnings):()),($error?(error=>$error):())};
    }
    my $preauth_ok = 1;
    for my $line ('.history clear', '.help plugins') {
        my ($p,$out,$other) = _tools_context();
        $p->{users}{7}{authenticated} = 0;
        $p->{users}{7}{auth_stage} = 'nick';
        my $before = join "\0", @{$p->{users}{7}{history}};
        $p->_handle_line($out,7,$line);
        $preauth_ok &&= ($p->{users}{7}{auth_stage} // '') eq 'pass'
            && join("\0",@{$p->{users}{7}{history}}) eq $before
            && $other->{out} eq '' && $out->{out} !~ /Command help|history cleared/;
    }
    push @results, {case=>'authentication_gate',ok=>$preauth_ok?1:0};
    {
        my ($p,$out,$other) = _tools_context();
        my $before = join "\0", @{$p->{users}{7}{history}};
        $p->_handle_line($out,7,'.history 1') for 1..12;
        push @results, {case=>'history_rate_limit',ok=>
            (()=$out->{out}=~/Recent commands:/g)==10
            && (()=$out->{out}=~/Rate limit exceeded/g)==1
            && $other->{out} eq ''
            && join("\0",@{$p->{users}{7}{history}}) eq $before ? 1:0};
    }
    for my $transport (qw(telnet dcc)) {
        my (@warnings,$r);
        { local $SIG{__WARN__}=sub {push @warnings,@_};
          $r=eval {_run_one($transport,'tools')}; $r||={ok=>0,error=>"$@"}; }
        $r->{case}='native_tools_'.$transport;
        if (@warnings) {$r->{ok}=0;$r->{warnings}=\@warnings}
        push @results,$r;
    }
    return \@results;
}

1;
