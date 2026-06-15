# t/cases/488_mb274_command_registry_scalar_names.t
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

    my $bad_name_ok = eval {
        $reg->register_command(
            name    => [ 'bad' ],
            source  => 'public',
            handler => sub { 1 },
        );
        1;
    };
    $assert->(!$bad_name_ok && $@ =~ /command name must be scalar/,
        'array command name is rejected instead of stringified');
    $assert->($reg->count == 0,
        'failed non-scalar command name leaves registry empty');

    my $bad_source_ok = eval {
        $reg->register_command(
            name    => 'badsource',
            source  => { bad => 1 },
            handler => sub { 1 },
        );
        1;
    };
    $assert->(!$bad_source_ok && $@ =~ /command source must be scalar/,
        'hash command source is rejected instead of stringified');
    $assert->($reg->count == 0,
        'failed non-scalar source leaves registry empty');

    $reg->register_command(
        name    => 'Spell',
        source  => ' PUBLIC ',
        aliases => [ [ 'arrayalias' ], { bad => 'hashalias' }, 'Charm' ],
        handler => sub { 'ok' },
    );

    $assert->($reg->has_command('spell', 'public'),
        'valid command still registers under trimmed scalar source');
    $assert->($reg->has_command('charm', 'public'),
        'valid scalar alias still registers');
    $assert->(!$reg->has_command('arrayalias', 'public'),
        'array alias is ignored, not flattened or stringified');

    my @aliases = sort $reg->aliases_for('spell', 'public');
    $assert->(join(',', @aliases) eq 'charm',
        'aliases list contains only valid scalar aliases');

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };

    my $entry = $reg->command_for([ 'spell' ], 'public');
    my @bad_list = $reg->list({ source => 'public' });
    my $bad_count = $reg->count({ source => 'public' });

    $assert->(!defined $entry,
        'lookup with non-scalar command name returns undef');
    $assert->(@bad_list == 0 && $bad_count == 0,
        'list/count with non-scalar source returns empty result');

    my $bad_warning_count = scalar grep { /ARRAY|HASH|uninitialized/i } @warnings;
    $assert->($bad_warning_count == 0,
        'non-scalar lookup/list inputs do not trigger stringification warnings');

    my $src = File::Spec->catfile($root, 'Mediabot', 'CommandRegistry.pm');
    open my $fh, '<', $src
        or do { $assert->(0, "cannot open CommandRegistry.pm: $!"); return; };
    my $text = do { local $/; <$fh> };
    close $fh;

    $assert->($text =~ /mb274-B1/ && $text =~ /mb274-B2/ && $text =~ /mb274-B3/,
        'CommandRegistry source contains mb274 scalar contract markers');
    $assert->($text !~ /\b(?:system|qx)\s*(?:\(|\/|\{)|`[^`]+`/,
        'mb274 CommandRegistry hardening does not introduce shell execution');
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
