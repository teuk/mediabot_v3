package Mediabot::Plugin::EventCatalogV3;

use strict;
use warnings;
use utf8;

use Scalar::Util qw(blessed reftype);

my %CATALOG = (
    'command.public.observed' => {
        1 => {
            bus_event => 'public_command_observed',
            fields    => {
                channel => [ 'scalar' => 128 ],
                nick    => [ 'scalar' => 64 ],
                command => [ 'scalar' => 32 ],
                args    => [ 'array'  => 32, 256 ],
            },
        },
    },
    'irc.channel.join' => {
        1 => {
            bus_event => 'channel_join_observed',
            fields    => {
                channel => [ 'scalar' => 128 ],
                nick    => [ 'scalar' => 64 ],
                ident   => [ 'scalar' => 128 ],
                host    => [ 'scalar' => 255 ],
                is_self => [ 'bool' ],
            },
        },
    },
    'irc.channel.part' => {
        1 => {
            bus_event => 'channel_part_observed',
            fields    => {
                channel => [ 'scalar' => 128 ],
                nick    => [ 'scalar' => 64 ],
                ident   => [ 'scalar' => 128 ],
                host    => [ 'scalar' => 255 ],
                message => [ 'scalar' => 400 ],
                is_self => [ 'bool' ],
            },
        },
    },
    'irc.channel.topic' => {
        1 => {
            bus_event => 'channel_topic_observed',
            fields    => {
                channel => [ 'scalar' => 128 ],
                nick    => [ 'scalar' => 64 ],
                ident   => [ 'scalar' => 128 ],
                host    => [ 'scalar' => 255 ],
                topic   => [ 'scalar' => 400 ],
                is_self => [ 'bool' ],
            },
        },
    },
    'irc.channel.kick' => {
        1 => {
            bus_event => 'channel_kick_observed',
            fields    => {
                channel => [ 'scalar' => 128 ],
                nick    => [ 'scalar' => 64 ],
                ident   => [ 'scalar' => 128 ],
                host    => [ 'scalar' => 255 ],
                kicked  => [ 'scalar' => 64 ],
                message => [ 'scalar' => 400 ],
                is_self => [ 'bool' ],
            },
        },
    },
    'irc.nick.change' => {
        1 => {
            bus_event => 'channel_nick_observed',
            fields    => {
                nick     => [ 'scalar' => 64 ],
                ident    => [ 'scalar' => 128 ],
                host     => [ 'scalar' => 255 ],
                new_nick => [ 'scalar' => 64 ],
                is_self  => [ 'bool' ],
            },
        },
    },
    'irc.user.quit' => {
        1 => {
            bus_event => 'channel_quit_observed',
            fields    => {
                nick    => [ 'scalar' => 64 ],
                ident   => [ 'scalar' => 128 ],
                host    => [ 'scalar' => 255 ],
                message => [ 'scalar' => 400 ],
                is_self => [ 'bool' ],
            },
        },
    },
    'scheduler.minute' => {
        1 => {
            bus_event => 'plugin_cron_observed',
            fields    => {
                minute => [ 'integer' => 0, 59 ],
                hour   => [ 'integer' => 0, 23 ],
                dow    => [ 'integer' => 0, 6 ],
                mday   => [ 'integer' => 1, 31 ],
                month  => [ 'integer' => 1, 12 ],
                year   => [ 'integer' => 1970, 9999 ],
            },
        },
    },
);

sub _clone {
    my ($value) = @_;
    return $value unless ref($value);
    return [ map { _clone($_) } @$value ] if ref($value) eq 'ARRAY';
    return { map { $_ => _clone($value->{$_}) } keys %$value }
        if ref($value) eq 'HASH';
    return undef;
}

sub event_names { sort keys %CATALOG }

sub versions_for {
    my ($class, $name) = @_;
    return () unless defined($name) && !ref($name) && exists $CATALOG{$name};
    return sort { $a <=> $b } keys %{ $CATALOG{$name} };
}

sub schema {
    my ($class, $name, $version) = @_;
    return undef unless defined($name) && !ref($name)
        && defined($version) && !ref($version)
        && exists($CATALOG{$name}) && exists($CATALOG{$name}{$version});
    return _clone($CATALOG{$name}{$version});
}

sub assert_supported {
    my ($class, $name, $version) = @_;
    die "Plugin API v3: unsupported event '$name' version '$version'\n"
        unless $class->schema($name, $version);
    return 1;
}

sub bus_event {
    my ($class, $name, $version) = @_;
    my $schema = $class->schema($name, $version) or return undef;
    return $schema->{bus_event};
}

sub field_contract {
    my ($class, $name, $version) = @_;
    my $schema = $class->schema($name, $version) or return undef;
    my %contract;
    for my $field (sort keys %{ $schema->{fields} }) {
        my ($type, @bounds) = @{ $schema->{fields}{$field} };
        $contract{$field} = $type eq 'scalar'  ? "scalar:$bounds[0]"
                          : $type eq 'array'   ? "array[scalar:$bounds[1]]:$bounds[0]"
                          : $type eq 'bool'    ? 'boolean'
                          : $type eq 'integer' ? "integer:$bounds[0]..$bounds[1]"
                          :                      'unknown';
    }
    return \%contract;
}

sub _read_raw {
    my ($raw, $field) = @_;
    my $storage = eval { reftype($raw) } // '';
    return $raw->{$field} if $storage eq 'HASH' && exists $raw->{$field};
    return eval { $raw->$field() }
        if blessed($raw) && eval { $raw->can($field) };
    return undef;
}

sub _clean_scalar {
    my ($value, $limit) = @_;
    return undef unless defined($value) && !ref($value);
    my $text = "$value";
    $text =~ s/[\r\n\0]+/ /g;
    return substr($text, 0, $limit);
}

sub normalize_data {
    my ($class, $name, $version, $raw) = @_;
    my $schema = $class->schema($name, $version)
        or die "Plugin API v3: unsupported event '$name' version '$version'\n";

    my %data;
    for my $field (sort keys %{ $schema->{fields} }) {
        my ($type, @bounds) = @{ $schema->{fields}{$field} };
        my $value = _read_raw($raw, $field);
        next unless defined $value;

        if ($type eq 'scalar') {
            my $clean = _clean_scalar($value, $bounds[0]);
            $data{$field} = $clean if defined $clean;
        }
        elsif ($type eq 'bool') {
            next if ref($value) || "$value" !~ /\A[01]\z/;
            $data{$field} = int($value);
        }
        elsif ($type eq 'integer') {
            next if ref($value) || "$value" !~ /\A[0-9]+\z/;
            my $number = int($value);
            next if $number < $bounds[0] || $number > $bounds[1];
            $data{$field} = $number;
        }
        elsif ($type eq 'array' && ref($value) eq 'ARRAY') {
            my @items;
            for my $item (@$value) {
                my $clean = _clean_scalar($item, $bounds[1]);
                next unless defined $clean;
                push @items, $clean;
                last if @items >= $bounds[0];
            }
            $data{$field} = \@items;
        }
    }
    return \%data;
}

sub envelope {
    my ($class, $name, $version, $raw, %opts) = @_;
    require Mediabot::Plugin::EventEnvelopeV3;
    return Mediabot::Plugin::EventEnvelopeV3->new(
        name        => $name,
        version     => $version,
        occurred_at => $opts{occurred_at},
        data        => $class->normalize_data($name, $version, $raw),
    );
}

1;
