# t/cases/445_mb231_command_registry_failed_replace_atomicity.t
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

    $reg->register_command(
        name    => 'spell',
        source  => 'public',
        aliases => [ 'oldspell', 's' ],
        handler => sub { 'spell-v1' },
    );

    $reg->register_command(
        name    => 'other',
        source  => 'public',
        aliases => [ 'o' ],
        handler => sub { 'other-v1' },
    );

    my $conflict_alias_ok = eval {
        $reg->register_command(
            name    => 'spell',
            source  => 'public',
            aliases => [ 'o' ],
            replace => 1,
            handler => sub { 'spell-v2-bad' },
        );
        1;
    };

    $assert->(!$conflict_alias_ok && $@ =~ /already points to 'other'/,
        'conflicting alias replacement is rejected');
    $assert->($reg->has_command('oldspell', 'public'),
        'failed replacement keeps old alias oldspell');
    $assert->($reg->has_command('s', 'public'),
        'failed replacement keeps old alias s');
    $assert->($reg->handler_for('spell', 'public')->() eq 'spell-v1',
        'failed replacement keeps original canonical handler');
    $assert->($reg->handler_for('oldspell', 'public')->() eq 'spell-v1',
        'failed replacement keeps old alias handler');
    $assert->($reg->handler_for('o', 'public')->() eq 'other-v1',
        'failed replacement does not damage other alias owner');

    my $conflict_command_ok = eval {
        $reg->register_command(
            name    => 'spell',
            source  => 'public',
            aliases => [ 'other' ],
            replace => 1,
            handler => sub { 'spell-v2-bad' },
        );
        1;
    };

    $assert->(!$conflict_command_ok && $@ =~ /conflicts with command 'other'/,
        'canonical-name shadow replacement is rejected');
    $assert->($reg->has_command('oldspell', 'public'),
        'second failed replacement still keeps old aliases');
    $assert->($reg->handler_for('spell', 'public')->() eq 'spell-v1',
        'second failed replacement still keeps original handler');

    $reg->register_command(
        name    => 'spell',
        source  => 'public',
        aliases => [ 'newspell' ],
        replace => 1,
        handler => sub { 'spell-v2' },
    );

    $assert->(!$reg->has_command('oldspell', 'public'),
        'successful replacement removes old alias after validation');
    $assert->(!$reg->has_command('s', 'public'),
        'successful replacement removes second old alias after validation');
    $assert->($reg->handler_for('newspell', 'public')->() eq 'spell-v2',
        'successful replacement installs new alias and handler');
    $assert->($reg->handler_for('other', 'public')->() eq 'other-v1',
        'successful replacement does not damage other canonical command');

    my $src = File::Spec->catfile($root, 'Mediabot', 'CommandRegistry.pm');
    open my $fh, '<', $src
        or do { $assert->(0, "cannot open CommandRegistry.pm: $!"); return; };
    my $text = do { local $/; <$fh> };
    close $fh;

    $assert->($text =~ /mb231-B1/, 'CommandRegistry source contains mb231 atomic replace marker');
    $assert->($text !~ /\b(?:system|qx)\s*(?:\(|\/|\{)|`[^`]+`/,
        'CommandRegistry atomic replace fix does not introduce shell execution');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;

my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';
    if ($ok) { print "ok $tests - $name\n"; }
    else     { print "not ok $tests - $name\n"; $fail++; }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
