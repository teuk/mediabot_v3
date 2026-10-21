package MB889ChromiumFixture;

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Encode ();
use POSIX ();
use Mediabot::External::Chromium ();
use Exporter 'import';

our @EXPORT_OK = qw(make_fixture run_fixture);

sub make_fixture {
    my $root = tempdir('mb889-browser-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $binary = File::Spec->catfile($root, 'browser fixture');
    open my $fh, '>:raw', $binary or die "$binary: $!";
    print {$fh} "#!$^X\n", <<'CHILD';
use strict;
use warnings;
use JSON::PP ();
use POSIX ();
open my $record, '>:raw', $ENV{MB889_BROWSER_RECORD} or die $!;
print {$record} JSON::PP::encode_json({argv => \@ARGV, pid => $$});
close $record or die $!;
binmode STDOUT;
binmode STDERR;
my $mode = $ENV{MB889_BROWSER_MODE};
if ($mode eq 'closed-pipes') {
    $SIG{TERM} = 'IGNORE';
    close STDOUT;
    close STDERR;
    sleep 15;
    POSIX::_exit(99);
}
if ($mode eq 'signal') {
    print STDERR "fixture signal diagnostic\n";
    kill 'TERM', $$;
    POSIX::_exit(99);
}
if ($mode eq 'stderr') { print STDERR 'e' x 200_000; }
if ($mode eq 'invalid-utf8') { print STDOUT "\xff<title>legacy</title>"; }
elsif ($mode ne 'empty') { print STDOUT "<html><title>Caf\xc3\xa9</title></html>"; }
exit($mode eq 'nonzero' ? 7 : 0);
CHILD
    close $fh or die "$binary: $!";
    chmod 0700, $binary or die "chmod $binary: $!";
    return {
        binary => $binary,
        profile_base => File::Spec->catdir($root, 'profiles'),
        record => File::Spec->catfile($root, 'child.json'),
    };
}

sub run_fixture {
    my ($fixture, $fetch, $mode, $url, %options) = @_;
    unlink $fixture->{record} if -e $fixture->{record};
    my $logs = bless [], 'MB889ChromiumFixture::Logger';
    my ($binary_calls, $profile_calls) = (0, 0);
    local $ENV{MB889_BROWSER_RECORD} = $fixture->{record};
    local $ENV{MB889_BROWSER_MODE} = $mode;
    no warnings 'redefine';
    local *Mediabot::External::Chromium::_chromium_binary = sub {
        $binary_calls++;
        return $fixture->{binary};
    };
    local *Mediabot::External::Chromium::_chromium_profile_base = sub {
        $profile_calls++;
        return $fixture->{profile_base};
    };
    my $value = $fetch->({logger => $logs}, $url, %options);
    my $child;
    if (-f $fixture->{record}) {
        open my $fh, '<:raw', $fixture->{record} or die $!;
        local $/;
        $child = JSON::PP::decode_json(<$fh>);
        close $fh;
    }
    return {value => $value, logs => [@$logs], child => $child,
        binary_calls => $binary_calls, profile_calls => $profile_calls};
}

sub MB889ChromiumFixture::Logger::log {push @{$_[0]}, [$_[1], $_[2]];}

# Native probes run in a fresh interpreter so process-global SIGCHLD state from
# unrelated runner cases cannot collect their unregistered child first.
sub native_results {
    my @checks;
    my $ok = sub {push @checks, [$_[0] ? 1 : 0, $_[1]];};
    my $fixture = MB889ChromiumFixture::make_fixture();
    my $fetch = \&Mediabot::External::Chromium::_fetch_url_chromium_dumpdom;
    my $url = 'https://example.invalid/a; printf fixture?x=1&y=2';
    my $run = sub {
        my ($mode, %options) = @_;
        MB889ChromiumFixture::run_fixture($fixture, $fetch, $mode, $url,
            alarm_timeout => 2, virtual_time_budget => 4100,
            lang => 'en-GB', user_agent => 'fixture agent with spaces', %options);
    };
    my $success = $run->('success');
    my @argv = @{$success->{child}{argv} // []};
    my $expected = Encode::decode('UTF-8', "<html><title>Caf\xc3\xa9</title></html>");
    $ok->(defined($success->{value}) && $success->{value} eq $expected
        && utf8::is_utf8($success->{value})
        && @argv && $argv[-1] eq $url && $argv[-2] eq '--dump-dom'
        && grep($_ eq '--user-agent=fixture agent with spaces', @argv)
        && grep($_ eq '--virtual-time-budget=4100', @argv)
        && grep($_ eq '--lang=en-GB', @argv),
        'mb889: native argv preserves spaces/metacharacters and successful UTF-8 DOM');

    my $large = $run->('stderr');
    $ok->(defined($large->{value}) && $large->{value} eq $expected
        && grep($_->[1] =~ /stderr=e{500}\z/, @{$large->{logs}}),
        'mb889: native stderr exceeding a pipe buffer is drained beside stdout');
    my $nonzero = $run->('nonzero');
    $ok->(!defined($nonzero->{value})
        && grep($_->[1] =~ /rc=7 signal=0/, @{$nonzero->{logs}}),
        'mb889: native nonzero exit rejects an otherwise populated DOM');
    my $signal = $run->('signal');
    $ok->(!defined($signal->{value})
        && grep($_->[1] =~ /terminated by signal 15/, @{$signal->{logs}})
        && grep($_->[1] =~ /fixture signal diagnostic/, @{$signal->{logs}}),
        'mb889: native signal termination preserves its stderr diagnostic');
    my $empty = $run->('empty');
    $ok->(!defined($empty->{value})
        && grep($_->[1] =~ /returned no usable DOM/, @{$empty->{logs}}),
        'mb889: a successful empty subprocess still has no usable DOM');
    my $raw = $run->('invalid-utf8');
    $ok->(defined($raw->{value}) && $raw->{value} eq "\xff<title>legacy</title>"
        && !utf8::is_utf8($raw->{value})
        && grep($_->[1] =~ /UTF-8 decode failed/, @{$raw->{logs}}),
        'mb889: invalid UTF-8 keeps the historical raw-buffer fallback');

    my $late = $run->('closed-pipes');
    my $late_pid = $late->{child}{pid};
    $ok->(!defined($late->{value}) && $late_pid
        && waitpid($late_pid, POSIX::WNOHANG()) == -1
        && grep($_->[1] =~ /exceeded alarm timeout after closing its pipes/, @{$late->{logs}}),
        'mb889: native child closing both pipes and ignoring TERM is killed and reaped');
    my @refused;
    for my $bad ('--headless=old', 'file:///fixture', 'javascript:alert(1)', 'ftp://fixture') {
        my $result = MB889ChromiumFixture::run_fixture($fixture, $fetch, 'success', $bad);
        push @refused, !defined($result->{value}) && !$result->{child}
            && !$result->{binary_calls} && !$result->{profile_calls}
            && @{$result->{logs}} == 1
            && $result->{logs}[0][1] =~ /refused non-http\(s\) argument/;
    }
    $ok->(@refused == 4 && !grep(!$_, @refused),
        'mb889: actual unsafe-argument refusals precede all executable/profile IO');
    return \@checks;
}

1;
