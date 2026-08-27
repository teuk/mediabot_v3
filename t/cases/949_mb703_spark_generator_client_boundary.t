# t/cases/949_mb703_spark_generator_client_boundary.t
# =============================================================================
# MB703-C — Generator can use the common AI client without owning IRC delivery.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::Generator;

{
    package MB703C::Client;
    sub new { bless { requests => [] }, shift }
    sub execute {
        my ($self, $request) = @_;
        push @{ $self->{requests} }, $request;
        return { ok => 1, answer => 'LINE: Même le silence avait fini par trouver cette conversation trop longue.' };
    }
    sub submit {
        my ($self, $request, %args) = @_;
        push @{ $self->{requests} }, $request;
        $args{on_done}->({ ok => 1, answer => "QUESTION: Priorité absolue ?\nA: Réparer proprement\nB: Redémarrer et nier" });
        return 1;
    }
    sub requests { $_[0]{requests} }
}

return sub {
    my ($assert) = @_;

    my $client = MB703C::Client->new;
    my $gen = Mediabot::Spark::Generator->new(client => $client);

    my $callback = $gen->execute(
        kind     => 'callback',
        language => 'fr',
        context  => [
            'Alice: le service est encore debout',
            'Bob: techniquement oui',
            'Carol: ce mot fait beaucoup de travail',
        ],
    );
    $assert->is($callback->{action}, 'ready',
        'mb703-949: injected provider-neutral client can generate Callback content');
    $assert->is($client->requests->[0]{purpose}, 'spark.callback',
        'mb703-949: client receives Spark-specific request purpose');

    my $async;
    my $started = $gen->submit(
        kind     => 'fork',
        language => 'fr',
        on_done  => sub { $async = shift },
    );
    $assert->is($started, 1,
        'mb703-949: async Spark generation delegates to client submit');
    $assert->is($async->{action}, 'ready',
        'mb703-949: async result is parsed before caller receives it');
    $assert->is($async->{kind}, 'fork',
        'mb703-949: async result preserves event kind');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/Spark/Generator.pm"
            or die "open Generator.pm: $!";
        local $/;
        <$fh>;
    };
    $assert->like($src, qr/use Mediabot::AI::Client/,
        'mb703-949: Spark uses the existing provider-neutral AI client');
    $assert->unlike($src, qr/\b(?:botPrivmsg|botNotice|send_message|do_PRIVMSG|Net::Async::IRC)\b/,
        'mb703-949: Spark Generator owns no IRC emission primitive');
    $assert->unlike($src, qr/\b(?:DBI|CHANNEL_SET|CHANSET_LIST)\b/,
        'mb703-949: Spark Generator owns no database/chanset access');
};
