package Mediabot::AI;

use strict;
use warnings;

use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(
    known_providers
    normalize_provider
    provider_configured
    configured_providers
    select_provider
);

# Provider-neutral registry. Keep credentials in their historical config
# namespaces so existing !ai / tellme installations continue to work while the
# transport layer is migrated behind this facade in later MB699 rounds.
my @DEFAULT_PROVIDER_ORDER = qw(anthropic openai);
my %PROVIDER = (
    anthropic => {
        api_key => 'anthropic.API_KEY',
        aliases => [qw(claude)],
    },
    openai => {
        api_key => 'openai.API_KEY',
        aliases => [qw(chatgpt gpt)],
    },
);

my %PROVIDER_ALIAS;
for my $name (@DEFAULT_PROVIDER_ORDER) {
    $PROVIDER_ALIAS{$name} = $name;
    $PROVIDER_ALIAS{$_} = $name for @{ $PROVIDER{$name}{aliases} || [] };
}

sub known_providers {
    return @DEFAULT_PROVIDER_ORDER;
}

sub normalize_provider {
    my ($raw) = @_;
    return undef unless defined $raw;

    my $name = lc "$raw";
    $name =~ s/^\s+|\s+$//g;
    return undef if $name eq '';
    return 'auto' if $name eq 'auto';

    return $PROVIDER_ALIAS{$name};
}

sub _conf_value {
    my ($source, $key) = @_;
    return undef unless $source && ref($source);

    # Accept either a Mediabot-like owner carrying {conf}, or the configuration
    # object itself.  This keeps provider selection reusable by non-IRC clients.
    my $conf = eval { $source->can('get') } ? $source : eval { $source->{conf} };
    return undef unless $conf && eval { $conf->can('get') };

    return eval { $conf->get($key) };
}

sub provider_configured {
    my ($bot, $provider) = @_;
    my $name = normalize_provider($provider);
    return 0 unless defined($name) && $name ne 'auto' && exists $PROVIDER{$name};

    my $value = _conf_value($bot, $PROVIDER{$name}{api_key});
    return 0 unless defined $value;

    $value = "$value";
    $value =~ s/^\s+|\s+$//g;
    return length($value) ? 1 : 0;
}

sub configured_providers {
    my ($bot) = @_;
    return grep { provider_configured($bot, $_) } @DEFAULT_PROVIDER_ORDER;
}

sub select_provider {
    my ($bot, $requested, %opts) = @_;
    my $name = normalize_provider(defined($requested) ? $requested : 'auto');
    return undef unless defined $name;

    # An explicit provider is a strict choice. Never silently send a request
    # to a different company when the caller asked for one provider by name.
    return provider_configured($bot, $name) ? $name : undef
        if $name ne 'auto';

    my @order = @DEFAULT_PROVIDER_ORDER;
    if (ref($opts{order}) eq 'ARRAY' && @{ $opts{order} }) {
        my %seen;
        @order = grep {
            defined($_) && $_ ne 'auto' && !$seen{$_}++
        } map { normalize_provider($_) } @{ $opts{order} };
    }

    for my $candidate (@order) {
        return $candidate if provider_configured($bot, $candidate);
    }

    return undef;
}

1;
