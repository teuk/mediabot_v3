# t/cases/527_mb305_metrics_log_severity.t
# =============================================================================
# MB305: Metrics errors must remain visible at MAIN_PROG_DEBUG=0 and named
# logger fallbacks must preserve symbolic severity.
# =============================================================================

use strict;
use warnings;

return sub {
    my ($assert) = @_;

    # Run the behavioral probe in a child Perl process. The small optional-module
    # stubs are therefore isolated and cannot pollute the shared static runner.
    my $probe = <<'PROBE';
BEGIN {
    $INC{'IO/Async/Listener.pm'} = __FILE__;
    $INC{'JSON/MaybeXS.pm'}      = __FILE__;

    package IO::Async::Listener;
    sub import { return 1 }

    package JSON::MaybeXS;
    sub import {
        my ($class, @symbols) = @_;
        my $caller = caller;
        no strict 'refs';
        for my $symbol (@symbols) {
            next unless $symbol eq 'encode_json';
            *{"${caller}::encode_json"} = \&encode_json;
        }
    }
    sub encode_json { return '{}' }
}

use lib '.';
use Mediabot::Metrics;

{
    package ProbeNumericLogger;
    sub new { return bless { entries => [] }, shift }
    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{entries} }, [$level, $message];
        return 1;
    }
}

{
    package ProbeNamedLogger;
    sub new { return bless { entries => [] }, shift }
    sub info  { my ($self, $message) = @_; push @{ $self->{entries} }, ['info',  $message]; return 1 }
    sub error { my ($self, $message) = @_; push @{ $self->{entries} }, ['error', $message]; return 1 }
    sub debug { my ($self, $message) = @_; push @{ $self->{entries} }, ['debug', $message]; return 1 }
}

my $numeric = ProbeNumericLogger->new;
my $metrics = bless { logger => $numeric }, 'Mediabot::Metrics';

$metrics->_log('ERROR', 'bind failed');
$metrics->_log('INFO',  'listener ready');
$metrics->_log('WARN',  'slow scrape');
$metrics->_log('DEBUG', 'request details');
$metrics->_log(4,       'numeric level');

my $named = ProbeNamedLogger->new;
my $named_metrics = bless { logger => $named }, 'Mediabot::Metrics';

$named_metrics->_log('ERROR', 'provider failed');
$named_metrics->_log('INFO',  'provider ready');
$named_metrics->_log('DEBUG', 'provider details');

print join(',', map { $_->[0] } @{ $numeric->{entries} });
print '|';
print join(',', map { $_->[0] } @{ $named->{entries} });
PROBE

    open my $fh, '-|', $^X, '-I.', '-e', $probe
        or die "could not start MB305 probe: $!";

    local $/;
    my $output = <$fh> // '';
    close $fh;
    my $rc = $? >> 8;

    $output =~ s/\s+\z//;

    $assert->is($rc, 0,
        'isolated Metrics logging probe exits successfully');
    $assert->is($output, '0,0,1,2,4|error,info,debug',
        'symbolic and numeric severities keep the expected behavior');
};
