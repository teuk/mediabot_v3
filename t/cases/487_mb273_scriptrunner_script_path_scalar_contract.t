use strict;
use warnings;
use utf8;

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib '.';
use Mediabot::ScriptRunner;

{
    package Local::OverloadedPath;
    use overload '""' => sub { 'examples/hello_perl.pl' }, fallback => 1;
    sub new { bless {}, shift }
}

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/examples");

my $runner = Mediabot::ScriptRunner->new(script_dir => $tmp);

my ($ok, $err, $lang, $full_path) = $runner->validate_script_path('examples/hello_perl.pl');
ok($ok, 'valid scalar relative script path is still accepted');
is($err, undef, 'valid scalar path has no validation error');
is($lang, 'perl', 'valid scalar path still resolves Perl language');
like($full_path, qr{/examples/hello_perl\.pl\z}, 'valid scalar path still resolves full path');

for my $case (
    [ 'ARRAY ref script path', [ 'examples/hello_perl.pl' ] ],
    [ 'HASH ref script path',  { path => 'examples/hello_perl.pl' } ],
    [ 'blessed overloaded script path', Local::OverloadedPath->new ],
) {
    my ($label, $path_value) = @$case;
    my ($bad_ok, $bad_err) = $runner->validate_script_path($path_value);
    is($bad_ok, 0, "$label is rejected");
    is($bad_err, 'script path must be scalar', "$label returns scalar contract error");
}

my $array_plan = $runner->build_execution_plan([ 'examples/hello_perl.pl' ], { event => 'public_command', data => {} });
is($array_plan->{ok}, 0, 'build_execution_plan rejects ARRAY ref script path');
is($array_plan->{error}, 'script path must be scalar', 'build_execution_plan propagates scalar script path error');
is_deeply($array_plan->{command}, [], 'invalid script path produces no command argv');

my $object_dry = $runner->run_dry(Local::OverloadedPath->new, 'public_command', command => 'hello');
is($object_dry->{ok}, 0, 'run_dry rejects overloaded object script path');
is($object_dry->{error}, 'script path must be scalar', 'run_dry propagates scalar script path error');
is_deeply($object_dry->{actions}, [], 'run_dry exposes no actions for invalid script path');

my $source = do {
    open my $fh, '<', 'Mediabot/ScriptRunner.pm' or die "open ScriptRunner.pm: $!";
    local $/;
    <$fh>;
};
like($source, qr/mb273-B1/, 'ScriptRunner source contains mb273 script path scalar marker');
unlike($source, qr/`[^`]+`/, 'mb273 script path guard does not introduce backtick execution');
unlike($source, qr/system\s*\(/, 'mb273 script path guard does not introduce system()');

done_testing();
