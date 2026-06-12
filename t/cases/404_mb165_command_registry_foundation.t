# t/cases/404_mb165_command_registry_foundation.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    eval { require Mediabot::CommandRegistry; 1 }
        or do { $assert->(0, "cannot load Mediabot::CommandRegistry: $@"); return; };

    my $reg = Mediabot::CommandRegistry->new();

    $assert->(ref($reg) eq 'Mediabot::CommandRegistry',
        'CommandRegistry object can be created');
    $assert->($reg->count == 0,
        'new registry starts empty');

    my $called = 0;
    my $entry = $reg->register_command(
        name        => 'Ping',
        source      => 'PUBLIC',
        aliases     => [ 'P', 'pong', 'PING' ],
        category    => 'core',
        description => 'Test command',
        level       => 'public',
        handler     => sub { $called++; return 'ok'; },
    );

    $assert->($entry->{name} eq 'ping',
        'command name is normalized to lowercase');
    $assert->($entry->{source} eq 'public',
        'source is normalized to lowercase');
    $assert->($reg->count('public') == 1,
        'registry counts one public command');
    $assert->($reg->has_command('PING', 'public'),
        'canonical command lookup is case-insensitive');
    $assert->($reg->has_command('p', 'public'),
        'alias lookup works');
    $assert->($reg->has_command('pong', 'public'),
        'second alias lookup works');

    my $handler = $reg->handler_for('PONG', 'PUBLIC');
    $assert->(ref($handler) eq 'CODE',
        'handler_for returns handler through alias');
    $assert->($handler->() eq 'ok' && $called == 1,
        'handler returned by alias is callable');

    my @aliases = sort $reg->aliases_for('ping', 'public');
    $assert->(join(',', @aliases) eq 'p,ping,pong',
        'aliases_for includes normalized aliases except canonical duplicate rules');

    my @list = $reg->list('public');
    $assert->(@list == 1 && $list[0]{description} eq 'Test command',
        'list returns registered command metadata');

    my $dup_ok = eval {
        $reg->register_command(
            name    => 'ping',
            source  => 'public',
            handler => sub { 1 },
        );
        1;
    };
    $assert->(!$dup_ok && $@ =~ /already registered/,
        'duplicate command registration is rejected by default');

    my $bad_handler_ok = eval {
        $reg->register_command(
            name    => 'broken',
            source  => 'public',
            handler => 'not-code',
        );
        1;
    };
    $assert->(!$bad_handler_ok && $@ =~ /must be a CODE reference/,
        'non-CODE handler is rejected');

    $reg->register_command(
        name    => 'privonly',
        source  => 'private',
        handler => sub { 'private-ok' },
    );
    $assert->($reg->has_command('privonly', 'private') && !$reg->has_command('privonly', 'public'),
        'public and private registries are isolated');

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot = Mediabot->new({});
    $assert->($bot->command_registry && ref($bot->command_registry) eq 'Mediabot::CommandRegistry',
        'Mediabot constructor creates a command registry');
    $assert->($bot->commands == $bot->command_registry,
        'Mediabot->commands is a short alias to command_registry');

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $mfh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $main_src = do { local $/; <$mfh> };
    close $mfh;

    $assert->($main_src =~ /my %command_map = \(/ && $main_src =~ /my %command_table = \(/,
        'legacy public/private dispatch tables are still present for compatibility');
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
