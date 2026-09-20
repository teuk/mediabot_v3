package Mediabot::Plugin::DiagnosticsV3;

use strict;
use warnings;
use utf8;

sub _list {
    my ($value) = @_;
    return () unless ref($value) eq 'ARRAY';
    return sort grep { defined($_) && !ref($_) && length($_) } @$value;
}

sub _set {
    return { map { $_ => 1 } @_ };
}

sub _channel_key {
    my ($channel) = @_;
    return undef unless defined($channel) && !ref($channel);
    my $key = lc "$channel";
    $key =~ tr/\x5b\x5d\x5c\x5e/\x7b\x7d\x7c\x7e/;
    return $key;
}

sub permissions {
    my ($class, %args) = @_;
    my $entry = $args{entry};
    die "Plugin diagnostics: entry must be an object\n"
        unless ref($entry) eq 'HASH';
    my $metadata = ref($entry->{metadata}) eq 'HASH'
        ? $entry->{metadata} : {};

    my @requested = _list($metadata->{requested_capabilities});
    my @granted   = _list($metadata->{granted_capabilities});
    my @effective = _list($metadata->{effective_capabilities});
    my $effective = _set(@effective);
    my $requested = _set(@requested);
    my @missing = grep { !$effective->{$_} } @requested;
    my @unexpected = grep { !$requested->{$_} } @granted;

    return {
        plugin     => "$entry->{name}",
        status     => @missing ? 'partial' : 'complete',
        requested  => [ @requested ],
        granted    => [ @granted ],
        effective  => [ @effective ],
        missing    => [ @missing ],
        unexpected => [ @unexpected ],
    };
}

sub report {
    my ($class, %args) = @_;
    my $entry = $args{entry};
    die "Plugin diagnostics: entry must be an object\n"
        unless ref($entry) eq 'HASH';
    my $manifest = ref($entry->{manifest}) eq 'HASH'
        ? $entry->{manifest} : {};
    my $policies = ref($args{policies}) eq 'ARRAY' ? $args{policies} : [];
    my $permissions = $class->permissions(entry => $entry);

    my %policy_counts = (off => 0, observe => 0, on => 0);
    for my $policy (@$policies) {
        next unless ref($policy) eq 'HASH';
        my $mode = $policy->{mode} // '';
        $policy_counts{$mode}++ if exists $policy_counts{$mode};
    }
    my $active = $policy_counts{observe} + $policy_counts{on};

    my $declared_commands = ref($manifest->{commands}) eq 'HASH'
        ? scalar(keys %{ $manifest->{commands} }) : 0;
    my $declared_events = ref($manifest->{events}) eq 'ARRAY'
        ? scalar(@{ $manifest->{events} }) : 0;
    my $declared_jobs = ref($manifest->{jobs}) eq 'HASH'
        ? scalar(keys %{ $manifest->{jobs} }) : 0;
    my $mounted_commands = ref($entry->{mounted_commands}) eq 'ARRAY'
        ? scalar(@{ $entry->{mounted_commands} }) : 0;
    my $mounted_events = ref($entry->{event_listeners}) eq 'ARRAY'
        ? scalar(@{ $entry->{event_listeners} }) : 0;
    my $mounted_jobs = ref($entry->{mounted_jobs}) eq 'ARRAY'
        ? scalar(@{ $entry->{mounted_jobs} }) : 0;
    my $saved_handlers = ref($entry->{mounted_commands}) eq 'ARRAY'
        ? scalar(grep { ref($_) eq 'HASH' && ref($_->{restore}) eq 'HASH' }
            @{ $entry->{mounted_commands} }) : 0;

    my ($status, $reason);
    if (!$entry->{enabled}) {
        ($status, $reason) = ('inactive', 'plugin_disabled');
    }
    elsif (!$active) {
        ($status, $reason) = ('inactive', 'no_active_channel');
    }
    elsif (@{ $permissions->{missing} }) {
        ($status, $reason) = ('limited', 'missing_capabilities');
    }
    else {
        ($status, $reason) = ('ready', 'operational');
    }

    return {
        plugin      => "$entry->{name}",
        version     => defined($entry->{version}) ? "$entry->{version}" : '',
        lifecycle   => $entry->{enabled} ? 'enabled' : 'disabled',
        status      => $status,
        reason      => $reason,
        permissions => $permissions,
        policies    => {
            total   => scalar(@$policies),
            active  => $active,
            off     => $policy_counts{off},
            observe => $policy_counts{observe},
            on      => $policy_counts{on},
        },
        runtime => {
            declared => {
                commands => $declared_commands,
                events   => $declared_events,
                jobs     => $declared_jobs,
            },
            mounted => {
                commands => $mounted_commands,
                events   => $mounted_events,
                jobs     => $mounted_jobs,
            },
            saved_handlers => $saved_handlers,
        },
    };
}

sub explain_channel {
    my ($class, %args) = @_;
    my $entry = $args{entry};
    die "Plugin diagnostics: entry must be an object\n"
        unless ref($entry) eq 'HASH';
    my $policy = $args{policy};
    die "Plugin diagnostics: channel policy must be an object\n"
        unless ref($policy) eq 'HASH';
    my $policies = ref($args{policies}) eq 'ARRAY' ? $args{policies} : [];
    my $channel_key = _channel_key($args{channel});
    my $configured = 0;
    for my $candidate (@$policies) {
        next unless ref($candidate) eq 'HASH';
        my $candidate_key = _channel_key($candidate->{channel});
        if (defined($channel_key) && defined($candidate_key)
            && $candidate_key eq $channel_key) {
            $configured = 1;
            last;
        }
    }

    my $mode = $policy->{mode} // 'off';
    my ($decision, $reason, $runs, $output);
    if (!$entry->{enabled}) {
        ($decision, $reason, $runs, $output) =
            ('blocked', 'plugin_disabled', 0, 0);
    }
    elsif ($mode eq 'off') {
        ($decision, $reason, $runs, $output) =
            ('blocked', 'channel_off', 0, 0);
    }
    elsif ($mode eq 'observe') {
        ($decision, $reason, $runs, $output) =
            ('shadow', 'policy_observe', 1, 0);
    }
    else {
        ($decision, $reason, $runs, $output) =
            ('active', 'policy_on', 1, 1);
    }

    my $saved_handlers = ref($entry->{mounted_commands}) eq 'ARRAY'
        ? scalar(grep { ref($_) eq 'HASH' && ref($_->{restore}) eq 'HASH' }
            @{ $entry->{mounted_commands} }) : 0;
    my $fallback_visible = $saved_handlers
        && (!$entry->{enabled} || $mode eq 'off' || $mode eq 'observe')
        ? 1 : 0;

    return {
        plugin           => "$entry->{name}",
        channel          => defined($policy->{channel})
            ? "$policy->{channel}" : "$args{channel}",
        lifecycle        => $entry->{enabled} ? 'enabled' : 'disabled',
        configured       => $configured,
        policy_mode      => $mode,
        decision         => $decision,
        reason           => $reason,
        plugin_runs      => $runs,
        output_allowed   => $output,
        saved_handlers   => $saved_handlers,
        fallback_visible => $fallback_visible,
    };
}

1;
