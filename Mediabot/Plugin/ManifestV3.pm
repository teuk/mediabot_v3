package Mediabot::Plugin::ManifestV3;

use strict;
use warnings;
use utf8;

use File::Spec;
use JSON::PP ();

our $MAX_MANIFEST_BYTES = 16384;

my %TOP_LEVEL = map { $_ => 1 } qw(
    api name version description runtime compatibility activation
    capabilities commands events config_schema
);

my %RUNTIME_LEVEL = map { $_ => 1 } qw(api kind entrypoint class);
my %ACTIVATION_LEVEL = map { $_ => 1 } qw(default);
my %COMMAND_LEVEL = map { $_ => 1 } qw(source help level handler aliases);
my %EVENT_LEVEL = map { $_ => 1 } qw(name version handler);
my %BASE_CAPABILITY = map { $_ => 1 } qw(
    irc.reply irc.notice channel.topic moderation.kick moderation.ban
    storage.kv scheduler.jobs http.fetch
);

sub _plain_scalar {
    my ($value) = @_;
    return defined($value) && !ref($value) ? 1 : 0;
}

sub _keys_are_known {
    my ($value, $known, $where) = @_;
    for my $key (sort keys %$value) {
        die "Plugin API v3: unknown $where field '$key'\n"
            unless $known->{$key};
    }
}

sub _valid_capability {
    my ($capability) = @_;
    return 0 unless _plain_scalar($capability);
    return 1 if $BASE_CAPABILITY{$capability};
    return 1 if $capability =~ /\Asecrets\.read:[a-z][a-z0-9_.-]{0,63}\z/;
    return 1 if $capability =~ /\Adata\.[a-z][a-z0-9_.-]{0,63}\z/;
    return 0;
}

