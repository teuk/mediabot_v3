package Mediabot::Spark::Replay;

use strict;
use warnings;
use Exporter 'import';
use Mediabot::AI::ConversationExclusion;
use Mediabot::AI::ConversationFloodGuard;
use Mediabot::Spark::Observer;
use Mediabot::Spark::Orchestrator;
use Mediabot::Spark::State;

our @EXPORT_OK = qw(replay_events);

# An offline run uses the production classifiers and policies with a virtual
# monotonic clock. A candidate is only a decision; no generator or sender is
# constructed and neither Spark send arm is consulted or enabled.
sub replay_events {
    my (%args) = @_;
    my $events = $args{events};
    my $channel = $args{channel};
    my $bot_nick = $args{bot_nick};
    die "invalid replay input\n" unless $args{conf}
        && eval { $args{conf}->can('get') }
        && defined($channel) && !ref($channel)
        && $channel =~ /\A\#[^\s,:\x00-\x1f\x7f]{1,79}\z/
        && defined($bot_nick) && !ref($bot_nick)
        && $bot_nick =~ /\A[^\s,:\x00-\x1f\x7f]{1,100}\z/
        && ref($events) eq 'ARRAY' && @$events <= 256;

    # The live observer receives the instance's configured public command
    # prefix. A replay must use that same prefix or it may count commands as
    # human conversation. Older synthetic fixtures without this key use !.
    my $command_char = eval { $args{conf}->get('main.MAIN_PROG_CMD_CHAR') };
    die "replay command prefix unavailable\n" if $@;
    $command_char = '!' unless defined($command_char) && "$command_char" ne '';
    die "invalid replay command prefix\n"
        if ref($command_char) || length("$command_char") != 1
            || "$command_char" =~ /[\s\x00-\x1f\x7f]/;

    my $time = 10_000;
    my $clock = sub { $time };
    my $observer = Mediabot::Spark::Observer->new(clock => $clock);
    my $runtime = Mediabot::Spark::Orchestrator->new(
        state => Mediabot::Spark::State->new(clock => $clock),
        observer => $observer,
        flood_guard => Mediabot::AI::ConversationFloodGuard->new(clock => $clock),
        clock => $clock,
    );
    my $exclusion = Mediabot::AI::ConversationExclusion->new(conf => $args{conf});
    my (%excluded, %decisions);
    my @probes;
    my ($previous, $window, $last_momentum_window) = (-1, 0, -1);
    my $repeated_momentum = 0;

    for my $event (@$events) {
        die "invalid replay event\n" unless ref($event) eq 'HASH'
            && defined($event->{at}) && !ref($event->{at})
            && "$event->{at}" =~ /\A\d{1,6}\z/
            && $event->{at} <= 604_800 && $event->{at} >= $previous
            && defined($event->{type}) && !ref($event->{type})
            && ($event->{type} eq 'line' || $event->{type} eq 'probe');
        $previous = int($event->{at});
        $time = 10_000 + $previous;

        if ($event->{type} eq 'line') {
            my ($nick, $message) = @{$event}{qw(nick message)};
            die "invalid replay line\n" unless defined($nick) && !ref($nick)
                && $nick =~ /\A[^\s,:\x00-\x1f\x7f]{1,100}\z/
                && defined($message) && !ref($message)
                && length($message) >= 1 && length($message) <= 240
                && $message !~ /[\x00-\x1f\x7f]/
                && (!exists($event->{from_bot})
                    || (!ref($event->{from_bot})
                        && "$event->{from_bot}" =~ /\A[01]\z/));
            my $classification = $exclusion->classify_public_line(
                channel => $channel, nick => $nick,
                bot_nick => $bot_nick, message => $message,
            );
            if ($classification->{excluded}) {
                $excluded{$classification->{reason}}++;
                next;
            }
            my $result = $runtime->observe_public_line(
                enabled => 1, channel => $channel,
                nick => $nick, message => $message,
                bot_nick => $bot_nick, command_char => $command_char,
                from_bot => $event->{from_bot} ? 1 : 0,
            );
            die "observer unavailable\n" unless ref($result) eq 'HASH'
                && ($result->{action} // '') eq 'observe';
            $window++ if ($result->{reason} // '') eq 'human_context';
            next;
        }

        my %gate = (
            channel => $channel, runtime_active => 1,
            irc_connected => 1, channel_joined => 1,
            game_active => 0, wit_pending => 0, ai_available => 1,
        );
        my $revival = $runtime->evaluate_channel(
            %gate, enabled => 1, vdm_enabled => 1, dtc_enabled => 1,
        );
        my $momentum = $runtime->evaluate_action_channel(
            %gate, spark_enabled => 1, action_enabled => 1,
        );
        die "policy unavailable\n" unless ref($revival) eq 'HASH'
            && ref($momentum) eq 'HASH';
        my $is_candidate = ($momentum->{action} // '') eq 'action_candidate';
        $repeated_momentum++ if $is_candidate
            && $last_momentum_window == $window;
        $last_momentum_window = $window if $is_candidate;
        for my $entry ([revival => $revival], [momentum => $momentum]) {
            my ($lane, $decision) = @$entry;
            my $action = $decision->{action} // 'unknown';
            my $reason = $decision->{reason} // 'unknown';
            die "invalid policy token\n" unless $action =~ /\A[a-z_]+\z/
                && $reason =~ /\A[a-z_]+\z/;
            $decisions{"$lane:$action:$reason"}++;
        }
        push @probes, {
            at => $previous,
            revival => $revival->{action},
            revival_reason => $revival->{reason},
            revival_regime => ($revival->{audience_regime} // 'unknown') =~
                /\A(?:empty|solo|small|social|crowded)\z/
                    ? $revival->{audience_regime} : 'unknown',
            momentum => $momentum->{action},
            momentum_reason => $momentum->{reason},
            momentum_regime => ($momentum->{audience_regime} // 'unknown') =~
                /\A(?:empty|solo|small|social|crowded)\z/
                    ? $momentum->{audience_regime} : 'unknown',
        };
    }

    return {
        probes => \@probes,
        excluded => \%excluded,
        decisions => \%decisions,
        repeated_momentum => $repeated_momentum,
    };
}

1;
