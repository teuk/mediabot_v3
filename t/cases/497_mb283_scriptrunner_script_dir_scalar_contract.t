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
    package Local::MB283::StringyDir;
    use overload '""' => sub { $_[0]->{value} }, fallback => 1;
    sub new { bless { value => $_[1] }, $_[0] }
}

my $tmp = tempdir(CLEANUP => 1);
my $script_dir = "$tmp/scripts";
make_path($script_dir);

my $runner = Mediabot::ScriptRunner->new(script_dir => "  $script_dir  ");
is($runner->script_dir, $script_dir, 'constructor still accepts scalar script_dir and trims surrounding whitespace');

my $payload = $runner->build_event_payload('public_command', command => 'hello');
my $plan = $runner->build_execution_plan('hello.py', $payload);
ok($plan->{ok}, 'normal scalar script_dir still builds Python execution plans');
is($plan->{language}, 'python', 'normal scalar script_dir keeps language detection');
is($plan->{full_path}, "$script_dir/hello.py", 'normal scalar script_dir keeps the expected resolved path');

for my $case (
    [ 'ARRAY ref script_dir', [ $script_dir ] ],
    [ 'HASH ref script_dir',  { dir => $script_dir } ],
    [ 'overloaded script_dir', Local::MB283::StringyDir->new($script_dir) ],
) {
    my ($label, $value) = @$case;
    my $bad_runner = Mediabot::ScriptRunner->new(script_dir => $value);

    is($bad_runner->script_dir, 'plugins/scripts', "constructor rejects $label instead of stringifying it");

    my $bad_plan = $bad_runner->build_execution_plan('hello.py', $payload);
    isnt($bad_plan->{full_path} || '', "$script_dir/hello.py", "$label is not used as the executable script root");
}

my $default_runner = Mediabot::ScriptRunner->new(script_dir => " \t\n ");
is($default_runner->script_dir, 'plugins/scripts', 'blank scalar script_dir falls back to the safe default');

my @warnings;
{
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    Mediabot::ScriptRunner->new(script_dir => [ $script_dir ]);
    Mediabot::ScriptRunner->new(script_dir => { dir => $script_dir });
    Mediabot::ScriptRunner->new(script_dir => Local::MB283::StringyDir->new($script_dir));
}
is_deeply(\@warnings, [], 'constructor ref script_dir rejection is quiet and does not trigger length/stringification warnings');

my $source = do {
    local $/;
    open my $fh, '<', "$Bin/../../Mediabot/ScriptRunner.pm" or die "open ScriptRunner.pm: $!";
    <$fh>;
};

like($source, qr/mb283-B1/, 'ScriptRunner source contains mb283 constructor script_dir scalar marker');
unlike($source, qr/`[^`]+`|\bqx\s*(?:\/|\(|\{)|\bsystem\s*(?:\(|\s)/, 'mb283 constructor guard does not introduce shell execution');

done_testing();
