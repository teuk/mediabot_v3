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

    $assert->($src =~ /sub _register_builtin_command_catalogue \{/,
        'complete built-in catalogue registration method exists');
    $assert->($src =~ /every built-in command is catalogued before plugins load/,
        'constructor seeds the complete built-in catalogue');
    $assert->($src =~ /CommandRegistry is the sole authority/,
        'public dispatch documents registry authority');
    $assert->($src =~ /command_for\(\$cmd, 'public'\)/,
        'public dispatch resolves catalogue entry first');
    $assert->($src !~ /if \(my \$handler = \$command_map\{\$cmd\}\)/,
        'legacy public command_map has no unregistered fallback');
    $assert->($src =~ /my %command_map = \(/,
        'legacy public implementation adapter is still declared');

    eval { require 'Mediabot/Mediabot.pm'; 1 }
        or do { $assert->(0, "cannot load Mediabot/Mediabot.pm: $@"); return; };

    my $bot = Mediabot->new({});
    my $reg = $bot->commands;

    $assert->($reg && ref($reg) eq 'Mediabot::CommandRegistry',
        'Mediabot->commands returns CommandRegistry');
    $assert->($reg->count('public') == 238,
        'public registry contains the complete frozen built-in surface');
    $assert->($reg->count('private') == 94,
        'private registry contains the complete frozen built-in surface');

    for my $cmd (qw(version uptime help commands)) {
        $assert->($reg->has_command($cmd, 'public'),
            "runtime registry has public command '$cmd'");
        $assert->(ref($reg->handler_for($cmd, 'public')) eq 'CODE',
            "runtime registry handler for '$cmd' is CODE");
    }

    my $karma = $reg->command_for('karma', 'public');
    $assert->($karma && $karma->{metadata}{dispatch} eq 'legacy-public',
        'public legacy handler is reachable only through adapter metadata');
    my $login = $reg->command_for('login', 'private');
    $assert->($login && $login->{metadata}{dispatch} eq 'legacy-private',
        'private legacy handler is reachable only through adapter metadata');
    my $version = $reg->command_for('version', 'public');
    $assert->($version && $version->{metadata}{dispatch} eq 'registry',
        'native core handler remains direct registry dispatch');
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
