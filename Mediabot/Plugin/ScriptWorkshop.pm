package Mediabot::Plugin::ScriptWorkshop;

use strict;
use warnings;
use utf8;
use Encode qw(decode FB_CROAK);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Mediabot::Plugin::ScaffoldFiles ();
use Mediabot::Plugin::WorkshopFixture ();

my %extension = (perl => 'pl', python => 'py', tcl => 'tcl');

my %source = (
    perl => <<'PERL',
use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);

binmode STDIN, ':raw';
binmode STDOUT, ':raw';
my $request = decode_json(do { local $/; <STDIN> });
my $data = $request->{data};
my $greeting = $data->{config}{GREETING};
my $name = $data->{args}[0] // $data->{nick};

print encode_json({
    protocol => 'mediabot-script-v1',
    ok => JSON::PP::true,
    actions => [{ type => 'reply', text => "$greeting, $name!" }],
});
PERL
    python => <<'PYTHON',
import json
import sys

request = json.load(sys.stdin.buffer)
data = request["data"]
greeting = data["config"]["GREETING"]
name = (data["args"] or [data["nick"]])[0]

print(json.dumps({
    "protocol": "mediabot-script-v1",
    "ok": True,
    "actions": [{"type": "reply", "text": f"{greeting}, {name}!"}],
}))
PYTHON
    tcl => <<'TCL',
package require json
package require json::write
fconfigure stdin -encoding utf-8
fconfigure stdout -encoding utf-8

set request [json::json2dict [read stdin]]
set data [dict get $request data]
set greeting [dict get $data config GREETING]
set arguments [dict get $data args]
set name [dict get $data nick]
if {[llength $arguments]} {
    set name [lindex $arguments 0]
}

set reply [json::write object type [json::write string reply] \
    text [json::write string "$greeting, $name!"]]
puts [json::write object protocol [json::write string mediabot-script-v1] \
    ok true actions [json::write array $reply]]
TCL
);

sub greeting_source {
    my ($language, $config_key) = @_;
    die "Unknown greeting template\n" unless exists $source{$language};
    return $source{$language} =~ s/GREETING/$config_key/gr;
}

sub create {
    my (%args) = @_;
    my ($name, $command, $language) = @args{qw(name command language)};
    die "Invalid script package name\n"
        unless defined($name) && !ref($name) && $name =~ /\A[a-z][a-z0-9_-]{0,31}\z/;
    $language //= 'perl';
    die "Script language must be perl, python or tcl\n"
        unless !ref($language) && exists $extension{$language};
    $command //= $name =~ s/-/_/gr;
    die "Invalid script command name (maximum 24 characters)\n"
        unless !ref($command) && $command =~ /\A[a-z][a-z0-9_]{0,23}\z/;

    my $script = "$name.$extension{$language}";
    my $manifest = {
        api => 2, name => $name, version => '0.1.0',
        description => 'A script plugin greeting with an editable test fixture.',
        commands => { $command => { help => 'Show a greeting for an optional name.', level => 0 } },
        config => { GREETING => 'Bonjour' },
    };
    my $fixture = { steps => [
        { command => $command, replies => [['PRIVMSG', '#workshop', 'Bonjour, Pablo!']] },
        { command => $command, data => { args => ['Élodie "IRC"'] },
          replies => [['PRIVMSG', '#workshop', 'Bonjour, Élodie "IRC"!']] },
    ] };
    my $json = JSON::PP->new->canonical->pretty->ascii;
    my $readme = <<"README";
# $name

Mediabot script plugin ($language). Edit $script and the accompanying test
fixture together, then run this command from your Mediabot checkout.

    perl tools/plugin_v3_workshop.pl --test-script $name/$script

For a custom script directory, add --directory DIR. The Tcl template uses
Tcllib's json and json::write packages.

See docs/PLUGIN_WORKSHOP.md for the test format and installation procedure.
README
    Mediabot::Plugin::ScaffoldFiles::write_package($args{directory}, $name, {
        $script => greeting_source($language, 'GREETING'),
        "$script.manifest.json" => $json->encode($manifest),
        "$script.test.json" => $json->encode($fixture),
        'README.md' => $readme,
    });
    return "$name/$script";
}

