# MB744 — strict typed API v3 configuration schemas and values.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    require Mediabot::Plugin::ManifestV3;
    require Mediabot::Plugin::ConfigSchemaV3;

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/hello-v3/plugin.json', expected_name => 'hello-v3');
    my $schema = Mediabot::Plugin::ConfigSchemaV3->new(
        schema => $manifest->{config_schema});

    my $defaults = $schema->normalize({});
    $assert->like($defaults->{greeting}, qr/capability-scoped API v3 plugin/,
        'typed schema applies the witness string default');
    $assert->is($defaults->{enthusiasm}, 0,
        'typed schema applies the bounded integer default');
    $assert->is($defaults->{mention_nick}, 0,
        'typed schema normalizes the JSON boolean default');

    my $effective = $schema->normalize({
        greeting     => 'Lumos',
        enthusiasm   => 3,
        mention_nick => 1,
    });
    $assert->is(join('|', @$effective{qw(greeting enthusiasm mention_nick)}),
        'Lumos|3|1', 'valid channel overrides keep their declared types');

    my $ok = eval { $schema->normalize({ unknown => 1 }); 1 };
    $assert->like($@ // '', qr/unknown channel config field 'unknown'/,
        'unknown channel configuration fails closed');
    $ok = eval { $schema->normalize({ enthusiasm => 4 }); 1 };
    $assert->like($@ // '', qr/above 3/,
        'integer bounds are enforced at policy input');
    $ok = eval { $schema->normalize({ mention_nick => 'yes' }); 1 };
    $assert->like($@ // '', qr/must be a boolean/,
        'boolean values cannot be coerced from arbitrary strings');

    $ok = eval {
        Mediabot::Plugin::ConfigSchemaV3->new(schema => {
            secret => { type => 'string', surprise => 1 },
        });
        1;
    };
    $assert->like($@ // '', qr/unknown config field 'secret' property 'surprise'/,
        'unknown schema properties fail before plugin code loads');

    my $required = Mediabot::Plugin::ConfigSchemaV3->new(schema => {
        room => { type => 'string', required => 1, min_length => 2 },
    });
    $ok = eval { $required->normalize({}); 1 };
    $assert->like($@ // '', qr/required channel config 'room' is missing/,
        'required typed values cannot silently disappear');

    my $copy = $schema->definition;
    $copy->{greeting}{default} = 'changed';
    $assert->like($schema->normalize({})->{greeting}, qr/capability-scoped/,
        'schema snapshots cannot mutate core-owned defaults');
};
