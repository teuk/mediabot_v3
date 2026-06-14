# t/cases/443_mb230_command_registry_replace_alias_hygiene.t
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
        aliases => [ 's', 'oldspell', 'SPELL', 's' ],
        handler => sub { 'v1' },
    );

    my @aliases_v1 = sort $reg->aliases_for('spell', 'public');
    $assert->(join(',', @aliases_v1) eq 'oldspell,s',
        'initial aliases are deduplicated and canonical duplicates are ignored');
    $assert->($reg->has_command('oldspell', 'public'),
        'old alias resolves before replacement');

    $reg->register_command(
        name    => 'spell',
        source  => 'public',
        aliases => [ 'newspell' ],
        replace => 1,
        handler => sub { 'v2' },
    );

    $assert->(!$reg->has_command('oldspell', 'public'),
        'replace removes stale alias oldspell');
    $assert->(!$reg->has_command('s', 'public'),
        'replace removes stale alias s');
    $assert->($reg->has_command('newspell', 'public'),
        'replace installs new alias');
    $assert->($reg->handler_for('newspell', 'public')->() eq 'v2',
        'new alias resolves to replacement handler');

    $reg->register_command(
        name    => 'other',
        source  => 'public',
        aliases => [ 'o' ],
        handler => sub { 'other' },
    );

    my $steal_alias_ok = eval {
        $reg->register_command(
            name    => 'spell',
            source  => 'public',
            aliases => [ 'o' ],
            replace => 1,
            handler => sub { 'bad' },
        );
        1;
    };
    $assert->(!$steal_alias_ok && $@ =~ /already points to 'other'/,
        'replace cannot steal an alias owned by another command');

    my $shadow_command_ok = eval {
        $reg->register_command(
            name    => 'spell',
            source  => 'public',
            aliases => [ 'other' ],
            replace => 1,
            handler => sub { 'bad' },
        );
        1;
    };
    $assert->(!$shadow_command_ok && $@ =~ /conflicts with command 'other'/,
        'replace cannot shadow another canonical command name with an alias');

    $assert->($reg->handler_for('other', 'public')->() eq 'other',
        'other command still resolves after failed replacement attempts');

    my $src = File::Spec->catfile($root, 'Mediabot', 'CommandRegistry.pm');
    open my $fh, '<', $src
        or do { $assert->(0, "cannot open CommandRegistry.pm: $!"); return; };
    my $text = do { local $/; <$fh> };
    close $fh;

    $assert->($text =~ /mb230-B1/, 'CommandRegistry source contains mb230 alias hygiene marker');
    $assert->($text !~ /\b(?:system|qx)\s*(?:\(|\/|\{)|`[^`]+`/,
        'CommandRegistry alias hygiene does not introduce shell execution');
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
