#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin qw($Bin);
use lib "$Bin/../..";

use Mediabot::ScriptRunner;

{
    package Local::MB280::Stringy;
    use overload '""' => sub { $_[0]->{value} }, fallback => 1;
    sub new { bless { value => $_[1] }, $_[0] }
}

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/examples");

my $runner = Mediabot::ScriptRunner->new(script_dir => $tmp);

is($runner->language_for('examples/hello_perl.pl'), 'perl', 'language_for still detects Perl scripts');
is($runner->language_for('examples/hello_python.py'), 'python', 'language_for still detects Python scripts');
is($runner->language_for('examples/hello_tcl.tcl'), 'tcl', 'language_for still detects Tcl scripts');
is($runner->language_for('examples/hello.txt'), undef, 'language_for still rejects unsupported extensions');

for my $case (
    [ 'ARRAY ref script path', [ 'examples/hello_perl.pl' ] ],
    [ 'HASH ref script path',  { path => 'examples/hello_python.py' } ],
    [ 'overloaded script path', Local::MB280::Stringy->new('examples/hello_tcl.tcl') ],
) {
    my ($label, $value) = @$case;
    is($runner->language_for($value), undef, "language_for rejects $label instead of stringifying it");
}

my $perl_argv = $runner->interpreter_for_language('perl');
ok(ref($perl_argv) eq 'ARRAY' && @$perl_argv == 1 && $perl_argv->[0] eq $^X,
    'interpreter_for_language still returns the current Perl interpreter');

is_deeply($runner->interpreter_for_language('python'), [ 'python3' ], 'interpreter_for_language still returns python3');
is_deeply($runner->interpreter_for_language('tcl'), [ 'tclsh' ], 'interpreter_for_language still returns tclsh');
is_deeply($runner->interpreter_for_language(' Perl '), [ $^X ], 'interpreter_for_language tolerates scalar surrounding whitespace');
is($runner->interpreter_for_language('ruby'), undef, 'interpreter_for_language still rejects unsupported languages');

for my $case (
    [ 'ARRAY ref language', [ 'perl' ] ],
    [ 'HASH ref language',  { language => 'python' } ],
    [ 'overloaded language', Local::MB280::Stringy->new('tcl') ],
) {
    my ($label, $value) = @$case;
    is($runner->interpreter_for_language($value), undef, "interpreter_for_language rejects $label instead of stringifying it");
}

my $source = do {
    local $/;
    open my $fh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die "open ScriptRunner.pm: $!";
    <$fh>;
};

like($source, qr/mb280-B1/, 'ScriptRunner source contains mb280 language scalar marker');
like($source, qr/mb280-B2/, 'ScriptRunner source contains mb280 interpreter scalar marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb280 language guard does not introduce shell execution');

done_testing();