sub test_script {
    my (%args) = @_;
    require Mediabot::Mediabot;

    my $directory = $args{directory};
    my $data_dir = tempdir('mediabot-script-workshop-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $config = bless { data_dir => $data_dir }, 'Mediabot::Plugin::ScriptWorkshop::Config';
    my $bot = Mediabot->new({ conf => $config });
    my $irc = $bot->{irc} = bless { replies => [] }, 'Mediabot::Plugin::ScriptWorkshop::IRC';
    my $log = $bot->{logger} = bless { errors => [] }, 'Mediabot::Plugin::ScriptWorkshop::Log';
    my $runner = $bot->{script_runner} =
        Mediabot::Plugin::ScriptWorkshop::Runner->new(bot => $bot, script_dir => $directory);
    my $actions = $bot->{script_action_runner} =
        Mediabot::Plugin::ScriptWorkshop::Actions->new(bot => $bot);
    my $manager = $bot->plugin_manager;
    my $entry = $manager->load_script_v2($args{script}, enabled => 0);
    my $name = $entry->{name};
    my $manifest = $entry->{manifest};
    my $fixture_path = $args{fixture} // File::Spec->catfile(
        $directory, "$entry->{metadata}{script_path}.test.json");

    my $count = 0;
    my $tested = eval {
        my $steps = Mediabot::Plugin::WorkshopFixture::read_steps($fixture_path);
        $manager->enable($name);
        for my $step (@$steps) {
            $count++;
            die "Step $count must declare one command or event and a replies array\n"
                unless ref($step) eq 'HASH' && (defined($step->{command}) xor defined($step->{event}))
                    && ref($step->{replies}) eq 'ARRAY';
            my $input = $step->{data} // {};
            die "Step $count data must be an object\n" unless ref($input) eq 'HASH';
            my %data = (nick => 'Pablo', channel => '#workshop', args => [], %$input);
            my $command = $step->{command};
            my $event = $step->{event};
            $irc->{replies} = [];
            $log->{errors} = [];
            delete $actions->{last_plan};
            delete $runner->{last_result};

            if (defined $command) {
                my $spec = !ref($command) && $manifest->{commands}{$command};
                die "Step $count: command is not declared by the script\n" unless $spec;
                die "Step $count: command fixtures require a public level-0 command\n"
                    unless $spec->{level} eq '0';
                my $handler = $bot->command_registry->handler_for($command, 'public');
                my $context = Mediabot::Context->new(%data, bot => $bot, command => $command);
                $handler->($context);
            } else {
                die "Step $count: event is not declared by the script\n"
                    unless !ref($event) && grep { $_ eq $event } @{ $manifest->{events} || [] };
                my $report = $bot->events->emit_report($event, \%data);
                die "Step $count: event delivery failed\n"
                    unless $report->{ran} == 1 && !@{ $report->{errors} };
            }

            unless ($actions->{last_plan} && $actions->{last_plan}{applied_ok}) {
                my $detail = join('; ', @{ $log->{errors} }) || 'no successful script result';
                my $stderr = $runner->{last_result}{stderr} // '';
                $stderr =~ s/[^\x20-\x7e\n\t]/?/g;
                $detail .= "\nInterpreter stderr:\n" . substr($stderr, 0, 2048) if length $stderr;
                die "Step $count failed: $detail\n";
            }
            Mediabot::Plugin::WorkshopFixture::assert_replies($count, $step->{replies}, $irc->{replies});
        }
        1;
    };
    my $error = $@;
    $manager->unregister_plugin($name);
    die $error unless $tested;
    return $count;
}

sub Mediabot::Plugin::ScriptWorkshop::Config::get {
    return $_[1] eq 'plugins.DATA_DIR' ? $_[0]{data_dir} : undef;
}

sub Mediabot::Plugin::ScriptWorkshop::Log::log {
    push @{ $_[0]{errors} }, $_[2] if $_[1] eq '1';
    return 1;
}

sub Mediabot::Plugin::ScriptWorkshop::IRC::send_message {
    my ($self, $kind, undef, $target, $wire) = @_;
    push @{ $self->{replies} }, [$kind, $target, decode('UTF-8', $wire, FB_CROAK)];
    return 1;
}

{
    package Mediabot::Plugin::ScriptWorkshop::Runner;
    use parent 'Mediabot::ScriptRunner';

    sub run_script {
        my $self = shift;
        return $self->{last_result} = $self->SUPER::run_script(@_);
    }
}

{
    package Mediabot::Plugin::ScriptWorkshop::Actions;
    use parent 'Mediabot::ScriptActionRunner';

    sub apply_actions {
        my $self = shift;
        return $self->{last_plan} = $self->SUPER::apply_actions(@_);
    }
}

1;
