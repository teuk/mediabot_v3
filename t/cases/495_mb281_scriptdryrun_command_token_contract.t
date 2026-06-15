use strict;
use warnings;
use utf8;

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib '.';

use Mediabot::Plugin::ScriptDryRun;
use Mediabot::ScriptRunner;
use Mediabot::ScriptActionRunner;

sub ok {
    my ($cond, $name) = @_;
    print(($cond ? 'ok' : 'not ok') . " - $name\n");
    return $cond ? 1 : 0;
}

{
    package MB281::Conf;
    sub new { my $class = shift; return bless { @_ }, $class }
    sub get { my ($self, $key) = @_; return $self->{$key}; }

    package MB281::Events;
    sub new { bless { listeners => [] }, shift }
    sub on {
        my ($self, $event, $cb, %opts) = @_;
        my $entry = { event => $event, cb => $cb, %opts };
        push @{ $self->{listeners} }, $entry;
        return $entry;
    }

    package MB281::Bot;
    sub new {
        my ($class, %args) = @_;
        return bless {
            conf   => MB281::Conf->new(%{ $args{conf} || {} }),
            events => MB281::Events->new,
            ran    => [],
        }, $class;
    }
    sub events { return shift->{events} }
    sub run_script_actions_dry {
        my ($self, $script, $event, %data) = @_;
        push @{ $self->{ran} }, { script => $script, event => $event, data => \%data };
        return {
            ok => 1,
            script_result => { ok => 1, response => { ok => 1, actions => [] } },
            action_plan   => { ok => 1, planned => [], errors => [] },
        };
    }
}

my $failures = 0;
my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/plugins/scripts");
open my $fh, '>', "$tmp/plugins/scripts/hello.py" or die $!;
print {$fh} "print('unused')\n";
close $fh;

my $bot = MB281::Bot->new(conf => {
    'plugins.ScriptDryRun.SCRIPT' => 'hello.py',
});
my $plugin = Mediabot::Plugin::ScriptDryRun->register($bot);

$failures += !ok($plugin->command_allowed('hello'), 'plain scalar command remains allowed with SCRIPT fallback');
$failures += !ok(!$plugin->command_allowed("hello world"), 'command with whitespace is rejected');
$failures += !ok(!$plugin->command_allowed("hello\nworld"), 'command with newline is rejected');
$failures += !ok(!$plugin->command_allowed("hello\rworld"), 'command with carriage return is rejected');
$failures += !ok(!$plugin->command_allowed("hello\0world"), 'command with NUL is rejected');

my %bad_ctx = (channel => '#test', target => '#test', nick => 'TeuK', command => "hello\nworld", args => []);
my $result = $plugin->observe_public_command(\%bad_ctx);
$failures += !ok(!defined $result, 'malformed command is not observed through fallback SCRIPT');
$failures += !ok(!$bad_ctx{scriptdryrun_handled}, 'malformed command is not marked handled');
$failures += !ok(@{ $bot->{ran} } == 0, 'malformed command never reaches external script runner');
$failures += !ok(($plugin->last_error || '') =~ /not allowed by ScriptDryRun filter/, 'malformed command reports a safe filter error');

my %good_ctx = (channel => '#test', target => '#test', nick => 'TeuK', command => 'hello', args => []);
$result = $plugin->observe_public_command(\%good_ctx);
$failures += !ok(ref($result) eq 'HASH', 'valid command is still observed');
$failures += !ok(@{ $bot->{ran} } == 1, 'valid command still reaches external script runner');
$failures += !ok($bot->{ran}[0]{data}{command} eq 'hello', 'external script payload keeps clean command token');

print "1..12\n";
exit($failures ? 1 : 0);
