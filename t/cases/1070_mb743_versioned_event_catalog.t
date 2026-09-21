# MB743 — versioned event catalogue and immutable bounded envelopes.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub _slurp_1070 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    require Mediabot::Plugin::EventCatalogV3;
    require Mediabot::Plugin::EventEnvelopeV3;
    require Mediabot::Plugin::ManifestV3;

    my $api_contract = JSON::PP->new->decode(
        _slurp_1070('plugins/API_V3_CONTRACT.json'));
    $assert->is($api_contract->{milestone}, 'MB761',
        'API v3 machine contract records the current platform milestone');
    $assert->is(join(',', @{ $api_contract->{implemented_capabilities} }),
        'data.factoids.read,data.factoids.write,data.quotes.read,data.quotes.write,events.subscribe,http.fetch,irc.channel_message,irc.notice,irc.reply,scheduler.jobs,storage.kv',
        'machine contract lists the eleven executable capabilities');
    $assert->is($api_contract->{event_backpressure}{max_pending_per_plugin}, 32,
        'machine contract publishes the queue bound');
    $assert->is($api_contract->{event_backpressure}{dispatch_batch_size}, 8,
        'machine contract publishes the dispatch batch');
    $assert->is($api_contract->{operator_diagnostics}{mode}, 'read-only',
        'machine contract keeps operator diagnostics non-mutating');
    $assert->is($api_contract->{operator_diagnostics}{configuration_values},
        'unavailable', 'machine contract excludes channel config values');
    $assert->is(
        $api_contract->{runtime_failure_history}{maximum_recent_records}, 16,
        'machine contract publishes the per-instance history bound');
    $assert->is($api_contract->{runtime_failure_history}{error_text},
        'unavailable', 'machine contract excludes raw exception text');
    $assert->is($api_contract->{manual_quarantine}{maximum_entries}, 64,
        'machine contract publishes the per-instance quarantine bound');
    $assert->is($api_contract->{manual_quarantine}{automatic_trigger},
        'none', 'machine contract forbids failure-driven quarantine');
    $assert->is($api_contract->{manual_quarantine}{failure_history},
        'preserve', 'quarantine release does not erase evidence');
    $assert->is($api_contract->{quote_write_limits}{activation}, 'on only',
        'machine contract forbids writes in observe mode');
    $assert->is($api_contract->{quote_write_limits}{plugin_adoption},
        'quotes-v3 q and quote, inactive by default',
        'machine contract keeps quote adoption operator-controlled');
    $assert->is($api_contract->{factoid_read_limits}{plugin_adoption},
        'factoids-v3 factoid, factoids, learn and forget, inactive by default',
        'machine contract keeps factoid adoption operator-controlled');
    $assert->is($api_contract->{factoid_write_limits}{plugin_adoption},
        'factoids-v3 learn and forget, inactive by default',
        'machine contract keeps factoid writes operator-controlled');

    my $published = JSON::PP->new->decode(
        _slurp_1070('plugins/API_V3_EVENTS.json'));
    my @runtime_names = Mediabot::Plugin::EventCatalogV3->event_names;
    $assert->is(join(',', @runtime_names),
        join(',', sort keys %{ $published->{events} }),
        'machine-readable and executable event catalogues agree');
    for my $name (@runtime_names) {
        my @versions = Mediabot::Plugin::EventCatalogV3->versions_for($name);
        $assert->is(join(',', @versions),
            join(',', sort { $a <=> $b } keys %{ $published->{events}{$name} }),
            "published versions agree for $name");
        for my $version (@versions) {
            my $runtime_fields =
                Mediabot::Plugin::EventCatalogV3->field_contract(
                    $name, $version);
            $assert->is(
                JSON::PP->new->canonical->encode($runtime_fields),
                JSON::PP->new->canonical->encode(
                    $published->{events}{$name}{$version}{fields}),
                "published field schema agrees for $name v$version",
            );
        }
    }

    my $raw = {
        channel => "#i/o\nignored",
        nick    => 'Tangy',
        ident   => [],
        host    => 'example.test',
        is_self => 0,
        secret  => 'must not cross',
    };
    my $event = Mediabot::Plugin::EventCatalogV3->envelope(
        'irc.channel.join', 1, $raw, occurred_at => 1234);
    $assert->is($event->name, 'irc.channel.join',
        'envelope exposes the canonical event name');
    $assert->is($event->version, 1,
        'envelope exposes the schema version');
    $assert->is($event->occurred_at, 1234,
        'envelope carries a core-owned timestamp');
    $assert->is($event->get('channel'), '#i/o ignored',
        'scalar event data is single-line and bounded');
    $assert->ok(!defined($event->get('ident')),
        'reference-valued input is rejected');
    $assert->ok(!defined($event->get('secret')),
        'undeclared fields never cross the catalogue');

    my $invalid_boolean = Mediabot::Plugin::EventCatalogV3->envelope(
        'irc.channel.join', 1, { is_self => 'false' });
    $assert->ok(!defined($invalid_boolean->get('is_self')),
        'boolean fields reject ambiguous scalar values');

    my $copy = $event->data;
    $copy->{nick} = 'mutated';
    $assert->is($event->get('nick'), 'Tangy',
        'event data accessor returns a detached copy');

    my $ok = eval {
        Mediabot::Plugin::EventCatalogV3->assert_supported(
            'irc.channel.join', 2);
        1;
    };
    $assert->like($@ // '', qr/unsupported event .* version '2'/,
        'unknown event versions fail closed');

    my $manifest = Mediabot::Plugin::ManifestV3->load_file(
        'plugins/hello-v3/plugin.json', expected_name => 'hello-v3');
    my %without_event_cap = (%$manifest,
        capabilities => ['irc.reply', 'scheduler.jobs']);
    $ok = eval {
        Mediabot::Plugin::ManifestV3->validate(\%without_event_cap);
        1;
    };
    $assert->like($@ // '', qr/events require capability 'events\.subscribe'/,
        'event declarations require their explicit capability');

    my %without_job_cap = (%$manifest,
        capabilities => ['events.subscribe', 'irc.reply']);
    $ok = eval {
        Mediabot::Plugin::ManifestV3->validate(\%without_job_cap);
        1;
    };
    $assert->like($@ // '', qr/jobs require capability 'scheduler\.jobs'/,
        'job declarations require their explicit capability');

    require Mediabot::Plugin::JobInvocationV3;
    $ok = eval {
        Mediabot::Plugin::JobInvocationV3->new(
            name => 'heartbeat', sequence => 1, fired_at => 'soon');
        1;
    };
    $assert->like($@ // '', qr/invalid fired_at timestamp/,
        'job invocation rejects non-numeric timestamps');
};
