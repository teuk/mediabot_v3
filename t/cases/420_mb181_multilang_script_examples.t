# t/cases/420_mb181_multilang_script_examples.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $script_dir = File::Spec->catdir($root, 'plugins', 'scripts');

    my $bot = Mediabot->new({});
    $bot->{script_runner} = Mediabot::ScriptRunner->new(
        bot              => $bot,
        script_dir       => $script_dir,
        timeout          => 4,
        max_stdout_bytes => 8192,
    );
    $bot->{script_action_runner} = Mediabot::ScriptActionRunner->new(
        bot             => $bot,
        max_text_length => 500,
    );

    my $perl_result = $bot->run_script_actions_dry(
        'examples/hello_perl.pl',
        'public_command',
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'mb181',
        args    => [ 'perl' ],
    );

    $assert->($perl_result->{ok},
        'Perl example script passes full dry-run pipeline');
    $assert->($perl_result->{script_result}{ok},
        'Perl example subprocess result is OK');
    $assert->($perl_result->{action_plan}{ok},
        'Perl example action plan is OK');
    $assert->($perl_result->{action_plan}{planned}[0]{type} eq 'reply',
        'Perl example plans reply action');
    $assert->($perl_result->{action_plan}{planned}[0]{target} eq '#teuk',
        'Perl example reply target is explicit channel');
    $assert->($perl_result->{action_plan}{planned}[0]{text} =~ /Perl script bridge OK/,
        'Perl example reply text is present');

    my $python_result = $bot->run_script_actions_dry(
        'examples/hello_python.py',
        'public_command',
        channel => '#teuk',
        nick    => 'Te[u]K',
        command => 'mb181',
        args    => [ 'python' ],
    );

    $assert->($python_result->{ok},
        'Python example script passes full dry-run pipeline');
    # mb227-B1: current Python example is intentionally visible in-channel,
    # matching the mb196/mb198 live-smoke contract used by pyhello.
    $assert->($python_result->{action_plan}{planned}[0]{type} eq 'reply',
        'Python example plans visible reply action');
    $assert->($python_result->{action_plan}{planned}[0]{target} eq '#teuk',
        'Python example reply target defaults from context channel');
    $assert->($python_result->{action_plan}{planned}[0]{text} =~ /Python script bridge OK/,
        'Python example notice text is present');

    my $tcl_available = 0;
    for my $dir (split /:/, $ENV{PATH} || '') {
        if (-x File::Spec->catfile($dir, 'tclsh')) {
            $tcl_available = 1;
            last;
        }
    }

    if ($tcl_available) {
        my $tcl_result = $bot->run_script_actions_dry(
            'examples/hello_tcl.tcl',
            'public_command',
            channel => '#teuk',
            nick    => 'Te[u]K',
            command => 'mb181',
            args    => [ 'tcl' ],
        );

        $assert->($tcl_result->{ok},
            'Tcl example script passes full dry-run pipeline');
        $assert->($tcl_result->{script_result}{ok},
            'Tcl example subprocess result is OK');
        $assert->($tcl_result->{action_plan}{ok},
            'Tcl example action plan is OK');
        $assert->($tcl_result->{action_plan}{planned}[0]{type} eq 'reply',
            'Tcl example plans reply action');
        $assert->($tcl_result->{action_plan}{planned}[0]{target} eq '#teuk',
            'Tcl example reply target defaults from context channel');
        $assert->($tcl_result->{action_plan}{planned}[0]{text} =~ /Tcl script bridge OK/,
            'Tcl example reply text is present');
    }
    else {
        $assert->(1, 'Tcl example skipped because tclsh is not available');
        $assert->(1, 'Tcl subprocess check skipped because tclsh is not available');
        $assert->(1, 'Tcl action plan check skipped because tclsh is not available');
        $assert->(1, 'Tcl reply action check skipped because tclsh is not available');
        $assert->(1, 'Tcl target check skipped because tclsh is not available');
        $assert->(1, 'Tcl text check skipped because tclsh is not available');
    }

    for my $file (
        File::Spec->catfile($root, 'plugins', 'scripts', 'examples', 'hello_perl.pl'),
        File::Spec->catfile($root, 'plugins', 'scripts', 'examples', 'hello_python.py'),
        File::Spec->catfile($root, 'plugins', 'scripts', 'examples', 'hello_tcl.tcl'),
    ) {
        open my $fh, '<', $file
            or do { $assert->(0, "cannot open example script $file: $!"); next; };
        my $src = do { local $/; <$fh> };
        close $fh;

        $assert->(scalar($src =~ /mediabot-script-v1/),
            "example script $file documents the mediabot-script-v1 protocol");
        $assert->($src !~ /\bsystem\s*\(|\bexec\s*\(|qx\/|rm\s+-rf|curl\s+/,
            "example script $file does not contain dangerous shell helpers");
    }
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
