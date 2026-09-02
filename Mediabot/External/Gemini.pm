package Mediabot::External::Gemini;

use strict;
use warnings;
use utf8;

use Exporter 'import';
use Encode ();

use Mediabot::AI qw(provider_configured);
use Mediabot::AI::Client ();
use Mediabot::AI::Request qw(build_request);
use Mediabot::AI::Transport ();
use Mediabot::AI::Provider::Gemini ();
use Mediabot::Helpers ();
use Mediabot::External::Claude ();

our $VERSION = '1.0';
our @EXPORT_OK = qw(gemini_ctx geminiAI);

use constant {
    GEMINI_SYSTEM_PROMPT    => 'You are a helpful IRC assistant. Answer clearly and concisely in the language of the user.',
    GEMINI_TEMPERATURE      => 0.7,
    GEMINI_MAX_TOKENS       => 1024,
    GEMINI_MAX_PRIVMSG      => 4,
    GEMINI_WRAP_BYTES       => 400,
    GEMINI_SLEEP_US         => 750_000,
    GEMINI_TIMEOUT          => 30,
    GEMINI_RATE_MAX         => 5,
    GEMINI_RATE_WINDOW      => 60,
    GEMINI_MAX_PROMPT_CHARS => 4000,
    GEMINI_TRUNC_MSG        => ' [truncated]',
};

sub _conf_string {
    my ($self, $key, $default) = @_;
    my $value = eval { $self->{conf}->get($key) };
    return $default unless defined($value) && !ref($value) && length("$value");
    return "$value";
}

sub _conf_int {
    my ($self, $key, $default, $min, $max) = @_;
    my $value = eval { $self->{conf}->get($key) };
    return $default unless defined($value) && !ref($value) && "$value" =~ /^\d+\z/;
    $value = int($value);
    return $default if defined($min) && $value < $min;
    return $default if defined($max) && $value > $max;
    return $value;
}

sub _conf_float {
    my ($self, $key, $default, $min, $max) = @_;
    my $value = eval { $self->{conf}->get($key) };
    return $default unless defined($value) && !ref($value)
        && "$value" =~ /^\d+(?:\.\d+)?\z/;
    $value = 0 + $value;
    return $default if defined($min) && $value < $min;
    return $default if defined($max) && $value > $max;
    return $value;
}

sub _metric {
    my ($self, $name) = @_;
    eval { $self->{metrics}->inc($name) if $self->{metrics}; 1 };
}

sub _emit_notice {
    my ($self, $nick, $text) = @_;
    Mediabot::Helpers::botNotice($self, $nick, $text);
}

sub _strict_chanset_enabled {
    my ($self, $channel) = @_;
    return 0 unless defined($channel) && !ref($channel) && $channel =~ /^#/;

    my $list_id = eval { Mediabot::External::getIdChansetList($self, 'Gemini') };
    return 0 unless defined($list_id) && "$list_id" ne '';

    my $set_id = eval {
        Mediabot::External::getIdChannelSet($self, $channel, $list_id)
    };
    return defined($set_id) && "$set_id" ne '' ? 1 : 0;
}

sub _fit_suffix {
    my ($text, $suffix, $budget) = @_;
    $text   = '' unless defined $text;
    $suffix = '' unless defined $suffix;

    while (length($text) && length(Encode::encode('UTF-8', $text . $suffix)) > $budget) {
        chop $text;
    }
    return $text . $suffix;
}

sub _deliver_answer {
    my ($self, $state, $answer) = @_;
    return undef unless defined($answer) && !ref($answer) && length($answer);

    $answer =~ s/[\r\n]+/ /g;
    $answer =~ s/\s{2,}/ /g;
    $answer =~ s/^\s+|\s+$//g;
    return undef unless length $answer;

    my @chunks = Mediabot::Helpers::_split_text_for_irc(
        $answer, $state->{wrap_bytes}
    );
    return undef unless @chunks;

    my $truncated = @chunks > $state->{max_privmsg};
    my $last = $truncated ? $state->{max_privmsg} - 1 : $#chunks;
    if ($truncated) {
        $chunks[$last] = _fit_suffix(
            $chunks[$last], GEMINI_TRUNC_MSG, $state->{wrap_bytes}
        );
    }

    my @out = @chunks[0 .. $last];
    my $queued = Mediabot::External::Claude::_queue_irc_chunks(
        $self, $state->{channel}, \@out, $state->{sleep_us}, 'Gemini'
    );
    $self->{logger}->log(4, "geminiAI() queued $queued PRIVMSG");
    return $answer;
}

