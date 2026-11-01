# MB744 — strict typed API v3 configuration schemas and values.

use strict;
use warnings;
use utf8;
use Config ();
use JSON::PP ();

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
    $assert->like(join('|', @$defaults{qw(greeting enthusiasm mention_nick)}),
        qr/capability-scoped API v3 plugin[^|]*\|0\|0\z/,
        'typed schema applies string, bounded integer and JSON boolean defaults');

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

    # Use the public schema and policy boundaries, not a mirrored parser.
    my ($positive, $negative, $overflow, $underflow) = $Config::Config{ivsize} >= 8
        ? ('18446744073709551615', '-9223372036854775808',
           '18446744073709551616', '-9223372036854775809')
        : ('4294967295', '-2147483648', '4294967296', '-2147483649');
    my $integers = Mediabot::Plugin::ConfigSchemaV3->new(schema => {
        count => {type => 'integer'},
    });
    my $json = JSON::PP->new->canonical;
    my (@valid_errors, @invalid_errors, @warnings);
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    for my $value ('0', '-0', '-7', '42', $positive, $negative) {
        my $result = eval { $integers->normalize({count => $value}) };
        my $expected = $value eq '-0' ? '0' : $value;
        push @valid_errors, "native value $value changed or lost its numeric JSON type"
            unless $result && $json->encode($result) eq '{"count":'.$expected.'}';
    }
    my $limits = eval { Mediabot::Plugin::ConfigSchemaV3->new(schema => {
        count => {type=>'integer',minimum=>$negative,maximum=>$positive,default=>'-0'},
    }) };
    push @valid_errors, 'exact signed/unsigned bounds and zero default were rejected'
        unless $limits && $json->encode($limits->normalize({})) eq '{"count":0}';
    $assert->is(join("\n", @valid_errors), '',
        'exact native integers, signed and unsigned boundaries, and -0 retain numeric JSON values');

    my @bad = ($overflow, $underflow, '9' x 400);
    for my $value (@bad, '01', '+1', '1.0', '1e3', "1\n", undef, [], JSON::PP::true) {
        my $accepted = eval { $integers->normalize({count=>$value}); 1 };
        my $error = $@;
        push @invalid_errors, 'invalid channel integer was accepted or misclassified'
            if $accepted || $error !~ /must be an integer/;
    }
    for my $property (qw(minimum maximum default)) {
        for my $value (@bad) {
            my $accepted = eval { Mediabot::Plugin::ConfigSchemaV3->new(schema => {
                count => {type=>'integer', $property=>$value},
            }); 1 };
            my $error = $@;
            push @invalid_errors, "invalid schema $property was accepted or misclassified"
                if $accepted || $error !~ /(?:invalid \Q$property\E|must be an integer)/;
        }
    }
    my $bad_manifest = $json->decode($json->encode($manifest));
    $bad_manifest->{config_schema} = {count=>{type=>'integer',maximum=>'9'x400}};
    my $accepted = eval { Mediabot::Plugin::ManifestV3->validate($bad_manifest); 1 };
    push @invalid_errors, 'manifest validation did not reject an infinite bound'
        if $accepted || $@ !~ /invalid maximum/;
    require Mediabot::Plugin::ChannelPolicyV3;
    my $policy = Mediabot::Plugin::ChannelPolicyV3->new(schema=>$integers);
    $policy->set('#test',mode=>'observe',config=>{count=>7});
    $accepted = eval { $policy->set('#test',mode=>'on',config=>{count=>'9'x400}); 1 };
    my $retained = $policy->policy_for('#test');
    push @invalid_errors, 'rejected overflow changed the previous channel policy'
        if $accepted || $retained->{mode} ne 'observe' || $retained->{config}{count} != 7;
    push @invalid_errors, 'integer validation emitted a warning' if @warnings;
    $assert->is(join("\n", @invalid_errors), '',
        'lossy and non-finite integers fail at config, schema and manifest boundaries without changing policy');
};