sub validate {
    my ($class, $manifest, %opts) = @_;

    die "Plugin API v3: manifest must be a JSON object\n"
        unless ref($manifest) eq 'HASH';
    _keys_are_known($manifest, \%TOP_LEVEL, 'manifest');

    die "Plugin API v3: api must be the integer 3\n"
        unless defined($manifest->{api}) && !ref($manifest->{api})
            && "$manifest->{api}" eq '3';

    my $name = $manifest->{name};
    die "Plugin API v3: name must be a lowercase slug\n"
        unless _plain_scalar($name)
            && $name =~ /\A[a-z0-9][a-z0-9-]{0,47}\z/;
    die "Plugin API v3: manifest name '$name' does not match package '$opts{expected_name}'\n"
        if defined($opts{expected_name}) && $name ne $opts{expected_name};

    die "Plugin API v3: version must be semver-like\n"
        unless _plain_scalar($manifest->{version})
            && $manifest->{version} =~ /\A[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?\z/;
    die "Plugin API v3: description must be a short scalar\n"
        unless _plain_scalar($manifest->{description})
            && length($manifest->{description}) >= 1
            && length($manifest->{description}) <= 240;

    my $runtime = $manifest->{runtime};
    die "Plugin API v3: runtime must be an object\n"
        unless ref($runtime) eq 'HASH';
    _keys_are_known($runtime, \%RUNTIME_LEVEL, 'runtime');
    die "Plugin API v3: runtime.kind must be 'perl'\n"
        unless _plain_scalar($runtime->{kind}) && $runtime->{kind} eq 'perl';
    die "Plugin API v3: runtime.entrypoint must be a relative .pm path\n"
        unless _plain_scalar($runtime->{entrypoint})
            && $runtime->{entrypoint} =~ /\A(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+\.pm\z/
            && $runtime->{entrypoint} !~ /(?:\A|\/)\.\.?\//;
    die "Plugin API v3: runtime.class must be a Perl package name\n"
        unless _plain_scalar($runtime->{class})
            && $runtime->{class} =~ /\A[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)*\z/;

    my $activation = $manifest->{activation};
    die "Plugin API v3: activation must be an object\n"
        unless ref($activation) eq 'HASH';
    _keys_are_known($activation, \%ACTIVATION_LEVEL, 'activation');
    die "Plugin API v3: activation.default must be 'off' in MB742\n"
        unless _plain_scalar($activation->{default})
            && $activation->{default} eq 'off';

    my $capabilities = $manifest->{capabilities};
    die "Plugin API v3: capabilities must be an array\n"
        unless ref($capabilities) eq 'ARRAY';
    die "Plugin API v3: at most 32 capabilities may be requested\n"
        if @$capabilities > 32;
    my %seen_capability;
    for my $capability (@$capabilities) {
        die "Plugin API v3: unknown capability\n"
            unless _valid_capability($capability);
        die "Plugin API v3: capability '$capability' is duplicated\n"
            if $seen_capability{$capability}++;
    }

    my $commands = $manifest->{commands};
    die "Plugin API v3: commands must be an object\n"
        unless ref($commands) eq 'HASH';
    die "Plugin API v3: at most 32 commands may be declared\n"
        if keys(%$commands) > 32;
    for my $command (sort keys %$commands) {
        die "Plugin API v3: invalid command name '$command'\n"
            unless $command =~ /\A[a-z][a-z0-9_]{0,23}\z/;
        my $spec = $commands->{$command};
        die "Plugin API v3: command '$command' must be an object\n"
            unless ref($spec) eq 'HASH';
        _keys_are_known($spec, \%COMMAND_LEVEL, "command '$command'");
        die "Plugin API v3: command '$command' source must be public or private\n"
            unless _plain_scalar($spec->{source})
                && $spec->{source} =~ /\A(?:public|private)\z/;
        die "Plugin API v3: command '$command' needs a short help string\n"
            unless _plain_scalar($spec->{help})
                && length($spec->{help}) >= 1 && length($spec->{help}) <= 200;
        die "Plugin API v3: command '$command' has an invalid level\n"
            unless _plain_scalar($spec->{level})
                && ("$spec->{level}" eq '0'
                    || $spec->{level} =~ /\A[A-Za-z][A-Za-z ]{1,31}\z/);
        die "Plugin API v3: command '$command' handler must be a method name\n"
            unless _plain_scalar($spec->{handler})
                && $spec->{handler} =~ /\A[a-z_][a-z0-9_]{0,63}\z/;
        if (exists $spec->{aliases}) {
            die "Plugin API v3: command '$command' aliases must be an array\n"
                unless ref($spec->{aliases}) eq 'ARRAY';
            die "Plugin API v3: command '$command' has too many aliases\n"
                if @{ $spec->{aliases} } > 8;
            my %seen_alias;
            for my $alias (@{ $spec->{aliases} }) {
                die "Plugin API v3: command '$command' has an invalid alias\n"
                    unless _plain_scalar($alias)
                        && $alias =~ /\A[a-z][a-z0-9_]{0,23}\z/;
                die "Plugin API v3: alias '$alias' is duplicated\n"
                    if $seen_alias{$alias}++;
            }
        }
    }

    my $events = $manifest->{events};
    die "Plugin API v3: events must be an array\n"
        unless ref($events) eq 'ARRAY';
    for my $event (@$events) {
        die "Plugin API v3: each event must be an object\n"
            unless ref($event) eq 'HASH';
        _keys_are_known($event, \%EVENT_LEVEL, 'event');
        die "Plugin API v3: event name is invalid\n"
            unless _plain_scalar($event->{name})
                && $event->{name} =~ /\A[a-z][a-z0-9_.-]{0,63}\z/;
        die "Plugin API v3: event version must be a positive integer\n"
            unless defined($event->{version}) && !ref($event->{version})
                && $event->{version} =~ /\A[1-9][0-9]*\z/;
        die "Plugin API v3: event handler must be a method name\n"
            unless _plain_scalar($event->{handler})
                && $event->{handler} =~ /\A[a-z_][a-z0-9_]{0,63}\z/;
    }

    die "Plugin API v3: compatibility must be an object\n"
        if exists($manifest->{compatibility})
            && ref($manifest->{compatibility}) ne 'HASH';
    die "Plugin API v3: config_schema must be an object\n"
        if exists($manifest->{config_schema})
            && ref($manifest->{config_schema}) ne 'HASH';

    return $manifest;
}

sub load_file {
    my ($class, $path, %opts) = @_;

    die "Plugin API v3: manifest path is required\n"
        unless _plain_scalar($path) && length($path);
    die "Plugin API v3: manifest must be a regular non-symlink file\n"
        unless -f $path && !-l $path;
    my $size = -s $path;
    die "Plugin API v3: cannot stat manifest\n" unless defined $size;
    die "Plugin API v3: manifest exceeds $MAX_MANIFEST_BYTES bytes\n"
        if $size > $MAX_MANIFEST_BYTES;

    open my $fh, '<:raw', $path
        or die "Plugin API v3: cannot read manifest: $!\n";
    local $/;
    my $json = <$fh>;
    close $fh;

    die "Plugin API v3: manifest exceeds $MAX_MANIFEST_BYTES bytes\n"
        if !defined($json) || length($json) > $MAX_MANIFEST_BYTES;
    my $manifest = eval { JSON::PP->new->utf8->decode($json) };
    die "Plugin API v3: invalid JSON manifest\n"
        unless ref($manifest) eq 'HASH';

    return $class->validate($manifest, %opts);
}

1;
