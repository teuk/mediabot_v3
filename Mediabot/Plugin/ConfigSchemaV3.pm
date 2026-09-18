package Mediabot::Plugin::ConfigSchemaV3;

use strict;
use warnings;
use utf8;

use JSON::PP ();

our $MAX_FIELDS = 32;
our $MAX_CONFIG_BYTES = 4096;

my %SPEC_FIELDS = map { $_ => 1 } qw(
    type default required minimum maximum min_length max_length enum
);

sub _is_bool {
    my ($value) = @_;
    return 1 if JSON::PP::is_bool($value);
    return defined($value) && !ref($value) && "$value" =~ /\A[01]\z/;
}

sub _clone {
    my ($value) = @_;
    return $value unless ref($value);
    return JSON::PP::is_bool($value) ? ($value ? 1 : 0)
        : ref($value) eq 'ARRAY' ? [ map { _clone($_) } @$value ]
        : ref($value) eq 'HASH'  ? { map { $_ => _clone($value->{$_}) } keys %$value }
        : undef;
}

sub _integer {
    my ($value) = @_;
    return undef unless defined($value) && !ref($value)
        && "$value" =~ /\A-?(?:0|[1-9][0-9]*)\z/;
    return 0 + $value;
}

sub _validate_value {
    my ($name, $spec, $value) = @_;
    my $type = $spec->{type};

    if ($type eq 'string') {
        die "Plugin API v3: config '$name' must be a string\n"
            unless defined($value) && !ref($value);
        my $text = "$value";
        die "Plugin API v3: config '$name' contains a control character\n"
            if $text =~ /[\x00-\x1f\x7f]/;
        my $length = length($text);
        die "Plugin API v3: config '$name' is shorter than $spec->{min_length}\n"
            if defined($spec->{min_length}) && $length < $spec->{min_length};
        die "Plugin API v3: config '$name' is longer than $spec->{max_length}\n"
            if defined($spec->{max_length}) && $length > $spec->{max_length};
        if (ref($spec->{enum}) eq 'ARRAY') {
            my %allowed = map { $_ => 1 } @{ $spec->{enum} };
            die "Plugin API v3: config '$name' is not an allowed value\n"
                unless $allowed{$text};
        }
        return $text;
    }

    if ($type eq 'integer') {
        my $number = _integer($value);
        die "Plugin API v3: config '$name' must be an integer\n"
            unless defined $number;
        die "Plugin API v3: config '$name' is below $spec->{minimum}\n"
            if defined($spec->{minimum}) && $number < $spec->{minimum};
        die "Plugin API v3: config '$name' is above $spec->{maximum}\n"
            if defined($spec->{maximum}) && $number > $spec->{maximum};
        return $number;
    }

    die "Plugin API v3: config '$name' must be a boolean\n"
        unless _is_bool($value);
    return $value ? 1 : 0;
}

