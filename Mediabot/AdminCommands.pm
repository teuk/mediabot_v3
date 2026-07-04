package Mediabot::AdminCommands;

# =============================================================================
# Mediabot::AdminCommands — Bot administration commands
#   mbStatus, mbQuit, mbRehash, mbRestart, mbJump, mbExec, debug, update
# =============================================================================

use strict;
use warnings;
use File::Basename qw(dirname);
use POSIX qw(strftime setsid WNOHANG);
use Exporter 'import';
use List::Util qw(min);
use Scalar::Util qw(weaken);
use IO::Async::Timer::Countdown;
use Sys::Hostname qw(hostname);
use HTTP::Tiny;
use JSON qw(encode_json decode_json);
use Time::HiRes qw(time);
use Mediabot::Helpers;
use Mediabot::External ();

use Mediabot::Context;
use Mediabot::Radio::Icecast;
use Mediabot::Liquidsoap;
use Mediabot::Radio::Request;

our @EXPORT = qw(
    debug_ctx
    openai_ctx
    mbExec_ctx
    mbJump
    mbQuit_ctx
    mbRehash_ctx
    mbRestart
    mbStatus_ctx
    radioStatus_ctx
    radioMounts_ctx
    displayRadioListeners_ctx
    radioNext_ctx
    song_ctx
    radioQueue_ctx
    radioPush_ctx
    radioSkip_ctx
    radioFlush_ctx
    radioPlay_ctx
    radioImport_ctx
    radioImportDir_ctx
    radioCheck_ctx
    radioCache_ctx
    radioCachePrune_ctx
    radioDlStatus_ctx
    radioDlCancel_ctx
    update
    update_ctx
);


sub _radio_irc_text {
    my ($text, @ops) = @_;

    $text = '' unless defined $text;

    my $out = $text;

    eval {
        require String::IRC;

        my $irc = String::IRC->new($text);

        for my $op (@ops) {
            next unless defined $op;

            if (ref($op) eq 'ARRAY') {
                my ($method, @args) = @$op;
                next unless defined $method && $method ne '';
                next unless $irc->can($method);
                $irc = $irc->$method(@args);
            }
            else {
                next unless $op ne '';
                next unless $irc->can($op);
                $irc = $irc->$op();
            }
        }

        $out = "$irc";
        1;
    } or do {
        # Never break an IRC command because of formatting.
        $out = $text;
    };

    return $out;
}


sub _radio_irc_orange_text {
    my ($text, %opts) = @_;

    $text = '' unless defined $text;

    # IRC/mIRC color 07 is orange. We use raw IRC codes here because
    # String::IRC does not always expose an orange() helper depending on version.
    my $prefix = "\x0307";
    $prefix .= "\x02" if $opts{bold};
    $prefix .= "\x1F" if $opts{underline};

    return $prefix . $text . "\x0F";
}

sub _radio_format_song_line {
    my (%args) = @_;

    my $listen_url = defined $args{listen_url} && $args{listen_url} ne ''
        ? $args{listen_url}
        : 'unknown-url';

    my $title = defined $args{title} && $args{title} ne ''
        ? $args{title}
        : 'unknown';

    # Capsule-like style, close to mediacaps, but without a [ LIVE ! ] suffix.
    # No heavy background on the main text: stays readable on dark and light IRC clients.
    return
          _radio_irc_orange_text('[ ', bold => 1)
        . _radio_irc_orange_text($listen_url, underline => 1)
        . _radio_irc_orange_text(' ]', bold => 1)
        . _radio_irc_text('  -  ', 'white')
        . _radio_irc_orange_text('[ ', bold => 1)
        . _radio_irc_text($title, 'grey')
        . _radio_irc_orange_text(' ]', bold => 1);
}

sub _radio_format_listeners_line {
    my (%args) = @_;

    my $total = defined $args{total} ? $args{total} : '?';
    my $mount = defined $args{mount} && $args{mount} ne ''
        ? $args{mount}
        : '/radio.mp3';
    my $mount_listeners = defined $args{mount_listeners} ? $args{mount_listeners} : '?';

    # This deliberately uses only small red capsules, similar to mediacaps.
    # White-on-red is readable on both dark and light clients; the fallback is plain text.
    return
          _radio_irc_text('◖◗◖', ['white', 'red'], 'bold')
        . _radio_irc_text(' ( There are )-', 'white')
        . _radio_irc_text('( ', 'white')
        . _radio_irc_text($total, ['white', 'red'], 'bold')
        . _radio_irc_text(' )-', 'white')
        . _radio_irc_text('( Listeners', 'white')
        . _radio_irc_text(' on ', 'grey')
        . _radio_irc_text($mount, 'yellow')
        . _radio_irc_text(':', 'white')
        . _radio_irc_text($mount_listeners, ['white', 'red'], 'bold')
        . _radio_irc_text(' ) ', 'white')
        . _radio_irc_text('◗◖◗', ['white', 'red'], 'bold');
}



sub _radio_icecast_config {
    my ($self) = @_;

    my $conf = $self->{conf};

    my $base_url      = $conf->get('radio.RADIO_ICECAST_STATUS_BASE_URL') || 'http://127.0.0.1:8000';
    my $public_base   = $conf->get('radio.RADIO_ICECAST_PUBLIC_BASE_URL') || $base_url;
    my $primary_mount = $conf->get('radio.RADIO_ICECAST_PRIMARY_MOUNT')    || '/radio.mp3';
    my $timeout       = $conf->get('radio.RADIO_ICECAST_TIMEOUT');

    $timeout = 5 unless defined $timeout && $timeout =~ /^\d+$/ && $timeout > 0;

    return {
        base_url      => $base_url,
        public_base   => $public_base,
        primary_mount => $primary_mount,
        timeout       => $timeout,
    };
}

sub _radio_icecast_client {
    my ($self) = @_;

    my $cfg = _radio_icecast_config($self);

    my $radio = Mediabot::Radio::Icecast->new(
        base_url => $cfg->{base_url},
        timeout  => $cfg->{timeout},
        logger   => $self->{logger},
        ua       => Mediabot::External::_make_http(timeout => $cfg->{timeout}, verify_SSL => 0),  # shared HTTP factory
    );

    return ($radio, $cfg);
}

sub mbQuit_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $reason = @args ? join(' ', @args) : 'bye';

    logBot($self, $ctx->message, undef, 'die', $reason);

    $self->{Quit} = 1;
    $self->{irc}->send_message('QUIT', undef, $reason);
}

# Check if the user is logged in
sub _openai_param_spec {
    return {
        api_url => {
            key     => 'openai.API_URL',
            default => 'https://api.openai.com/v1/chat/completions',
            type    => 'url',
            help    => 'HTTPS endpoint used by tellme/chatGPT',
        },
        model => {
            key     => 'openai.MODEL',
            default => 'gpt-4o-mini',
            type    => 'model',
            help    => 'OpenAI model name, for example gpt-4o-mini or gpt-4o',
        },
        fallback_model => {
            key     => 'openai.FALLBACK_MODEL',
            default => '',
            type    => 'model',
            help    => 'Optional fallback model used when the primary model is forbidden or unavailable',
        },
        system_prompt => {
            key     => 'openai.SYSTEM_PROMPT',
            default => 'You always answer in a helpful and serious way, precise and never start your answer with « Oh là là » when the answer is in French. Always respond using a maximum of 10 lines of text and line-based. There is one chance on two the answer contains emojis.',
            type    => 'text',
            min     => 10,
            max     => 800,
            help    => 'System prompt controlling tellme/chatGPT tone and behavior',
        },
        temperature => {
            key     => 'openai.TEMPERATURE',
            default => '0.7',
            type    => 'float',
            min     => 0,
            max     => 2,
            help    => 'Creativity/randomness, from 0 to 2',
        },
        max_tokens => {
            key     => 'openai.MAX_TOKENS',
            default => '400',
            type    => 'int',
            min     => 1,
            max     => 4000,
            help    => 'Maximum answer tokens requested from the API',
        },
        max_privmsg => {
            key     => 'openai.MAX_PRIVMSG',
            default => '4',
            type    => 'int',
            min     => 1,
            max     => 8,
            help    => 'Maximum IRC PRIVMSG lines sent for one answer',
        },
        wrap_bytes => {
            key     => 'openai.WRAP_BYTES',
            default => '400',
            type    => 'int',
            min     => 120,
            max     => 450,
            help    => 'Approximate IRC-safe split size in bytes',
        },
        sleep_us => {
            key     => 'openai.SLEEP_US',
            default => '750000',
            type    => 'int',
            min     => 0,
            max     => 2000000,
            help    => 'Delay between output lines, in microseconds',
        },
        timeout => {
            key     => 'openai.TIMEOUT',
            default => '20',
            type    => 'int',
            min     => 5,
            max     => 60,
            help    => 'OpenAI HTTP timeout in seconds',
        },
    };
}

sub _openai_param_alias {
    my ($name) = @_;

    return undef unless defined($name);

    $name = lc($name);
    $name =~ s/[-.]/_/g;

    my %alias = (
        url          => 'api_url',
        apiurl       => 'api_url',
        api_url      => 'api_url',
        endpoint     => 'api_url',
        model        => 'model',
        fallback     => 'fallback_model',
        fallback_model => 'fallback_model',
        fallbackmodel  => 'fallback_model',
        prompt       => 'system_prompt',
        system      => 'system_prompt',
        system_prompt => 'system_prompt',
        systemprompt  => 'system_prompt',
        temp         => 'temperature',
        temperature  => 'temperature',
        tokens       => 'max_tokens',
        max_token    => 'max_tokens',
        max_tokens   => 'max_tokens',
        privmsg      => 'max_privmsg',
        max_privmsg  => 'max_privmsg',
        lines        => 'max_privmsg',
        wrap         => 'wrap_bytes',
        wrap_bytes   => 'wrap_bytes',
        sleep        => 'sleep_us',
        sleep_us     => 'sleep_us',
        delay        => 'sleep_us',
        timeout      => 'timeout',
        http_timeout => 'timeout',
    );

    return $alias{$name};
}

sub _openai_effective_value {
    my ($self, $name) = @_;

    my $spec = _openai_param_spec()->{$name};
    return undef unless $spec;

    my $value = $self->{conf}->get($spec->{key});
    return defined($value) && $value ne '' ? $value : $spec->{default};
}

