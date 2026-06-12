# t/cases/415_mb176_script_runner_subprocess.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json);

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::ScriptRunner; 1 }
        or do { $assert->(0, "cannot load Mediabot::ScriptRunner: $@"); return; };

    my $tmp = File::Spec->catdir($root, 't', 'tmp_mb176_scripts');
    make_path($tmp);

    my $ok_script = File::Spec->catfile($tmp, 'ok.pl');
    open my $okfh, '>', $ok_script
        or do { $assert->(0, "cannot write ok script: $!"); return; };
    print {$okfh} <<'EOS';
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
my $in = do { local $/; <STDIN> };
my $payload = decode_json($in);
print encode_json({
    actions => [
        {
            type   => 'reply',
            target => $payload->{data}{channel},
            text   => 'ok:' . $payload->{data}{command},
        }
    ]
});
EOS
    close $okfh;

    my $bad_json_script = File::Spec->catfile($tmp, 'bad_json.pl');
    open my $bjfh, '>', $bad_json_script
        or do { $assert->(0, "cannot write bad_json script: $!"); return; };
    print {$bjfh} "print qq/not json/;\n";
    close $bjfh;

    my $stderr_script = File::Spec->catfile($tmp, 'stderr_exit.pl');
    open my $sefh, '>', $stderr_script
        or do { $assert->(0, "cannot write stderr_exit script: $!"); return; };
    print {$sefh} "print STDERR qq/problem happened\\n/; exit 7;\n";
    close $sefh;

    my $sleep_script = File::Spec->catfile($tmp, 'sleep.pl');
    open my $slfh, '>', $sleep_script
        or do { $assert->(0, "cannot write sleep script: $!"); return; };
    print {$slfh} "sleep 3; print qq/{\\\"actions\\\":[]}/;\n";
    close $slfh;

    my $runner = Mediabot::ScriptRunner->new(
        script_dir       => $tmp,
        timeout          => 2,
        max_stdout_bytes => 4096,
    );

    my $result = $runner->run_script(
        'ok.pl',
        'public_command',
        channel => '#test',
        nick    => 'Te[u]K',
        command => 'demo',
    );

    $assert->($result->{ok},
        'run_script executes valid Perl script successfully');
    $assert->(!$result->{timeout} && defined($result->{exit_code}) && $result->{exit_code} == 0,
        'successful script exits with code 0 and no timeout');
    $assert->(ref($result->{response}{actions}) eq 'ARRAY' && @{$result->{response}{actions}} == 1,
        'successful script response contains one action');
    $assert->($result->{response}{actions}[0]{type} eq 'reply' && $result->{response}{actions}[0]{text} eq 'ok:demo',
        'successful script action is parsed and normalized');

    my $bad = $runner->run_script('bad_json.pl', 'public_command', channel => '#test');
    $assert->(!$bad->{ok} && !$bad->{timeout},
        'invalid JSON script result is not OK');
    $assert->($bad->{response}{errors}[0] =~ /invalid JSON/,
        'invalid JSON script result reports parse error');

    my $stderr = $runner->run_script('stderr_exit.pl', 'public_command', channel => '#test');
    $assert->(!$stderr->{ok} && defined($stderr->{exit_code}) && $stderr->{exit_code} == 7,
        'non-zero script exit is not OK and preserves exit code');
    $assert->($stderr->{stderr} =~ /problem happened/,
        'stderr from failing script is captured');

    my $fast_runner = Mediabot::ScriptRunner->new(
        script_dir       => $tmp,
        timeout          => 1,
        max_stdout_bytes => 4096,
    );
    my $timeout = $fast_runner->run_script('sleep.pl', 'public_command', channel => '#test');
    $assert->(!$timeout->{ok} && $timeout->{timeout},
        'long script is killed on timeout');
    $assert->($timeout->{response}{errors}[0] =~ /timed out/,
        'timeout result has structured timeout error');

    my $unsafe = $runner->run_script('../ok.pl', 'public_command', channel => '#test');
    $assert->(!$unsafe->{ok} && $unsafe->{error} =~ /parent directory/,
        'run_script refuses unsafe relative path before spawning');

    my $plan = $runner->run_dry('ok.pl', 'public_command', channel => '#test');
    $assert->(ref($plan->{command}) eq 'ARRAY' && $plan->{command}[-1] =~ /ok\.pl\z/,
        'dry-run command remains argv array');

    my $sr_file = File::Spec->catfile($root, 'Mediabot', 'ScriptRunner.pm');
    open my $sfh, '<', $sr_file
        or do { $assert->(0, "cannot open ScriptRunner.pm: $!"); return; };
    my $src = do { local $/; <$sfh> };
    close $sfh;

    $assert->($src =~ /mb176-B1: real subprocess execution/,
        'ScriptRunner source contains mb176 marker');
    $assert->($src =~ /open3\(\$child_in, \$child_out, \$child_err, \@cmd\)/,
        'ScriptRunner uses open3 with argv array');
    $assert->($src !~ /\bsystem\s*\(|qx\//,
        'ScriptRunner does not use system() or qx// shell execution');
};

if (caller) { return $case; }

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