sub _accept_result {
    my ($self, $state, $result) = @_;

    unless (ref($result) eq 'HASH' && $result->{ok}
        && ($result->{provider} // '') eq 'gemini') {
        my $status = ref($result) eq 'HASH' ? ($result->{status} // 0) : 0;
        my $error  = ref($result) eq 'HASH' ? ($result->{error} // 'client_failed') : 'client_failed';
        my $type   = ref($result) eq 'HASH' ? ($result->{error_type} // '') : '';
        my $code   = ref($result) eq 'HASH' ? ($result->{error_code} // '') : '';
        my $detail = ref($result) eq 'HASH' && $error eq 'parse_error'
            ? ($result->{error_message} // '')
            : '';
        for ($error, $type, $code, $detail) {
            $_ =~ s/[\r\n\0]+/ /g;
            $_ = substr($_, 0, 240);
        }
        $self->{logger}->log(1,
            "geminiAI() AI::Client error: $error status=$status type=$type code=$code detail=$detail");
        _metric($self, 'mediabot_gemini_errors_total');

        my $message = ref($result) eq 'HASH' && ($result->{provider} // '') eq 'gemini'
            ? Mediabot::AI::Provider::Gemini::user_error_message($status, $type, $code)
            : 'Sorry, Gemini did not answer.';
        Mediabot::Helpers::botPrivmsg(
            $self, $state->{channel}, "($state->{nick}) $message"
        );
        return undef;
    }

    my $answer = _deliver_answer($self, $state, $result->{answer});
    unless (defined $answer) {
        $self->{logger}->log(1, 'geminiAI() empty or invalid provider answer');
        _metric($self, 'mediabot_gemini_errors_total');
        Mediabot::Helpers::botPrivmsg(
            $self, $state->{channel}, "($state->{nick}) Could not read Gemini response."
        );
    }
    return $answer;
}

sub _client {
    my ($self) = @_;
    return Mediabot::AI::Client->new(
        conf       => $self->{conf},
        loop_owner => $self,
    );
}

sub gemini_ctx {
    my ($ctx) = @_;
    my @args = ref($ctx->args) eq 'ARRAY' ? @{ $ctx->args } : ();
    return geminiAI(
        $ctx->bot, $ctx->message, $ctx->nick, $ctx->channel, @args
    );
}

sub geminiAI {
    my ($self, $message, $nick, $channel, @args) = @_;

    # The channel capability is the outermost public boundary.  A disabled
    # channel must not learn whether Gemini is configured, or even receive a
    # syntax notice from this command.
    return unless _strict_chanset_enabled($self, $channel);

    unless (provider_configured($self->{conf}, 'gemini')) {
        $self->{logger}->log(0, 'geminiAI() gemini.API_KEY missing');
        _emit_notice($self, $nick,
            'Gemini is not configured on this bot (missing gemini.API_KEY).');
        return;
    }

    @args or (_emit_notice($self, $nick, 'Syntax: gemini <prompt>'), return);

    my $prompt = join ' ', @args;
    my $max_prompt = _conf_int(
        $self, 'gemini.MAX_PROMPT_CHARS', GEMINI_MAX_PROMPT_CHARS, 256, 16_000
    );
    if (length($prompt) > $max_prompt) {
        _emit_notice($self, $nick,
            "Gemini prompt too long (maximum $max_prompt characters).");
        return;
    }

    my $rate_key = lc($nick) . "\x00" . lc($channel);
    if ($self->{_gemini_inflight}{$rate_key}) {
        _emit_notice($self, $nick,
            'Gemini is already processing a request for this conversation.');
        return 1;
    }

    my $rate_max = _conf_int(
        $self, 'gemini.RATE_MAX', GEMINI_RATE_MAX, 1, 100
    );
    my $rate_window = _conf_int(
        $self, 'gemini.RATE_WINDOW', GEMINI_RATE_WINDOW, 10, 3600
    );
    my $now = time();
    my $rate = $self->{_gemini_ratelimit}{$rate_key} //= {
        count => 0, window => $now,
    };
    if ($now - $rate->{window} >= $rate_window) {
        $rate->{count} = 0;
        $rate->{window} = $now;
    }
    if (++$rate->{count} > $rate_max) {
        my $wait = $rate_window - ($now - $rate->{window});
        _metric($self, 'mediabot_gemini_ratelimit_total');
        _emit_notice($self, $nick,
            "Gemini rate limit: wait ${wait}s before retrying.");
        return;
    }

    my $system = _conf_string(
        $self, 'gemini.SYSTEM_PROMPT', GEMINI_SYSTEM_PROMPT
    );
    $system =~ s/[\r\n]+/ /g;
    $system = substr($system, 0, 800);

    my $request = eval { build_request(
        provider          => 'gemini',
        purpose           => 'gemini',
        system            => $system,
        messages          => [ { role => 'user', content => $prompt } ],
        max_output_tokens => _conf_int(
            $self, 'gemini.MAX_TOKENS', GEMINI_MAX_TOKENS, 1, 4000
        ),
        temperature       => _conf_float(
            $self, 'gemini.TEMPERATURE', GEMINI_TEMPERATURE, 0, 2
        ),
        timeout_seconds   => _conf_int(
            $self, 'gemini.TIMEOUT', GEMINI_TIMEOUT, 5, 60
        ),
    ) };
    unless ($request) {
        my $error = $@ || 'request build failure';
        $error =~ s/[\r\n\0]+/ /g;
        $self->{logger}->log(1, "geminiAI() request build error: $error");
        _metric($self, 'mediabot_gemini_errors_total');
        _emit_notice($self, $nick, 'Internal error building Gemini request.');
        return;
    }

    my $state = {
        nick        => $nick,
        channel     => $channel,
        max_privmsg => _conf_int(
            $self, 'gemini.MAX_PRIVMSG', GEMINI_MAX_PRIVMSG, 1, 8
        ),
        wrap_bytes  => _conf_int(
            $self, 'gemini.WRAP_BYTES', GEMINI_WRAP_BYTES, 120, 450
        ),
        sleep_us    => _conf_int(
            $self, 'gemini.SLEEP_US', GEMINI_SLEEP_US, 0, 2_000_000
        ),
    };

    my $client = eval { _client($self) };
    unless ($client) {
        my $error = $@ || 'client construction failure';
        $error =~ s/[\r\n\0]+/ /g;
        $self->{logger}->log(1, "geminiAI() AI::Client construction failed: $error");
        _metric($self, 'mediabot_gemini_errors_total');
        _emit_notice($self, $nick, 'Sorry, Gemini did not answer.');
        return;
    }

    _metric($self, 'mediabot_gemini_requests_total');
    $self->{logger}->log(4,
        'geminiAI() request submitted for ' . $channel . ' / ' . $nick);

    if (Mediabot::AI::Transport::usable_loop($self)) {
        $self->{_gemini_inflight}{$rate_key} = time();
        my $completed = 0;
        my $done = sub {
            my ($result) = @_;
            return if $completed++;
            delete $self->{_gemini_inflight}{$rate_key};
            _accept_result($self, $state, $result);
        };

        my $started;
        my $ok = eval {
            $started = $client->submit($request, on_done => $done);
            1;
        };
        unless ($ok || $completed) {
            my $error = $@ || 'submit failure';
            $error =~ s/[\r\n\0]+/ /g;
            $self->{logger}->log(1, "geminiAI() AI::Client submit failed: $error");
            delete $self->{_gemini_inflight}{$rate_key};
            _metric($self, 'mediabot_gemini_errors_total');
            _emit_notice($self, $nick, 'Sorry, Gemini did not answer.');
            return;
        }
        unless ($started || $completed) {
            delete $self->{_gemini_inflight}{$rate_key};
            _metric($self, 'mediabot_gemini_errors_total');
            _emit_notice($self, $nick, 'Sorry, Gemini did not answer.');
        }
        return 1;
    }

    my $result = eval { $client->execute($request) };
    unless ($result) {
        my $error = $@ || 'execute failure';
        $error =~ s/[\r\n\0]+/ /g;
        $self->{logger}->log(1, "geminiAI() AI::Client execute failed: $error");
        _metric($self, 'mediabot_gemini_errors_total');
        _emit_notice($self, $nick, 'Sorry, Gemini did not answer.');
        return;
    }

    return _accept_result($self, $state, $result);
}

1;