sub _openai_validate_value {
    my ($name, $value) = @_;

    my $spec = _openai_param_spec()->{$name};

    return (0, "unknown OpenAI parameter") unless $spec;
    return (0, "missing value") unless defined($value) && $value ne '';

    if ($spec->{type} eq 'int') {
        return (0, "$name must be an integer") unless $value =~ /^\d+\z/;

        my $n = int($value);
        return (0, "$name must be >= $spec->{min}") if defined($spec->{min}) && $n < $spec->{min};
        return (0, "$name must be <= $spec->{max}") if defined($spec->{max}) && $n > $spec->{max};

        return (1, "$n");
    }

    if ($spec->{type} eq 'float') {
        return (0, "$name must be a number") unless $value =~ /^\d+(?:\.\d+)?\z/;

        my $n = 0 + $value;
        return (0, "$name must be >= $spec->{min}") if defined($spec->{min}) && $n < $spec->{min};
        return (0, "$name must be <= $spec->{max}") if defined($spec->{max}) && $n > $spec->{max};

        return (1, "$n");
    }

    if ($spec->{type} eq 'url') {
        return (0, "$name must start with https://") unless $value =~ m{^https://}i;
        return (0, "$name is too long") if length($value) > 250;

        return (1, $value);
    }

    if ($spec->{type} eq 'model') {
        return (0, "$name contains invalid characters") unless $value =~ /^[A-Za-z0-9._:-]+\z/;
        return (0, "$name is too long") if length($value) > 80;

        return (1, $value);
    }

    if ($spec->{type} eq 'text') {
        $value =~ s/\r|\n/ /g;
        $value =~ s/\s+/ /g;
        $value =~ s/^\s+|\s+\z//g;

        return (0, "$name is too short") if defined($spec->{min}) && length($value) < $spec->{min};
        return (0, "$name is too long")  if defined($spec->{max}) && length($value) > $spec->{max};

        return (1, $value);
    }

    return (0, "unsupported parameter type");
}

sub _openai_notice_status {
    my ($self, $nick, $channel) = @_;

    my $api_key = $self->{conf}->get('openai.API_KEY');
    my $has_key = (defined($api_key) && $api_key ne '') ? 'yes' : 'no';

    my $api_url     = _openai_effective_value($self, 'api_url');
    my $model          = _openai_effective_value($self, 'model');
    my $fallback_model = _openai_effective_value($self, 'fallback_model');
    $fallback_model = '(disabled)' unless defined($fallback_model) && $fallback_model ne '';
    my $temperature    = _openai_effective_value($self, 'temperature');
    my $max_tokens  = _openai_effective_value($self, 'max_tokens');
    my $max_privmsg = _openai_effective_value($self, 'max_privmsg');
    my $wrap_bytes  = _openai_effective_value($self, 'wrap_bytes');
    my $sleep_us      = _openai_effective_value($self, 'sleep_us');
    my $timeout       = _openai_effective_value($self, 'timeout');
    my $system_prompt = _openai_effective_value($self, 'system_prompt');
    my $system_prompt_len = length($system_prompt // '');

    my $chan_state = 'not checked';
    if (defined($channel) && $channel ne '') {
        my $setlist = getIdChansetList($self, 'chatGPT') // '';
        my $setid   = length($setlist) ? (getIdChannelSet($self, $channel, $setlist) // '') : '';
        $chan_state = length($setid) ? 'enabled' : 'disabled';
    }

    botNotice($self, $nick, "OpenAI/tellme: API key present: $has_key");
    botNotice($self, $nick, "OpenAI/tellme: model=$model fallback_model=$fallback_model api_url=$api_url");
    botNotice($self, $nick, "OpenAI/tellme: temperature=$temperature max_tokens=$max_tokens max_privmsg=$max_privmsg wrap_bytes=$wrap_bytes sleep_us=$sleep_us timeout=${timeout}s system_prompt_len=$system_prompt_len");

    if (defined($channel) && $channel ne '') {
        botNotice($self, $nick, "OpenAI/tellme: channel $channel chatGPT chanset: $chan_state");
    }
}

sub _openai_notice_help {
    my ($self, $nick) = @_;

    botNotice($self, $nick, "OpenAI admin syntax:");
    botNotice($self, $nick, "openai status|config|help|defaults|profiles|test|diagnose|models");
    botNotice($self, $nick, "openai set <model|fallback_model|system_prompt|temperature|max_tokens|max_privmsg|wrap_bytes|sleep_us|timeout|api_url> <value>");
    botNotice($self, $nick, "openai reset <model|fallback_model|system_prompt|temperature|max_tokens|max_privmsg|wrap_bytes|sleep_us|timeout|api_url>");
    botNotice($self, $nick, "openai explain <parameter>");
    botNotice($self, $nick, "openai test|diagnose [prompt]");
    botNotice($self, $nick, "openai models [filter]");
    botNotice($self, $nick, "openai profiles");
    botNotice($self, $nick, "openai profile <dev|compact|safe|default>");
    botNotice($self, $nick, "API_KEY is intentionally not changeable from IRC; edit mediabot.conf for secrets.");
}

sub _openai_notice_defaults {
    my ($self, $nick) = @_;

    my $spec = _openai_param_spec();

    for my $name (qw(model fallback_model temperature max_tokens max_privmsg wrap_bytes sleep_us timeout api_url)) {
        botNotice($self, $nick, "OpenAI default $name = $spec->{$name}{default}");
    }

    botNotice($self, $nick, "Recommended IRC dev profile: model=gpt-4o-mini temperature=0.6 max_tokens=700 max_privmsg=5 wrap_bytes=360 sleep_us=500000");
}

sub _openai_run_test {
    my ($self, $nick, @prompt_args) = @_;

    my $api_key = $self->{conf}->get('openai.API_KEY');

    unless (defined($api_key) && $api_key ne '') {
        botNotice($self, $nick, "OpenAI test: API key is missing.");
        return;
    }

    my $api_url        = _openai_effective_value($self, 'api_url');
    my $model          = _openai_effective_value($self, 'model');
    my $fallback_model = _openai_effective_value($self, 'fallback_model');
    my $temperature    = _openai_effective_value($self, 'temperature');

    $fallback_model = ''
        unless defined($fallback_model) && $fallback_model ne '';

    my $prompt = join(' ', @prompt_args);
    $prompt = 'Reply with exactly OK.' unless defined($prompt) && $prompt ne '';

    my $_openai_timeout = _openai_effective_value($self, 'timeout');
    $_openai_timeout = 20 unless defined($_openai_timeout) && $_openai_timeout =~ /^\d+\z/;
    $_openai_timeout = 5  if $_openai_timeout < 5;
    $_openai_timeout = 60 if $_openai_timeout > 60;
    my $http = Mediabot::External::_make_http(
        timeout    => $_openai_timeout,
        verify_SSL => 1,
    );

    my $build_payload = sub {
        my ($selected_model) = @_;

        return encode_json({
            model       => $selected_model,
            temperature => 0 + $temperature,
            max_tokens  => 40,
            messages    => [
                {
                    role    => 'system',
                    content => 'You are a tiny API health check. Answer briefly.',
                },
                {
                    role    => 'user',
                    content => $prompt,
                },
            ],
        });
    };

    my $send_test = sub {
        my ($selected_model) = @_;

        my $start = time();

        my $res = eval {
            $http->post(
                $api_url,
                {
                    headers => {
                        'Authorization' => "Bearer $api_key",
                        'Content-Type'  => 'application/json',
                    },
                    content => $build_payload->($selected_model),
                }
            );
        } // { success => 0, status => 0, reason => $@ };

        my $elapsed_ms = int((time() - $start) * 1000);

        return ($res, $elapsed_ms);
    };

    botNotice($self, $nick, "OpenAI test: model=$model fallback_model=" . ($fallback_model ne '' ? $fallback_model : '(disabled)') . " endpoint=$api_url");

    my $request_model = $model;
    my ($res, $elapsed_ms) = eval { $send_test->($request_model) };
    if ($@) { botNotice($self, $nick, "OpenAI test: network error: $@"); return; }
    my $fallback_tried = 0;

    # mb419-B3: keep the Owner diagnostic command aligned with chatGPT().
    # A transient/model-specific 429 may use the fallback model, while
    # insufficient_quota is account/project billing and must not spend a
    # second request.
    my ($primary_type, $primary_code) = $res->{success}
        ? ('', '')
        : Mediabot::External::Claude::_chatgpt_error_cause($res->{content});
    my $primary_quota = lc("$primary_type $primary_code") =~ /insufficient_quota/;
    my $primary_status = $res->{status} // 0;
    my $fallback_worthy =
        ($primary_status == 400 || $primary_status == 403 || $primary_status == 404)
        || ($primary_status == 429 && !$primary_quota);

    if (
        !$res->{success}
        && $fallback_model ne ''
        && $fallback_model ne $request_model
        && $fallback_worthy
    ) {
        botNotice(
            $self,
            $nick,
            "OpenAI test: primary model $request_model returned HTTP "
            . ($res->{status} // 0) . " "
            . ($res->{reason} // '')
            . "; trying fallback $fallback_model"
        );

        $request_model = $fallback_model;
        ($res, $elapsed_ms) = eval { $send_test->($request_model) };
        if ($@) { botNotice($self, $nick, "OpenAI test: network error on fallback: $@"); return; }
        $fallback_tried = 1;
    }

    my $status = $res->{status} // 0;
    my $reason = $res->{reason} // '';

    unless ($res->{success}) {
        my ($err_type, $err_code, $err_msg) =
            Mediabot::External::Claude::_chatgpt_error_cause($res->{content});
        my $diagnosis = Mediabot::External::Claude::_chatgpt_user_error_message(
            $status, $err_type, $err_code
        );

        botNotice($self, $nick, "OpenAI test: HTTP $status $reason in ${elapsed_ms}ms for model=$request_model");
        botNotice(
            $self,
            $nick,
            "OpenAI test: type=" . ($err_type || '(none)')
            . " code=" . ($err_code || '(none)')
        );
        botNotice($self, $nick, "OpenAI test: diagnosis=$diagnosis");

        if ($err_msg ne '') {
            $err_msg = substr($err_msg, 0, 320);
            botNotice($self, $nick, "OpenAI test: provider_message=$err_msg");
        }

        return;
    }

    my $data = eval { decode_json($res->{content} // '') };

    unless (
        !$@
        && ref($data) eq 'HASH'
        && ref($data->{choices}) eq 'ARRAY'
        && ref($data->{choices}[0]) eq 'HASH'
        && ref($data->{choices}[0]{message}) eq 'HASH'
        && defined($data->{choices}[0]{message}{content})
    ) {
        botNotice($self, $nick, "OpenAI test: HTTP $status $reason in ${elapsed_ms}ms for model=$request_model, but response shape was unexpected.");
        return;
    }

    my $answer = $data->{choices}[0]{message}{content};
    $answer =~ s/\s+/ /g;
    $answer = substr($answer, 0, 240);

    botNotice($self, $nick, "OpenAI test: HTTP $status $reason in ${elapsed_ms}ms for model=$request_model");
    botNotice($self, $nick, "OpenAI test: fallback used: " . ($fallback_tried ? 'yes' : 'no'));
    botNotice($self, $nick, "OpenAI test: answer=$answer");

    return 1;
}


sub _openai_profile_spec {
    return {
        dev => {
            label => 'development / richer IRC answers',
            values => {
                model        => 'gpt-4o-mini',
                temperature  => '0.6',
                max_tokens   => '700',
                max_privmsg  => '5',
                wrap_bytes   => '360',
                sleep_us     => '500000',
            },
        },
        compact => {
            label => 'shorter answers, lower IRC noise',
            values => {
                model        => 'gpt-4o-mini',
                temperature  => '0.4',
                max_tokens   => '350',
                max_privmsg  => '3',
                wrap_bytes   => '340',
                sleep_us     => '600000',
            },
        },
        safe => {
            label => 'very conservative public-channel profile',
            values => {
                model        => 'gpt-4o-mini',
                temperature  => '0.3',
                max_tokens   => '300',
                max_privmsg  => '3',
                wrap_bytes   => '330',
                sleep_us     => '750000',
            },
        },
        default => {
            label => 'built-in defaults',
            values => {
                model        => _openai_param_spec()->{model}{default},
                temperature  => _openai_param_spec()->{temperature}{default},
                max_tokens   => _openai_param_spec()->{max_tokens}{default},
                max_privmsg  => _openai_param_spec()->{max_privmsg}{default},
                wrap_bytes   => _openai_param_spec()->{wrap_bytes}{default},
                sleep_us     => _openai_param_spec()->{sleep_us}{default},
            },
        },
    };
}

sub _openai_notice_profiles {
    my ($self, $nick) = @_;

    my $profiles = _openai_profile_spec();

    for my $name (qw(dev compact safe default)) {
        my $profile = $profiles->{$name};

        botNotice($self, $nick, "OpenAI profile $name: $profile->{label}");
    }

    botNotice($self, $nick, "Usage: openai profile <dev|compact|safe|default>");
}

sub _openai_apply_profile {
    my ($self, $nick, $profile_name) = @_;

    $profile_name = lc($profile_name // '');

    my $profiles = _openai_profile_spec();
    my $profile  = $profiles->{$profile_name};

    unless ($profile) {
        botNotice($self, $nick, "Syntax: openai profile <dev|compact|safe|default>");
        _openai_notice_profiles($self, $nick);
        return;
    }

    my $param_spec = _openai_param_spec();

    for my $name (qw(model temperature max_tokens max_privmsg wrap_bytes sleep_us)) {
        my $value = $profile->{values}{$name};
        my $spec  = $param_spec->{$name};

        next unless $spec;

        my ($ok, $clean_or_error) = _openai_validate_value($name, $value);

        unless ($ok) {
            botNotice($self, $nick, "OpenAI profile $profile_name failed on $name: $clean_or_error");
            return;
        }

        $self->{conf}->set($spec->{key}, $clean_or_error);
    }

    $self->{conf}->save();

    botNotice($self, $nick, "OpenAI profile '$profile_name' applied: $profile->{label}");
    botNotice($self, $nick, "OpenAI/tellme: profile values are used immediately for future requests.");

    return 1;
}

sub _openai_models_url {
    my ($self) = @_;

    my $api_url = _openai_effective_value($self, 'api_url');
    $api_url = 'https://api.openai.com/v1/chat/completions'
        unless defined($api_url) && $api_url =~ m{^https://}i;

    $api_url =~ s{/chat/completions\z}{/models};
    $api_url =~ s{/responses\z}{/models};

    return $api_url if $api_url =~ m{/models\z};

    $api_url =~ s{/*\z}{};
    $api_url =~ s{/v1(?:/.*)?\z}{/v1};

    return "$api_url/models";
}

sub _openai_notice_models {
    my ($self, $nick, @filter_args) = @_;

    my $api_key = $self->{conf}->get('openai.API_KEY');

    unless (defined($api_key) && $api_key ne '') {
        botNotice($self, $nick, "OpenAI models: API key is missing.");
        return;
    }

    my $filter = lc(join(' ', @filter_args));
    $filter =~ s/^\s+|\s+\z//g;

    my $models_url = _openai_models_url($self);

    botNotice(
        $self,
        $nick,
        "OpenAI models: querying $models_url"
        . ($filter ne '' ? " filter='$filter'" : '')
    );

    my $_openai_timeout = _openai_effective_value($self, 'timeout');
    $_openai_timeout = 20 unless defined($_openai_timeout) && $_openai_timeout =~ /^\d+\z/;
    $_openai_timeout = 5  if $_openai_timeout < 5;
    $_openai_timeout = 60 if $_openai_timeout > 60;
    my $http = Mediabot::External::_make_http(
        timeout    => $_openai_timeout,
        verify_SSL => 1,
    );
    my $res  = eval {
        $http->get(
            $models_url,
            {
                headers => {
                    'Authorization' => "Bearer $api_key",
                },
            }
        );
    } // { success => 0, status => 0, reason => $@ };

    my $status = $res->{status} // 0;
    my $reason = $res->{reason} // '';

    unless ($res->{success}) {
        my ($err_type, $err_code, $err_msg) =
            Mediabot::External::Claude::_chatgpt_error_cause($res->{content});
        my $diagnosis = Mediabot::External::Claude::_chatgpt_user_error_message(
            $status, $err_type, $err_code
        );

        botNotice($self, $nick, "OpenAI models: HTTP $status $reason");
        botNotice(
            $self,
            $nick,
            "OpenAI models: type=" . ($err_type || '(none)')
            . " code=" . ($err_code || '(none)')
        );
        botNotice($self, $nick, "OpenAI models: diagnosis=$diagnosis");
        botNotice($self, $nick, "OpenAI models: provider_message=$err_msg")
            if $err_msg ne '';

        return;
    }

    my $data = eval { decode_json($res->{content} // '') };

    unless (!$@ && ref($data) eq 'HASH' && ref($data->{data}) eq 'ARRAY') {
        botNotice($self, $nick, "OpenAI models: unexpected response shape.");
        return;
    }

    my @ids;
    for my $item (@{ $data->{data} }) {
        next unless ref($item) eq 'HASH';
        next unless defined($item->{id}) && $item->{id} ne '';

        my $id = $item->{id};
        next if $filter ne '' && lc($id) !~ /\Q$filter\E/;

        push @ids, $id;
    }

    @ids = sort @ids;

    unless (@ids) {
        botNotice($self, $nick, "OpenAI models: no model matched" . ($filter ne '' ? " '$filter'" : ''));
        return;
    }

    my $total = scalar @ids;
    my $limit = 12;
    my @shown = @ids > $limit ? @ids[0 .. $limit - 1] : @ids;

    botNotice($self, $nick, "OpenAI models: " . join(', ', @shown));

    if ($total > $limit) {
        botNotice($self, $nick, "OpenAI models: showing $limit of $total matches; narrow with: openai models <filter>");
    }

    return 1;
}

sub openai_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Owner');

    my $subcmd = lc(shift(@args) // 'status');

    if ($subcmd eq 'status' || $subcmd eq 'config') {
        _openai_notice_status($self, $nick, $channel);
        botNotice($self, $nick, "OpenAI/tellme: use 'openai help' for set/reset commands.");
        return 1;
    }

    if ($subcmd eq 'help') {
        _openai_notice_help($self, $nick);
        return 1;
    }

    if ($subcmd eq 'defaults') {
        _openai_notice_defaults($self, $nick);
        return 1;
    }

    if ($subcmd eq 'test' || $subcmd eq 'ping' || $subcmd eq 'diagnose') {
        _openai_run_test($self, $nick, @args);
        return 1;
    }

    if ($subcmd eq 'models' || $subcmd eq 'model_list') {
        _openai_notice_models($self, $nick, @args);
        return 1;
    }

    if ($subcmd eq 'profiles') {
        _openai_notice_profiles($self, $nick);
        return 1;
    }

    if ($subcmd eq 'profile' || $subcmd eq 'preset') {
        _openai_apply_profile($self, $nick, $args[0] // '');
        return 1;
    }

    if ($subcmd eq 'explain') {
        my $name = _openai_param_alias($args[0] // '');

        unless ($name) {
            botNotice($self, $nick, "Syntax: openai explain <parameter>");
            return;
        }

        my $spec = _openai_param_spec()->{$name};

        botNotice($self, $nick, "OpenAI $name: $spec->{help}");
        botNotice($self, $nick, "OpenAI $name: config key=$spec->{key} default=$spec->{default}");

        if (defined($spec->{min}) || defined($spec->{max})) {
            botNotice($self, $nick, "OpenAI $name: range=$spec->{min}..$spec->{max}");
        }

        return 1;
    }

    if ($subcmd eq 'set') {
        my $raw_name = shift(@args) // '';
        my $name     = _openai_param_alias($raw_name);

        unless ($name) {
            botNotice($self, $nick, "Syntax: openai set <parameter> <value>");
            botNotice($self, $nick, "Valid parameters: model fallback_model system_prompt temperature max_tokens max_privmsg wrap_bytes sleep_us timeout api_url");
            return;
        }

        my $value = join(' ', @args);

        my ($ok, $clean_or_error) = _openai_validate_value($name, $value);
        unless ($ok) {
            botNotice($self, $nick, "OpenAI $name not changed: $clean_or_error");
            return;
        }

        my $spec = _openai_param_spec()->{$name};

        $self->{conf}->set($spec->{key}, $clean_or_error);
        $self->{conf}->save();

        botNotice($self, $nick, "OpenAI $name set to $clean_or_error");
        botNotice($self, $nick, "OpenAI/tellme: new value is used immediately for future requests.");

        return 1;
    }

    if ($subcmd eq 'reset') {
        my $name = _openai_param_alias($args[0] // '');

        unless ($name) {
            botNotice($self, $nick, "Syntax: openai reset <parameter>");
            botNotice($self, $nick, "Valid parameters: model fallback_model system_prompt temperature max_tokens max_privmsg wrap_bytes sleep_us timeout api_url");
            return;
        }

        my $spec = _openai_param_spec()->{$name};

        $self->{conf}->set($spec->{key}, $spec->{default});
        $self->{conf}->save();

        botNotice($self, $nick, "OpenAI $name reset to default $spec->{default}");

        return 1;
    }

    _openai_notice_help($self, $nick);
    return;
}


sub debug_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;   # may be undef for private
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $irc_nick = $self->{irc}->nick_folded;
    my $conf     = $self->{conf};  # Mediabot::Conf object

    # --- Auth / ACL ---
    my $user = $ctx->user;
    unless ($user) {
        botNotice($self, $nick, "User not found.");
        return;
    }

    unless ($user->is_authenticated) {
        noticeConsoleChan($self, (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick)
            . " debug attempt (unauthenticated " . ($user->nickname // '?') . ")");
        botNotice($self, $nick, "You must be logged to use this command - /msg $irc_nick login username password");
        return;
    }

    unless (eval { $user->has_level('Owner') }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        noticeConsoleChan($self, (($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick)
            . " debug attempt (Owner required for " . ($user->nickname // '?') . " [$lvl])");
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # --- Show current debug level if no argument is given ---
    my $level = $args[0];
    unless (defined $level && $level ne '') {
        my $current = $conf->get("main.MAIN_PROG_DEBUG");
        $current = 0 unless defined $current && $current =~ /^\d+$/;
        botNotice($self, $nick, "Current debug level is $current (0-5)");
        return 1;
    }

    $level =~ s/^\s+|\s+$//g;

    # --- Validate new debug level (0..5) ---
    unless ($level =~ /^[0-5]$/) {
        botNotice($self, $nick, "Syntax: debug <debug_level>");
        botNotice($self, $nick, "debug_level must be between 0 and 5");
        return;
    }

    # --- Persist config + update runtime logger immediately ---
    $conf->set("main.MAIN_PROG_DEBUG", $level);
    $conf->save();

    # Keep backward compatibility with existing logger structure
    $self->{logger}->{debug_level} = $level;

    $self->{logger}->log(1, "Debug set to $level");
    botNotice($self, $nick, "Debug level set to $level");

    logBot($self, $ctx->message, $channel, "debug", "Debug set to $level");
    return 1;
}

# Restart bot
sub mbRestart {
	my ($self, $message, $sNick, @tArgs) = @_;
	my $conf = $self->{conf};

	my $user = $self->get_user_from_message($message);
    return unless $user;

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " restart command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Owner")) {
        my $msg = $message->prefix . " restart command attempt (level [Owner] required for " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $full_params = $tArgs[0] // '';

    my @restart_args = grep {
        defined($_) && $_ ne '' && $_ !~ /^--server=/
    } split(/\s+/, $full_params);

    # Always pass --daemon (required by mb_restart.sh) and --conf
    unshift @restart_args, '--daemon'
        unless grep { $_ eq '--daemon' } @restart_args;
    if (defined $self->{config_file} && $self->{config_file} ne '') {
        push @restart_args, '--conf=' . $self->{config_file}
            unless grep { /^--conf=/ } @restart_args;
    }

    $self->{logger}->log(
        4,
        "Restart requested with args: " . join(' ', @restart_args)
    );

    my $child_pid;
    if (defined($child_pid = fork())) {
        if ($child_pid == 0) {
            my $bot_dir     = dirname(dirname(__FILE__));
            my $restart_bin = "$bot_dir/mb_restart.sh";

            $self->{logger}->log(1, "Restart request from " . $user->nickname . " using $restart_bin");
            setsid;
            exec $restart_bin, @restart_args;
            exit 1;
        } else {
            botNotice($self, $sNick, "Restarting");
            $self->{metrics}->inc('mediabot_restart_total') if $self->{metrics};
            logBot($self, $message, undef, "restart", "");
            $self->{Quit} = 1;
            $self->{irc}->send_message("QUIT", undef, "Be right back");
        }
    } else {
        $self->{logger}->log(1, "Failed to fork for restart");
        botNotice($self, $sNick, "Restart failed: unable to fork.");
    }

    return;
}

# Jump to another server (/jump <server>)
sub mbJump {
    my ($self, $message, $sNick, @tArgs) = @_;
    my $conf = $self->{conf};

    my $user = $self->get_user_from_message($message);
    return unless $user;

    unless ($user->is_authenticated) {
        my $msg = $message->prefix . " jump command attempt (user " . $user->nickname . " is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "You must be logged to use this command - /msg " . $self->{irc}->nick_folded . " login username password");
        return;
    }

    unless (checkUserLevel($self, $user->level, "Owner")) {
        my $msg = $message->prefix . " jump command attempt (level [Owner] required for " . $user->nickname . " [" . $user->level . "])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $sNick, "Your level does not allow you to use this command.");
        return;
    }

    my $full_params = $tArgs[0] // '';
    my $server      = $tArgs[1] // '';

    unless (defined($server) && $server ne '') {
        botNotice($self, $sNick, "Syntax: jump <server>");
        return;
    }

    my @restart_args = grep {
        defined($_) && $_ ne '' && $_ !~ /^--server=/
    } split(/\s+/, $full_params);

    # Always pass --daemon (required by mb_restart.sh) and --conf
    unshift @restart_args, '--daemon'
        unless grep { $_ eq '--daemon' } @restart_args;
    if (defined $self->{config_file} && $self->{config_file} ne '') {
        push @restart_args, '--conf=' . $self->{config_file}
            unless grep { /^--conf=/ } @restart_args;
    }

    $self->{logger}->log(
        4,
        "Jump requested to $server with restart args: " . join(' ', @restart_args)
    );

    my $child_pid;
    if (defined($child_pid = fork())) {
        if ($child_pid == 0) {
            my $bot_dir     = dirname(dirname(__FILE__));
            my $restart_bin = "$bot_dir/mb_restart.sh";

            $self->{logger}->log(1, "Jump request from " . $user->nickname . " to $server using $restart_bin");
            setsid;
            exec $restart_bin, @restart_args, "--server=$server";
            exit 1;
        } else {
            botNotice($self, $sNick, "Jumping to $server");
            $self->{metrics}->inc('mediabot_jump_total') if $self->{metrics};
            logBot($self, $message, undef, "jump", $server);
            $self->{Quit} = 1;
            $self->{irc}->send_message("QUIT", undef, "Changing server");
        }
    } else {
        $self->{logger}->log(1, "Failed to fork for jump");
        botNotice($self, $sNick, "Jump failed: unable to fork.");
    }

    return;
}

# Make a colored string with a high-contrast palette (dark+light bg friendly)


# Display the last N entries from ACTIONS_LOG table
# Syntax:
#   lastcom [<count>]
# Notes:
#   - count defaults to 5, max is 8
#   - Master+ only
#   - Always private reply (NOTICE)
sub mbRehash_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $user  = $ctx->user;
    my $unick = eval { $user->nickname } // $nick;

    my $ok = $self->rehash_runtime_state();

    # A6: re-attach the logger to Conf so warn() redirects correctly after reload
    if ($ok && $self->{conf} && $self->{logger} && $self->{conf}->can('set_logger')) {
        $self->{conf}->set_logger($self->{logger});
    }

    if ($ok) {
        if (defined $channel && $channel ne '') {
            botPrivmsg($self, $channel, "($nick) Successfully rehashed");
        } else {
            botNotice($self, $nick, "Successfully rehashed");
        }
        logBot($self, $message, $channel, "rehash", @args);
        return 1;
    } else {
        if (defined $channel && $channel ne '') {
            botPrivmsg($self, $channel, "($nick) Rehash failed - check logs");
        } else {
            botNotice($self, $nick, "Rehash failed - check logs");
        }
        return;
    }
}

# Generic authenticated exec command.
# Historical playRadio/rplayRadio comments were removed from here because
# Liquidsoap queue control now lives in the radioQueue/radioPush/radioSkip
# context handlers below.


sub mbExec_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # Where to send output:
    # - In channel if command was issued in a channel
    # - By notice if command was issued in private
    my $is_private = !defined($channel) || $channel eq '';
    my $send = $is_private
        ? sub { my ($msg) = @_; botNotice($self, $nick, $msg) }
        : sub { my ($msg) = @_; botPrivmsg($self, $channel, $msg) };

    # Retrieve user object (from context if available)
    my $user = $ctx->user // eval { $self->get_user_from_message($message) };

    # Authentication check
    unless ($user && $user->is_authenticated) {
        my $who = eval { $user->nickname } // $nick // "unknown";
        my $pfx = eval { $message->prefix } // $who;
        my $msg = "$pfx exec command attempt (user $who is not logged in)";
        noticeConsoleChan($self, $msg);
        botNotice(
            $self,
            $nick,
            "You must be logged in to use this command - /msg "
              . $self->{irc}->nick_folded
              . " login username password"
        );
        return;
    }

    # Privilege check: Owner only
    unless (eval { $user->has_level("Owner") }) {
        my $lvl = eval { $user->level } // 'undef';
        my $who = eval { $user->nickname } // $nick;
        my $pfx = eval { $message->prefix } // $who;

        my $msg = "$pfx exec command attempt (command level [Owner] for user $who [$lvl])";
        noticeConsoleChan($self, $msg);
        botNotice($self, $nick, "Your level does not allow you to use this command.");
        return;
    }

    # Build command string
    my $command = join(" ", @args);
    $command =~ s/^\s+|\s+$//g if defined $command;

    unless (defined($command) && $command ne "") {
        botNotice($self, $nick, "Syntax: exec <command>");
        return;
    }

    # B1/A1: limit command length to prevent abuse
    if (length($command) > 512) {
        botNotice($self, $nick, "Command too long (max 512 chars).");
        return;
    }

    # Very basic safety guard for obviously destructive commands
    # B1/A1: expanded safety blacklist — Owner-only but defence-in-depth
    if (
        $command =~ /\brm\s+-rf\b/i                        # rm -rf
        || $command =~ /\brm\s+-r\s+\//i                  # rm -r /
        || $command =~ /:()\s*{\s*:|:&};:/                  # bash fork bomb
        || $command =~ /\bshutdown\b|\breboot\b/i
        || $command =~ /\bmkfs\b/i
        || $command =~ /\bdd\s+if=/i
        || $command =~ />\s*\/dev\/sd/i
        || $command =~ /(?:curl|wget)\b.*\|\s*(?:bash|sh)\b/i  # download+exec
        || $command =~ />\s*\/etc\/(?:passwd|shadow|sudoers)/i  # clobber system files
    ) {
        botNotice($self, $nick, "Don't be that evil!");
        return;
    }

    # Log the attempt in console (owner-only, so it is fine to log full command)
    my $pfx = eval { $message->prefix } // $nick;
    noticeConsoleChan($self, "$pfx exec: $command");

    # Execute command with a hard timeout and sanitized output.
    #
    # This remains an Owner-only shell command, but the bot must not hang forever
    # if the command blocks. Output is still limited to 3 lines, with IRC-hostile
    # control characters stripped and long lines shortened.
    my $exec_timeout = eval { $self->{conf}->get('main.EXEC_TIMEOUT_SECONDS') } || 8;
    $exec_timeout = 8 unless defined($exec_timeout) && $exec_timeout =~ /^\d+$/;
    $exec_timeout = 1  if $exec_timeout < 1;
    $exec_timeout = 30 if $exec_timeout > 30;

    my $timeout_bin = '/usr/bin/timeout';

    unless (-x $timeout_bin) {
        $self->{logger}->log(1, "mbExec_ctx: refusing to run exec without $timeout_bin");
        $send->("Execution unavailable: $timeout_bin not found.");
        return;
    }

    my $shell = "$command 2>&1 | tail -n 3";
    my @runner = ($timeout_bin, '--kill-after=2s', "${exec_timeout}s", 'sh', '-c', $shell);

    open my $cmd_fh, "-|", @runner or do {
        $self->{logger}->log(3, "mbExec_ctx: Failed to execute: $command");
        $send->("Execution failed.");
        return;
    };

    my $i          = 0;
    my $has_output = 0;

    while (my $line = <$cmd_fh>) {
        chomp $line;
        $line =~ s/\r//g;

        # Strip ASCII control characters except horizontal tab.
        $line =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g;

        if (length($line) > 350) {
            $line = substr($line, 0, 347) . '...';
        }

        $send->("$i: $line");
        $has_output = 1;

        if (++$i >= 3) {
            # B1/A1: /usr/bin/timeout handles child lifetime;
            # just break — close() will return quickly once the pipe is drained
            last;
        }
    }

    close $cmd_fh;
    my $exit_status = $? >> 8;

    if (-x $timeout_bin && ($exit_status == 124 || $exit_status == 137)) {
        $send->("Command timed out after ${exec_timeout}s.");
        $self->{logger}->log(2, "mbExec_ctx: command timed out after ${exec_timeout}s: $command");
    }
    elsif (!$has_output) {
        $send->("No output.");
    }

    # Log to ACTIONS_LOG as usual
    logBot($self, $message, ($channel // "(private)"), "exec", $command);

    return 1;
}

# mb382-B2: pack optional Scheduler details into a bounded number of NOTICE
# lines.  The default status path never emits one line per task.
sub _status_scheduler_detail_lines {
    my ($tasks_ref, %opts) = @_;

    my @tasks = ref($tasks_ref) eq 'ARRAY' ? @$tasks_ref : ();
    return () unless @tasks;

    my $now       = defined($opts{now})       ? $opts{now}       : time();
    my $max_lines = defined($opts{max_lines}) ? $opts{max_lines} : 3;
    my $max_chars = defined($opts{max_chars}) ? $opts{max_chars} : 350;

    $max_lines = 1 if $max_lines < 1;
    $max_chars = 80 if $max_chars < 80;

    my @entries;
    for my $task (sort { ($a->{name} // '') cmp ($b->{name} // '') } @tasks) {
        next unless ref($task) eq 'HASH';

        my $name     = $task->{name} // 'unnamed';
        my $interval = $task->{interval} // 0;
        my $ticks    = $task->{ticks} // 0;
        my $state    = $task->{started} ? 'run' : 'stop';
        my $last     = $task->{last_tick}
            ? sprintf('%ds', $now - $task->{last_tick})
            : 'never';

        push @entries, sprintf('%s=%s/%ss/t%s/last:%s',
            $name, $state, $interval, $ticks, $last);
    }

    return () unless @entries;

    my @lines;
    my $prefix  = 'Scheduler tasks: ';
    my $current = $prefix;
    my $used    = 0;

    ENTRY:
    for my $entry (@entries) {
        my $candidate = $current eq $prefix
            ? $prefix . $entry
            : $current . ' | ' . $entry;

        if (length($candidate) <= $max_chars) {
            $current = $candidate;
            $used++;
            next ENTRY;
        }

        if ($current ne $prefix) {
            push @lines, $current;
            last ENTRY if @lines >= $max_lines;
        }

        $current = $prefix . $entry;
        $used++;
    }

    push @lines, $current
        if @lines < $max_lines && $current ne $prefix
            && (!@lines || $lines[-1] ne $current);

    if ($used < @entries && @lines) {
        my $more = scalar(@entries) - $used;
        my $tail = " | +$more more";

        if (length($lines[-1] . $tail) <= $max_chars) {
            $lines[-1] .= $tail;
        }
        else {
            $lines[-1] = substr($lines[-1], 0, $max_chars - length($tail)) . $tail;
        }
    }

    return @lines;
}

# Get the harbor ID from LIQUIDSOAP telnet server
sub mbStatus_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Master only
    return unless $ctx->require_level('Master');

    # --- Bot Uptime ---
    my $uptime = time - getProcessStartTimestamp($self);
    $uptime = 0 if $uptime < 0;
    my $days    = int($uptime / 86400);
    my $hours   = sprintf('%02d', int(($uptime % 86400) / 3600));
    my $minutes = sprintf('%02d', int(($uptime % 3600) / 60));
    my $seconds = sprintf('%02d', $uptime % 60);

    my $uptime_str = '';
    $uptime_str .= "$days days, "  if $days > 0;
    $uptime_str .= "${hours}h "    if $hours > 0;
    $uptime_str .= "${minutes}mn " if $minutes > 0;
    $uptime_str .= "${seconds}s";
    $uptime_str ||= 'Unknown';

    # --- Server uptime ---
    my $server_uptime = 'Unavailable';
    if (open my $fh_uptime, '<', '/proc/uptime') {
        if (defined(my $line = <$fh_uptime>)) {
            my ($uptime_seconds) = split /\s+/, $line;
            if (defined $uptime_seconds && $uptime_seconds =~ /^\d+(?:\.\d+)?$/) {
                my $sys_uptime = int($uptime_seconds);
                my $sys_days   = int($sys_uptime / 86400);
                my $sys_hours  = int(($sys_uptime % 86400) / 3600);
                my $sys_mins   = int(($sys_uptime % 3600) / 60);

                $server_uptime = sprintf(
                    'up %d days, %02d:%02d',
                    $sys_days,
                    $sys_hours,
                    $sys_mins,
                );
            }
        }
        close $fh_uptime;
    } else {
        $self->{logger}->log(1, "Could not read /proc/uptime");
    }

    # --- OS Info ---
    my $uname = 'Unknown';
    my @uname_parts = eval { POSIX::uname() };

    if (@uname_parts >= 5) {
        my ($sysname, undef, $release, $version, $machine) = @uname_parts;
        my $host = eval { hostname() } || 'unknown-host';

        $uname = join ' ', grep { defined $_ && $_ ne '' } (
            $sysname,
            $host,
            $release,
            $version,
            $machine,
        );
    } else {
        $self->{logger}->log(1, "POSIX::uname failed while building status output");
    }

    # --- Memory usage via /proc/self/status (reliable on Debian/Linux, no CPAN dep) ---
    my ($vm, $rss, $shared, $data) = ('?', '?', '?', '?');
    eval {
        open my $fh_mem, '<', '/proc/self/status' or die "cannot open /proc/self/status: $!";
        while (my $line = <$fh_mem>) {
            $rss    = sprintf('%.2f', $1 / 1024) if $line =~ /^VmRSS:\s+(\d+)\s+kB/i;
            $vm     = sprintf('%.2f', $1 / 1024) if $line =~ /^VmSize:\s+(\d+)\s+kB/i;
            $data   = sprintf('%.2f', $1 / 1024) if $line =~ /^VmData:\s+(\d+)\s+kB/i;
            $shared = sprintf('%.2f', $1 / 1024) if $line =~ /^VmLib:\s+(\d+)\s+kB/i;
        }
        close $fh_mem;
        1;
    } or do {
        $self->{logger}->log(1, "Memory stats via /proc/self/status failed: $@");
    };

    # mb382-B2: keep the normal status reply to a three-NOTICE budget.
    # One NOTICE per Scheduler task caused immediate Excess Flood disconnects.
    my $args = $ctx->args;
    my $status_mode = lc($args->[0] // '');
    my $show_scheduler_details =
        $status_mode eq 'full'
        || $status_mode eq 'scheduler'
        || $status_mode eq 'tasks';

    my $prog_name = $self->{conf}->get('main.MAIN_PROG_NAME') // 'Mediabot';
    my $runtime_version = $self->{main_prog_version};
    $runtime_version = 'unknown'
        unless defined($runtime_version)
            && !ref($runtime_version)
            && $runtime_version ne ''
            && lc($runtime_version) ne 'undefined';

    botNotice(
        $self,
        $nick,
        "$prog_name v$runtime_version | bot up $uptime_str"
          . " | RAM RSS ${rss}MB, VM ${vm}MB"
    );
    botNotice(
        $self,
        $nick,
        "Server: $uname | uptime $server_uptime"
    );

    # mb93-IMP2 / mb382-B2: compact Scheduler summary by default.  Explicit
    # "status full", "status scheduler" or "status tasks" remains bounded to
    # three additional detail lines.
    if ($self->{scheduler} && $self->{scheduler}->can('all_info')) {
        my @tasks = grep { ref($_) eq 'HASH' } $self->{scheduler}->all_info;

        if (@tasks) {
            my @running = grep { $_->{started} } @tasks;
            my @stopped = grep { !$_->{started} } @tasks;

            my $summary = sprintf(
                "Scheduler: %d total | %d running | %d stopped",
                scalar(@tasks),
                scalar(@running),
                scalar(@stopped),
            );

            if (@stopped) {
                my $stopped_names = join(',', map { $_->{name} // 'unnamed' } @stopped);
                $summary .= " | stopped: $stopped_names";
            }
            elsif (!$show_scheduler_details) {
                $summary .= " | details: status full";
            }

            botNotice($self, $nick, $summary);

            if ($show_scheduler_details) {
                my @detail_lines = _status_scheduler_detail_lines(
                    \@tasks,
                    now       => time(),
                    max_lines => 3,
                    max_chars => 350,
                );
                botNotice($self, $nick, $_) for @detail_lines;
            }
        }
        else {
            botNotice($self, $nick, "Scheduler: no tasks registered.");
        }
    }
    else {
        botNotice($self, $nick, "Scheduler: unavailable.");
    }

    logBot($self, $ctx->message, undef, 'status', undef);
}

sub radioStatus_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $conf = $self->{conf};

    return unless $ctx->require_level('Master');

    my ($radio, $radio_cfg) = _radio_icecast_client($self);
    my $public_base   = $radio_cfg->{public_base};
    my $primary_mount = $radio_cfg->{primary_mount};

    my $info = $radio->get_summary(
        primary_mount => $primary_mount,
        public_base   => $public_base,
    );

    unless ($info->{ok}) {
        botNotice($self, $nick, "Radio status error: " . ($info->{error} || 'unknown error'));
        logBot($self, $ctx->message, undef, 'radiostatus', 'error');
        return;
    }

    my $host            = $info->{host}            || '?';
    my $server_id       = $info->{server_id}       || '?';
    my $sources         = defined $info->{sources}         ? $info->{sources}         : '?';
    my $total_listeners = defined $info->{total_listeners} ? $info->{total_listeners} : '?';
    my $mount           = $info->{primary_mount}   || '?';
    my $bitrate         = defined $info->{bitrate}         ? $info->{bitrate}         : '?';
    my $mount_listeners = defined $info->{mount_listeners} ? $info->{mount_listeners} : 0;
    my $title           = defined $info->{title} && $info->{title} ne '' ? $info->{title} : 'unknown';
    my $listen_url      = $info->{listen_url}      || '?';

    # GG7: compact format — 2 notices instead of 4
    botNotice($self, $nick,
        "Icecast $host | $mount | ${bitrate}k | $mount_listeners listener(s) | $title");
    botNotice($self, $nick, "Listen: $listen_url");

    logBot($self, $ctx->message, undef, 'radiostatus', undef);
}

sub radioMounts_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my $conf = $self->{conf};

    return unless $ctx->require_level('Master');

    my ($radio) = _radio_icecast_client($self);

    my $mounts = $radio->get_mounts();
    unless ($mounts->{ok}) {
        botNotice($self, $nick, "Radio mounts error: " . ($mounts->{error} || 'unknown error'));
        logBot($self, $ctx->message, undef, 'radiomounts', 'error');
        return;
    }

    my $list = $mounts->{mounts} || [];
    if (!@$list) {
        botNotice($self, $nick, "No Icecast mounts found.");
        logBot($self, $ctx->message, undef, 'radiomounts', undef);
        return;
    }

    for my $m (@$list) {
        my $mount       = $m->{mount}       || '?';
        my $bitrate     = defined $m->{bitrate}   ? $m->{bitrate}   : '?';
        my $listeners   = defined $m->{listeners} ? $m->{listeners} : '?';
        my $title       = defined $m->{title} && $m->{title} ne '' ? $m->{title} : 'n/a';
        my $description = defined $m->{description} && $m->{description} ne '' ? $m->{description} : 'n/a';
        my $listenurl   = defined $m->{listenurl} && $m->{listenurl} ne '' ? $m->{listenurl} : 'n/a';

        # BB6: compact format, drop redundant desc, keep listenurl
        botNotice($self, $nick,
            sprintf("%s | %sk | %s listener%s | %s",
                $mount, $bitrate,
                $listeners, ($listeners eq '1' ? '' : 's'),
                ($title ne 'no title' ? $title : $listenurl)));
    }

    logBot($self, $ctx->message, undef, 'radiomounts', undef);
}


sub displayRadioListeners_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $conf = $self->{conf};

    my ($radio, $radio_cfg) = _radio_icecast_client($self);
    my $public_base   = $radio_cfg->{public_base};
    my $primary_mount = $radio_cfg->{primary_mount};

    my $info = $radio->get_summary(
        primary_mount => $primary_mount,
        public_base   => $public_base,
    );

    unless ($info->{ok}) {
        my $msg = "Radio listeners error: " . ($info->{error} || 'unknown error');

        if ($ctx->is_private) {
            $ctx->reply_private($msg);
        } else {
            $ctx->reply($msg);
        }

        logBot($self, $ctx->message, undef, 'listeners', 'error');
        return;
    }

    my $total           = defined $info->{total_listeners} ? $info->{total_listeners} : '?';
    my $mount           = $info->{primary_mount} || $primary_mount;
    my $mount_listeners = defined $info->{mount_listeners} ? $info->{mount_listeners} : '?';

    my $msg = _radio_format_listeners_line(
        total           => $total,
        mount           => $mount,
        mount_listeners => $mount_listeners,
    );

    if ($ctx->is_private) {
        $ctx->reply_private($msg);
    } else {
        $ctx->reply($msg);
    }

    logBot($self, $ctx->message, undef, 'listeners', undef);
    return 1;
}

sub radioNext_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;

    my $msg = "nextsong is not wired to a radio scheduler yet; current song follows.";

    if ($ctx->is_private) {
        $ctx->reply_private($msg);
    } else {
        $ctx->reply($msg);
    }

    logBot($self, $ctx->message, undef, 'nextsong', 'not_implemented');
    return song_ctx($ctx);
}


sub _liquidsoap_config_value {
    my ($self, $short, $default) = @_;

    my $conf = $self->{conf};
    return $default unless $conf && $conf->can('get');

    my $v = $conf->get("radio.$short");
    $v = $conf->get($short) unless defined($v) && $v ne '';

    return defined($v) && $v ne '' ? $v : $default;
}

sub _liquidsoap_client {
    my ($self) = @_;

    my $host = _liquidsoap_config_value($self, 'LIQUIDSOAP_TELNET_HOST', '127.0.0.1');
    my $port = _liquidsoap_config_value($self, 'LIQUIDSOAP_TELNET_PORT', 1235);
    my $qid  = _liquidsoap_config_value($self, 'LIQUIDSOAP_QUEUE_ID',  'mediabot_queue');

    $port = 1235 unless defined($port) && $port =~ /^\d+$/ && $port > 0;

    return Mediabot::Liquidsoap->new(
        host     => $host,
        port     => int($port),
        queue_id => $qid,
        timeout  => 5,
        logger   => $self->{logger},
    );
}

sub _radio_notice_lines {
    my ($ctx, $prefix, $text, $max_lines) = @_;

    $max_lines ||= 8;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    $text = '' unless defined $text;
    $text =~ s/\r//g;

    my @raw_lines = grep { defined($_) && $_ ne '' } split(/\n/, $text);
    my @lines = grep { $_ !~ /^\s*(?:END|Bye!)\s*$/ } @raw_lines;

    unless (@lines) {
        botNotice($self, $nick, "$prefix: empty");
        return;
    }

    my $shown = 0;
    for my $line (@lines) {
        botNotice($self, $nick, "$prefix: $line");
        $shown++;
        last if $shown >= $max_lines;
    }

    my $remaining = @lines - $shown;
    botNotice($self, $nick, "$prefix: ... ($remaining more line(s))")
        if $remaining > 0;
}




sub radioImportDir_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $dir = join(' ', @args);
    $dir =~ s/^\s+|\s+$//g;

    my $user = $ctx->user;
    my $uid  = eval { $user->id } || 0;

    my $radio = Mediabot::Radio::Request->new(bot => $self);
    my ($ok, $res) = $radio->import_directory(
        dir     => $dir,
        id_user => $uid,
        limit   => 500,
    );

    unless ($ok) {
        botNotice($self, $nick, "Radio importdir failed: $res");
        logBot($self, $ctx->message, undef, 'radioimportdir', 'failed', $dir);
        return;
    }

    botNotice(
        $self,
        $nick,
        "radioimportdir OK: scanned=$res->{seen}, imported_or_updated=$res->{imported}, failed=$res->{failed}, dir=$res->{dir}"
    );

    botNotice($self, $nick, "Radio importdir: stopped at safety limit $res->{limit}") if $res->{truncated};

    if ($res->{examples} && @{ $res->{examples} }) {
        botNotice($self, $nick, "Radio importdir examples: " . join(' | ', @{ $res->{examples} }));
    }

    logBot($self, $ctx->message, undef, 'radioimportdir', $res->{dir});
    return 1;
}


sub radioImport_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    unless (@args) {
        botNotice($self, $nick, "Syntax: radioimport <absolute-mp3-path> [artist - title]");
        return;
    }

    my $path = shift @args;
    my $label = join(' ', @args);
    $label =~ s/^\s+|\s+$//g;

    unless ($path =~ m{^/}) {
        botNotice($self, $nick, "Radio import: expected an absolute local MP3 path.");
        return;
    }

    my ($artist, $title) = ('', '');
    if ($label ne '') {
        if ($label =~ /^(.+?)\s+-\s+(.+)$/) {
            ($artist, $title) = ($1, $2);
        }
        else {
            $title = $label;
        }
    }

    my $user = $ctx->user;
    my $uid  = eval { $user->id } || 0;

    my $radio = Mediabot::Radio::Request->new(bot => $self);
    my ($ok, $res) = $radio->import_local_file(
        path    => $path,
        artist  => $artist,
        title   => $title,
        id_user => $uid,
    );

    unless ($ok) {
        botNotice($self, $nick, "Radio import failed: $res");
        logBot($self, $ctx->message, undef, 'radioimport', 'failed', $path);
        return;
    }

    botNotice(
        $self,
        $nick,
        "radioimport OK: id=$res->{id_mp3} $res->{artist} - $res->{title}"
    );

    logBot($self, $ctx->message, undef, 'radioimport', $res->{path});
    return 1;
}


sub radioPlay_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # First implementation is intentionally Master-only to avoid turning
    # a dev radio stack into a public download endpoint by accident.
    return unless $ctx->require_level('Master');

    my $query = join(' ', @args);
    $query =~ s/^\s+|\s+$//g;

    unless ($query ne '') {
        botNotice($self, $nick, "Syntax: play <artist/title/search>");
        return;
    }

    my $user = $ctx->user;
    my $uid  = eval { $user->id } || 0;

    my $radio = Mediabot::Radio::Request->new(bot => $self);
    return $radio->play(
        ctx     => $ctx,
        query   => $query,
        id_user => $uid,
    );
}



sub _radio_cancel_try_reap {
    my ($pid) = @_;

    return ('invalid', undef)
        unless defined($pid) && $pid =~ /^\d+\z/ && $pid > 0;

    my $waited = waitpid($pid, WNOHANG);

    return ('running', undef) if $waited == 0;
    return ('reaped', $?)     if $waited == $pid;
    return ('gone', undef)    if $waited == -1;

    return ('unexpected', undef);
}

sub radioDlCancel_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $job = $self->{_radio_request_download};

    unless ($job && $job->{active}) {
        botNotice($self, $nick, "Radio download: nothing to cancel, no active yt-dlp job.");
        logBot($self, $ctx->message, undef, 'radiodlcancel', 'idle');
        return 1;
    }

    my $pid   = $job->{pid};
    my $query = $job->{query} // 'unknown request';

    unless ($pid && $pid =~ /^\d+$/) {
        $self->{_radio_request_download} = {};
        botNotice($self, $nick, "Radio download: cleared invalid internal job state.");
        logBot($self, $ctx->message, undef, 'radiodlcancel', 'cleared-invalid-state');
        return 1;
    }

    my $loop = $self->{loop};

    my $remove_timer = sub {
        my ($key) = @_;

        my $timer = delete $job->{$key};
        return unless $timer;

        eval { $timer->stop if $timer->can('stop') };
        eval { $loop->remove($timer) if $loop };
    };

    my $cleanup = sub {
        my ($reason) = @_;

        return if $job->{cancel_cleanup_done};
        $job->{cancel_cleanup_done} = 1;

        $remove_timer->('cancel_kill_timer');
        $remove_timer->('cancel_reap_timer');

        for my $tmp ($job->{stdout}, $job->{stderr}) {
            next unless defined($tmp) && $tmp ne '';
            unlink $tmp if -e $tmp;
        }

        my $current = $self->{_radio_request_download};
        if (ref($current) eq 'HASH' && $current == $job) {
            $self->{_radio_request_download} = {};
        }

        botNotice($self, $nick, "Radio download: cancelled job: $query");
        logBot(
            $self,
            $ctx->message,
            undef,
            'radiodlcancel',
            $reason || 'cancelled-reaped',
            $query,
        );
    };

    my $try_finish = sub {
        my ($state) = _radio_cancel_try_reap($pid);

        if ($state eq 'reaped' || $state eq 'gone') {
            $cleanup->("cancel-$state");
            return 1;
        }

        return 0;
    };

    # A repeated cancel command must not install a second set of timers.
    if ($job->{cancel_requested}) {
        return 1 if $try_finish->();

        my $phase = $job->{cancel_phase} // 'in-progress';
        botNotice(
            $self,
            $nick,
            "Radio download: cancellation already in progress "
                . "(pid=$pid, phase=$phase): $query"
        );
        logBot(
            $self,
            $ctx->message,
            undef,
            'radiodlcancel',
            'already-in-progress',
            $query,
        );
        return 1;
    }

    # Prevent the normal Radio::Request polling timer from racing the cancel
    # path. Temporary files and active job state are kept until waitpid confirms
    # that the child is reaped.
    $job->{cancel_requested} = 1;
    $job->{cancel_phase}     = 'term';

    if (my $poll_timer = delete $job->{timer}) {
        my $poll_loop = delete($job->{loop}) || $loop;
        eval { $poll_timer->stop if $poll_timer->can('stop') };
        eval { $poll_loop->remove($poll_timer) if $poll_loop };
    }

    return 1 if $try_finish->();

    kill 'TERM', $pid;
    botNotice($self, $nick, "Radio download: cancelling job: $query");

    unless ($loop) {
        # A running bot normally always has an IO::Async loop. In this emergency
        # fallback, escalate immediately and perform only a short bounded reap
        # attempt. If the process still cannot be reaped, keep the job state
        # instead of falsely reporting successful cancellation.
        kill 'KILL', $pid;
        $job->{cancel_phase} = 'kill';

        my $deadline = time() + 1;
        while (time() < $deadline) {
            return 1 if $try_finish->();
            select undef, undef, undef, 0.05;
        }

        botNotice(
            $self,
            $nick,
            "Radio download: kill sent, but child reaping is still pending "
                . "(pid=$pid): $query"
        );
        logBot(
            $self,
            $ctx->message,
            undef,
            'radiodlcancel',
            'kill-sent-reap-pending',
            $query,
        );
        return 1;
    }

    my $reap_timer;
    $reap_timer = IO::Async::Timer::Countdown->new(
        delay => 0.10,
        on_expire => sub {
            return if $job->{cancel_cleanup_done};
            return if $try_finish->();

            $reap_timer->start;
        },
    );

    my $kill_timer;
    $kill_timer = IO::Async::Timer::Countdown->new(
        delay => 1,
        on_expire => sub {
            return if $job->{cancel_cleanup_done};
            return if $try_finish->();

            kill 'KILL', $pid;
            $job->{cancel_phase} = 'kill';

            eval { $loop->remove($kill_timer) if $kill_timer };
            delete $job->{cancel_kill_timer};
        },
    );

    $job->{cancel_reap_timer} = $reap_timer;
    $job->{cancel_kill_timer} = $kill_timer;

    $loop->add($reap_timer);
    $loop->add($kill_timer);

    # MB336-B1: the job and IO::Async loop are the strong owners. The timer
    # callbacks must not keep their own timer alive through the captured
    # lexical after cancellation cleanup removes those owners. Weakening the
    # lexicals also covers timers removed before their callback ever fires.
    weaken($reap_timer);
    weaken($kill_timer);

    $reap_timer->start;
    $kill_timer->start;

    return 1;
}



sub radioDlStatus_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $job = $self->{_radio_request_download};

    unless ($job && $job->{active}) {
        botNotice($self, $nick, "Radio download: idle, no active yt-dlp job.");
        logBot($self, $ctx->message, undef, 'radiodlstatus', 'idle');
        return 1;
    }

    my $query   = $job->{query}   // 'unknown request';
    my $pid     = $job->{pid}     // '?';
    my $started = $job->{started} // time();
    my $age     = int(time() - $started);

    my $timeout = _liquidsoap_config_value($self, 'YTDLP_TIMEOUT', 180);
    $timeout = 180 unless defined($timeout) && $timeout =~ /^\d+$/ && $timeout >= 30;

    my $stdout = $job->{stdout} // '';
    my $stderr = $job->{stderr} // '';

    my $alive = 'unknown';
    if ($pid && $pid =~ /^\d+$/) {
        $alive = kill(0, $pid) ? 'yes' : 'no';
    }

    my $state = $job->{cancel_requested} ? 'cancelling' : 'active';
    my $phase = $job->{cancel_phase};

    botNotice($self, $nick, "Radio download: $state query='$query'");

    my $age_h = $age >= 60
        ? sprintf('%dm %ds', int($age/60), $age%60)
        : "${age}s";

    my $phase_text = defined($phase) && $phase ne ''
        ? " cancel_phase=$phase"
        : '';

    botNotice(
        $self,
        $nick,
        "Radio download: pid=$pid alive=$alive age=$age_h "
            . "timeout=${timeout}s$phase_text"
    );

    if ($stderr && -r $stderr) {
        my $size = -s $stderr || 0;
        botNotice($self, $nick, "Radio download: stderr=$stderr (${size} bytes)");
    }

    if ($stdout && -r $stdout) {
        my $size = -s $stdout || 0;
        botNotice($self, $nick, "Radio download: stdout=$stdout (${size} bytes)");
    }

    logBot(
        $self,
        $ctx->message,
        undef,
        'radiodlstatus',
        "$state pid=$pid age=$age query=$query"
    );
    return 1;
}


sub radioCachePrune_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $confirm = (@args && lc($args[0] // '') eq 'confirm') ? 1 : 0;

    my $dbh = $self->{dbh};
    unless ($dbh) {
        botNotice($self, $nick, "Radio cache prune: database handle unavailable.");
        return;
    }

    my $sth = $dbh->prepare(q{
        SELECT id_mp3, folder, filename, artist, title
        FROM MP3
        ORDER BY id_mp3
    });

    unless ($sth && $sth->execute()) {
        botNotice($self, $nick, "Radio cache prune: database query failed.");
        $sth->finish if $sth;
        return;
    }

    my @missing;
    while (my $r = $sth->fetchrow_hashref) {
        my $folder   = $r->{folder}   // '';
        my $filename = $r->{filename} // '';
        my $path = ($folder ne '' && $filename ne '') ? "$folder/$filename" : '';

        next if $path ne '' && -r $path;

        push @missing, {
            id_mp3 => $r->{id_mp3},
            label  => (($r->{artist} // 'Unknown') . " - " . ($r->{title} // $filename // '?')),
            path   => $path || '(empty path)',
        };
    }

    $sth->finish;

    unless (@missing) {
        botNotice($self, $nick, "Radio cache prune: no missing MP3 cache rows found.");
        logBot($self, $ctx->message, undef, 'radiocacheprune', 'none');
        return 1;
    }

    unless ($confirm) {
        my @examples = map { "#" . $_->{id_mp3} . " " . $_->{label} } @missing[0 .. (@missing < 3 ? $#missing : 2)];
        botNotice($self, $nick, "Radio cache prune dry-run: " . scalar(@missing) . " missing row(s).");
        botNotice($self, $nick, "Radio cache prune examples: " . join(' | ', @examples)) if @examples;
        botNotice($self, $nick, "Radio cache prune: dry-run only. To delete these DB rows: radiocacheprune confirm");
        logBot($self, $ctx->message, undef, 'radiocacheprune', 'dry-run', scalar(@missing));
        return 1;
    }

    my $del = $dbh->prepare("DELETE FROM MP3 WHERE id_mp3 = ?");
    unless ($del) {
        botNotice($self, $nick, "Radio cache prune: delete prepare failed.");
        return;
    }

    my $deleted = 0;
    for my $row (@missing) {
        unless ($del->execute($row->{id_mp3})) {
            $self->{logger}->log(1, "radiocacheprune delete failed for id_mp3=$row->{id_mp3}: $DBI::errstr")
                if $self->{logger};
            next;
        }
        $deleted += $del->rows || 0;
    }

    $del->finish;

    botNotice($self, $nick, "Radio cache prune: deleted $deleted missing MP3 row(s).");
    logBot($self, $ctx->message, undef, 'radiocacheprune', 'deleted', $deleted);
    return 1;
}


sub radioCache_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $incoming = _liquidsoap_config_value($self, 'YOUTUBEDL_INCOMING', '');
    my $dbh = $self->{dbh};

    unless ($dbh) {
        botNotice($self, $nick, "Radio cache: database handle unavailable.");
        return;
    }

    my ($db_total, $db_readable, $db_missing) = (0, 0, 0);
    my @missing_examples;

    my $sth = $dbh->prepare(q{
        SELECT id_mp3, folder, filename, artist, title
        FROM MP3
        ORDER BY id_mp3 DESC
    });

    unless ($sth && $sth->execute()) {
        botNotice($self, $nick, "Radio cache: database query failed.");
        $sth->finish if $sth;
        return;
    }

    while (my $r = $sth->fetchrow_hashref) {
        $db_total++;

        my $folder   = $r->{folder}   // '';
        my $filename = $r->{filename} // '';
        my $path = ($folder ne '' && $filename ne '') ? "$folder/$filename" : '';

        if ($path ne '' && -r $path) {
            $db_readable++;
        }
        else {
            $db_missing++;
            push @missing_examples, "#" . ($r->{id_mp3} // '?') . " " . (($r->{artist} // 'Unknown') . " - " . ($r->{title} // $filename // '?'))
                if @missing_examples < 3;
        }
    }

    $sth->finish;

    my $fs_mp3 = 0;
    my $fs_readable = 0;

    if (defined($incoming) && $incoming ne '' && -d $incoming) {
        require File::Find;
        File::Find::find(
            {
                wanted => sub {
                    return unless -f $_;
                    return unless $_ =~ /\.mp3\z/i;
                    $fs_mp3++;
                    $fs_readable++ if -r $_;
                },
                no_chdir => 1,
            },
            $incoming,
        );
    }

    botNotice($self, $nick, "Radio cache: DB rows=$db_total, readable=$db_readable, missing=$db_missing");
    botNotice($self, $nick, "Radio cache dir: " . (($incoming && -d $incoming) ? "$incoming mp3=$fs_mp3 readable=$fs_readable" : "not available (" . ($incoming || 'undefined') . ")"));

    if (@missing_examples) {
        botNotice($self, $nick, "Radio cache missing examples: " . join(' | ', @missing_examples));
    }

    botNotice($self, $nick, "Use: radioimport <file> or radioimportdir [directory] to populate/update the cache.");

    logBot($self, $ctx->message, undef, 'radiocache', "db=$db_total readable=$db_readable missing=$db_missing");
    return 1;
}


sub radioCheck_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $incoming = _liquidsoap_config_value($self, 'YOUTUBEDL_INCOMING', '');
    my $download_enabled = _liquidsoap_config_value($self, 'RADIO_DOWNLOAD_ENABLED', 0);
    my $ytdlp    = _liquidsoap_config_value($self, 'YTDLP_PATH', '/usr/bin/yt-dlp');
    my $cookies  = _liquidsoap_config_value($self, 'YTDLP_COOKIES_FILE', '');
    my $remote_components = _liquidsoap_config_value($self, 'YTDLP_REMOTE_COMPONENTS', '');
    my $timeout  = _liquidsoap_config_value($self, 'YTDLP_TIMEOUT', 180);

    my $download_status =
        (defined($download_enabled) && $download_enabled =~ /^(?:1|yes|true|on|enabled)$/i)
        ? 'enabled'
        : 'disabled';

    my $host = _liquidsoap_config_value($self, 'LIQUIDSOAP_TELNET_HOST', '127.0.0.1');
    my $port = _liquidsoap_config_value($self, 'LIQUIDSOAP_TELNET_PORT', 1235);
    my $qid  = _liquidsoap_config_value($self, 'LIQUIDSOAP_QUEUE_ID',  'mediabot_queue');

    my @lines;

    push @lines, "Radio check:";

    if (defined($incoming) && $incoming ne '' && -d $incoming && -w $incoming) {
        push @lines, "incoming: OK writable ($incoming)";
    }
    else {
        push @lines, "incoming: FAIL not writable or missing (" . ($incoming || 'undefined') . ")";
    }

    push @lines, "downloads: $download_status";

    if (defined($ytdlp) && $ytdlp ne '' && -x $ytdlp) {
        my $version = '';
        if (open my $fh, '-|', $ytdlp, '--version') {
            $version = <$fh> // '';
            close $fh;
            chomp $version;
        }
        $version = 'version unknown' unless defined($version) && $version ne '';
        push @lines, "yt-dlp: OK $version ($ytdlp)";
    }
    else {
        push @lines, "yt-dlp: FAIL not executable (" . ($ytdlp || 'undefined') . ")";
    }

    if (defined($cookies) && $cookies ne '') {
        if (-r $cookies) {
            my $cookie_size = -s $cookies || 0;
            my $cookie_age_days = int(-M $cookies);
            push @lines, "cookies: OK readable ($cookies, ${cookie_size} bytes, age=${cookie_age_days}d)";
        }
        else {
            push @lines, "cookies: configured but not readable/missing ($cookies)";
        }
    }
    else {
        push @lines, "cookies: not configured";
    }

    push @lines, "yt-dlp remote components: " . ($remote_components || "not configured");
    push @lines, "yt-dlp timeout: $timeout seconds";

    my $liq = _liquidsoap_client($self);
    my ($ok, $response) = $liq->queue();

    if ($ok) {
        push @lines, "Liquidsoap: OK $host:$port queue=$qid";
    }
    else {
        push @lines, "Liquidsoap: FAIL $host:$port queue=$qid error=$response";
    }

    my $status_base = _liquidsoap_config_value($self, 'RADIO_ICECAST_STATUS_BASE_URL', '');
    my $public_base = _liquidsoap_config_value($self, 'RADIO_ICECAST_PUBLIC_BASE_URL', '');
    my $mount       = _liquidsoap_config_value($self, 'RADIO_ICECAST_PRIMARY_MOUNT', '');

    push @lines, "Icecast status base: " . ($status_base || 'undefined');
    push @lines, "Icecast public stream: " . (($public_base && $mount) ? "$public_base$mount" : 'undefined');

    for my $line (@lines) {
        botNotice($self, $nick, $line);
    }

    logBot($self, $ctx->message, undef, 'radiocheck', ($ok ? 'ok' : 'liquidsoap-failed'));
    return 1;
}


sub radioQueue_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $liq = _liquidsoap_client($self);
    my ($ok, $response) = $liq->queue();

    unless ($ok) {
        botNotice($self, $nick, "Radio: queue check failed: Liquidsoap error: $response");
        logBot($self, $ctx->message, undef, 'radioqueue', 'error');
        return;
    }

    _radio_notice_lines($ctx, 'Liquidsoap queue', $response, 10);
    logBot($self, $ctx->message, undef, 'radioqueue', undef);
    return 1;
}

sub radioPush_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    return unless $ctx->require_level('Master');

    my $uri = join(' ', @args);
    $uri =~ s/^\s+|\s+$//g;

    unless ($uri ne '') {
        botNotice($self, $nick, "Syntax: radiopush <absolute-local-mp3-path>");
        return;
    }

    unless ($uri =~ m{^/}) {
        botNotice($self, $nick, "Radio: radiopush expects an absolute local MP3 path.");
        return;
    }

    if ($uri =~ /\s/) {
        botNotice($self, $nick, "Radio: radiopush does not support spaces in file paths yet.");
        return;
    }

    unless (-r $uri) {
        botNotice($self, $nick, "Radio: radiopush file is not readable: $uri");
        return;
    }

    my $liq = _liquidsoap_client($self);
    my ($ok, $response) = $liq->push($uri);

    unless ($ok) {
        botNotice($self, $nick, "Radio: Liquidsoap push failed: $response");
        logBot($self, $ctx->message, undef, 'radiopush', 'error', $uri);
        return;
    }

    botNotice($self, $nick, "Radio: queued local file through Liquidsoap: $uri");
    _radio_notice_lines($ctx, 'Liquidsoap', $response, 4);

    logBot($self, $ctx->message, undef, 'radiopush', $uri);
    return 1;
}

sub radioSkip_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $liq = _liquidsoap_client($self);
    my ($ok, $response) = $liq->skip();

    unless ($ok) {
        botNotice($self, $nick, "Radio: Liquidsoap skip failed: $response");
        logBot($self, $ctx->message, undef, 'radioskip', 'error');
        return;
    }

    botNotice($self, $nick, "Radio: skip command sent to Liquidsoap.");
    _radio_notice_lines($ctx, 'Liquidsoap', $response, 4);

    logBot($self, $ctx->message, undef, 'radioskip', undef);
    return 1;
}

sub radioFlush_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $liq = _liquidsoap_client($self);
    my ($ok, $response) = $liq->flush_and_skip();

    unless ($ok) {
        botNotice($self, $nick, "Radio: Liquidsoap flush failed: $response");
        logBot($self, $ctx->message, undef, 'radioflush', 'error');
        return;
    }

    botNotice($self, $nick, "Radio: queue flushed and current track skipped.");
    _radio_notice_lines($ctx, 'Liquidsoap', $response, 4);

    logBot($self, $ctx->message, undef, 'radioflush', undef);
    return 1;
}


sub update_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    return unless $ctx->require_level('Master');

    my $script = 'install/deploy_update.sh';
    my $msg = "The IRC update command is disabled for safety. Use ./$script manually from the mediabot_v3 directory.";

    if ($ctx->is_private) {
        $ctx->reply_private($msg);
    } else {
        botNotice($self, $nick, $msg);
    }

    logBot($self, $ctx->message, undef, 'update', 'disabled');
    return 1;
}

sub update {
    my ($self, $message, $sNick, $sChannel, @tArgs) = @_;

    my $ctx = Mediabot::Context->new(
        bot     => $self,
        message => $message,
        nick    => $sNick,
        channel => $sChannel,
        command => 'update',
        args    => \@tArgs,
    );

    return update_ctx($ctx);
}

sub song_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $conf = $self->{conf};

    my ($radio, $radio_cfg) = _radio_icecast_client($self);
    my $public_base   = $radio_cfg->{public_base};
    my $primary_mount = $radio_cfg->{primary_mount};

    # A3: get_summary() -> _fetch_icestats() -> HTTP GET is synchronous;
    # bot blocks for up to $timeout seconds — acceptable for a local Icecast.
    my $info = $radio->get_summary(
        primary_mount => $primary_mount,
        public_base   => $public_base,
    );

    unless ($info->{ok}) {
        my $msg = "Radio error: " . ($info->{error} || 'unknown error');
        if ($ctx->is_private) {
            $ctx->reply_private($msg);
        } else {
            $ctx->reply($msg);
        }
        logBot($self, $ctx->message, undef, 'song', 'error');
        return;
    }

    my $title      = defined $info->{title} && $info->{title} ne '' ? $info->{title} : 'unknown';
    my $listen_url = $info->{listen_url} || ($public_base . $primary_mount);

    my $msg = _radio_format_song_line(
        listen_url => $listen_url,
        title      => $title,
    );

    if ($ctx->is_private) {
        $ctx->reply_private($msg);
    } else {
        $ctx->reply($msg);
    }

    logBot($self, $ctx->message, undef, 'song', undef);
}

1;

