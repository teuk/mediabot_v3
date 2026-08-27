# t/cases/965_mb703_spark_private_candidate_boundary.t
use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Spark::DryRun;

{
    package Local::SparkGenerator965;
    sub new { bless {}, shift }
    sub submit {
        my ($self, %args) = @_;
        $args{on_done}->({
            action => 'ready', reason => 'generated', kind => 'callback',
            provider => 'openai', model => 'test-model',
            content => { line => 'private generated payload' },
        });
        return 1;
    }
}

return sub {
    my ($assert) = @_;
    my $dry = Mediabot::Spark::DryRun->new(generator => Local::SparkGenerator965->new());
    my ($candidate, $summary);
    my $generation = $dry->submit_candidate(
        channel => '#spark', kind => 'callback', language => 'en',
        context => [ 'a', 'b', 'c' ],
        on_candidate => sub { $candidate = shift },
        on_result => sub { $summary = shift },
    );

    $assert->ok($generation,
        'mb703-965: provider request obtains a generation token');
    $assert->is($candidate->{generated}{content}{line}, 'private generated payload',
        'mb703-965: generated text crosses only the private candidate callback');
    $assert->ok(!exists($summary->{content}),
        'mb703-965: metadata result callback never contains generated content');

    my $log = Mediabot::Spark::DryRun::format_ai_dryrun_log('#spark', $summary);
    $assert->unlike($log, qr/private generated payload/,
        'mb703-965: AI dry-run log remains content-free after live sender wiring');
};