sub _validate_definition {
    my ($schema) = @_;
    die "Plugin API v3: config_schema must be an object\n"
        unless ref($schema) eq 'HASH';
    die "Plugin API v3: config_schema has more than $MAX_FIELDS fields\n"
        if keys(%$schema) > $MAX_FIELDS;

    my %normalized;
    for my $name (sort keys %$schema) {
        die "Plugin API v3: invalid config field '$name'\n"
            unless $name =~ /\A[a-z][a-z0-9_]{0,47}\z/;
        my $spec = $schema->{$name};
        die "Plugin API v3: config field '$name' must be an object\n"
            unless ref($spec) eq 'HASH';
        for my $key (sort keys %$spec) {
            die "Plugin API v3: unknown config field '$name' property '$key'\n"
                unless $SPEC_FIELDS{$key};
        }
        die "Plugin API v3: config field '$name' has an invalid type\n"
            unless defined($spec->{type}) && !ref($spec->{type})
                && $spec->{type} =~ /\A(?:string|integer|boolean)\z/;

        my %clean = (type => "$spec->{type}");
        if (exists $spec->{required}) {
            die "Plugin API v3: config field '$name' required must be boolean\n"
                unless _is_bool($spec->{required});
            $clean{required} = $spec->{required} ? 1 : 0;
        }
        else {
            $clean{required} = 0;
        }

        if ($clean{type} eq 'string') {
            die "Plugin API v3: config field '$name' cannot use numeric bounds\n"
                if exists($spec->{minimum}) || exists($spec->{maximum});
            for my $bound (qw(min_length max_length)) {
                next unless exists $spec->{$bound};
                my $number = _integer($spec->{$bound});
                die "Plugin API v3: config field '$name' has invalid $bound\n"
                    unless defined($number) && $number >= 0 && $number <= 1024;
                $clean{$bound} = $number;
            }
            die "Plugin API v3: config field '$name' has inverted length bounds\n"
                if defined($clean{min_length}) && defined($clean{max_length})
                    && $clean{min_length} > $clean{max_length};
            if (exists $spec->{enum}) {
                die "Plugin API v3: config field '$name' enum must be an array\n"
                    unless ref($spec->{enum}) eq 'ARRAY';
                die "Plugin API v3: config field '$name' enum must contain 1 to 32 values\n"
                    unless @{ $spec->{enum} } >= 1 && @{ $spec->{enum} } <= 32;
                my (%seen, @values);
                for my $value (@{ $spec->{enum} }) {
                    die "Plugin API v3: config field '$name' enum value must be a string\n"
                        unless defined($value) && !ref($value);
                    my $text = "$value";
                    die "Plugin API v3: config field '$name' enum value is duplicated\n"
                        if $seen{$text}++;
                    push @values, $text;
                }
                $clean{enum} = \@values;
                _validate_value($name, \%clean, $_) for @values;
            }
        }
        elsif ($clean{type} eq 'integer') {
            die "Plugin API v3: config field '$name' cannot use string bounds or enum\n"
                if exists($spec->{min_length}) || exists($spec->{max_length})
                    || exists($spec->{enum});
            for my $bound (qw(minimum maximum)) {
                next unless exists $spec->{$bound};
                my $number = _integer($spec->{$bound});
                die "Plugin API v3: config field '$name' has invalid $bound\n"
                    unless defined $number;
                $clean{$bound} = $number;
            }
            die "Plugin API v3: config field '$name' has inverted numeric bounds\n"
                if defined($clean{minimum}) && defined($clean{maximum})
                    && $clean{minimum} > $clean{maximum};
        }
        else {
            die "Plugin API v3: config field '$name' boolean has incompatible constraints\n"
                if grep { exists $spec->{$_} }
                    qw(minimum maximum min_length max_length enum);
        }

        $clean{default} = _validate_value($name, \%clean, $spec->{default})
            if exists $spec->{default};
        $normalized{$name} = \%clean;
    }
    return \%normalized;
}

sub new {
    my ($class, %args) = @_;
    my $schema = exists($args{schema}) ? $args{schema} : {};
    return bless { schema => _validate_definition($schema) }, $class;
}

sub validate_definition {
    my ($class, $schema) = @_;
    return _clone(_validate_definition($schema));
}

sub definition {
    my ($self) = @_;
    return _clone($self->{schema});
}

sub defaults {
    my ($self) = @_;
    my %defaults;
    for my $name (sort keys %{ $self->{schema} }) {
        next unless exists $self->{schema}{$name}{default};
        $defaults{$name} = _clone($self->{schema}{$name}{default});
    }
    return \%defaults;
}

sub normalize {
    my ($self, $config) = @_;
    $config = {} unless defined $config;
    die "Plugin API v3: channel config must be an object\n"
        unless ref($config) eq 'HASH';
    die "Plugin API v3: channel config has more than $MAX_FIELDS fields\n"
        if keys(%$config) > $MAX_FIELDS;
    for my $name (sort keys %$config) {
        die "Plugin API v3: unknown channel config field '$name'\n"
            unless exists $self->{schema}{$name};
    }

    my %effective;
    for my $name (sort keys %{ $self->{schema} }) {
        my $spec = $self->{schema}{$name};
        if (exists $config->{$name}) {
            $effective{$name} = _validate_value($name, $spec, $config->{$name});
        }
        elsif (exists $spec->{default}) {
            $effective{$name} = _clone($spec->{default});
        }
        elsif ($spec->{required}) {
            die "Plugin API v3: required channel config '$name' is missing\n";
        }
    }

    my $bytes = length(JSON::PP->new->canonical->utf8->encode(\%effective));
    die "Plugin API v3: effective channel config exceeds $MAX_CONFIG_BYTES bytes\n"
        if $bytes > $MAX_CONFIG_BYTES;
    return _clone(\%effective);
}

1;
