package Mediabot::Version::Command;

use strict;
use warnings;

# Command presentation and sequencing only. The facade supplies call-time
# providers for identity, normalization, comparison, audit and remote lookup.
# Context retains reply routing; the remote provider owns completion/lifecycle.
sub run {
    my ($ctx, $deps) = @_;

    my $self     = $ctx->bot;
    my $conf     = $self->{conf};
    my $bot_name = $conf->get('main.MAIN_PROG_NAME') // 'Mediabot';
    my $message  = $ctx->message;

    # MB391: the core identity command must answer immediately from the local
    # source of truth. GitHub remains an optional asynchronous follow-up and can
    # never delay or suppress the basic version reply.
    my $local_version = $deps->{normalize}->($deps->{cached}->($self))
        // $deps->{normalize}->($deps->{local}->($self))
        // 'unknown';

    $self->{main_prog_version} = $local_version
        if $local_version ne 'unknown';

    $ctx->reply("$bot_name version: $local_version");
    $deps->{audit}->($self, $message, undef, 'version', undef);

    $deps->{remote}->(
        $self,
        sub {
            my ($worker_local, $remote_version) = @_;

            $worker_local = $deps->{normalize}->($worker_local)
                // $deps->{normalize}->($local_version)
                // 'unknown';
            $remote_version = $deps->{normalize}->($remote_version);

            if ($local_version eq 'unknown' && $worker_local ne 'unknown') {
                $local_version = $worker_local;
                $self->{main_prog_version} = $worker_local;
                $ctx->reply("$bot_name version: $worker_local");
            }

            return unless defined $remote_version;

            my $comparison = $deps->{compare}->(
                $local_version,
                $remote_version,
            );

            if (!defined $comparison) {
                $ctx->reply(
                    "$bot_name repository version format unknown: $remote_version"
                );
            }
            elsif ($comparison < 0) {
                $ctx->reply(
                    "$bot_name update available: $remote_version (local: $local_version)"
                );
            }
            elsif ($comparison > 0) {
                $ctx->reply(
                    "$bot_name local build newer than repository: $local_version (repository: $remote_version)"
                );
            }
        },
    );

    return 1;
}

1;
