# t/cases/405_mb166_registry_public_core_dispatch.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    unshift @INC, $root;

    my $main_file = File::Spec->catfile($root, 'Mediabot', 'Mediabot.pm');
    open my $fh, '<', $main_file
        or do { $assert->(0, "cannot open Mediabot.pm: $!"); return; };
    my $src = do { local $/; <$fh> };
    close $fh;

    $assert->($src =~ /sub _register_builtin_public_core_commands \{/,
        'builtin public core registry method exists');
    $assert->($src =~ /seed the first low-risk built-in commands into the registry/,
        'constructor seeds the first registry command group');
    $assert->($src =~ /PUBLIC\(registry\):/,
        'public dispatch has registry path');
    $assert->($src =~ /compatibility fallback for every command not yet migrated/,
        'registry dispatch documents legacy fallback');
    $assert->($src =~ /if \(my \$handler = \$self->commands->handler_for\(\$cmd, 'public'\)\)/,
        'public dispatch checks CommandRegistry first');
    $assert->($src =~ /if \(my \$handler = \$command_map\{\$cmd\}\)/,
        'legacy public command_map fallback is still present');
    $assert->($src =~ /my %command_map = \(/,
        'legacy public dispatch table is still declared');

    for my $cmd (qw(version uptime help commands)) {
        $assert->($src =~ /name\s*=>\s*'$cmd'/,
            "core command '$cmd' is registered in CommandRegistry");
    }

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot = Mediabot->new({});
    my $reg = $bot->commands;

    $assert->($reg && ref($reg) eq 'Mediabot::CommandRegistry',
        'Mediabot->commands returns CommandRegistry');
    $assert->($reg->count('public') >= 4,
        'public registry contains at least the first four core commands');

    for my $cmd (qw(version uptime help commands)) {
        $assert->($reg->has_command($cmd, 'public'),
            "runtime registry has public command '$cmd'");
        $assert->(ref($reg->handler_for($cmd, 'public')) eq 'CODE',
            "runtime registry handler for '$cmd' is CODE");
    }

    $assert->(!$reg->has_command('karma', 'public'),
        'non-migrated public command is not forced into registry yet');
    $assert->(!$reg->has_command('login', 'private'),
        'private command migration has not started in mb166');
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
