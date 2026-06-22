package Mediabot::External::Claude;
# =============================================================================
# Mediabot::External::Claude — ChatGPT/OpenAI + Claude/Anthropic + TMDB
# =============================================================================
# mb95-R1: extrait de Mediabot::External pour le découpage en sous-modules.
# External.pm reste la façade — il charge ce module et importe les subs.
#
# Dépendances internes (helpers dans External.pm) :
#   _make_http, Mediabot::External::_chanset_ok, getIdChansetList, getIdChannelSet
#   botPrivmsg, botNotice (via Mediabot::Helpers)
# =============================================================================

use strict;
use warnings;
use Exporter 'import';
use Encode qw(encode decode);
use JSON::MaybeXS;
use URI::Escape qw(uri_escape_utf8);

our $VERSION = '1.00';

our @EXPORT_OK = qw(
    _chatgpt_conf_int
    _chatgpt_conf_float
    _chatgpt_conf_string
    chatGPT_ctx
    chatGPT
    _chatgpt_wrap
    _repair_utf8_mojibake
    mbTMDBSearch_ctx
    get_tmdb_info
    claude_ctx
    claudeAI
    _claude_send_and_parse
);

# ------------------------------------------------------------------
# CONSTANTS (all prefixed with CHATGPT_)
# ------------------------------------------------------------------

use constant {
    CHATGPT_API_URL      => 'https://api.openai.com/v1/chat/completions',
    CHATGPT_MODEL        => 'gpt-4o-mini',
    CHATGPT_TEMPERATURE  => 0.7,
    CHATGPT_MAX_TOKENS   => 400,
    CHATGPT_MAX_PRIVMSG  => 4,       # how many PRIVMSG we allow to send
    CHATGPT_WRAP_BYTES   => 400,     # safe IRC payload length
    CHATGPT_SLEEP_US     => 750_000, # µs between PRIVMSG
	CHATGPT_TRUNC_MSG    => ' [¯\_(ツ)_/¯ guess you can’t have everything…]',   # suffix when we truncate

    # --- Anthropic / Claude ---
    CLAUDE_API_URL       => 'https://api.anthropic.com/v1/messages',
    CLAUDE_API_VERSION   => '2023-06-01',
    CLAUDE_MODEL         => 'claude-haiku-4-5-20251001',
    CLAUDE_MAX_TOKENS    => 400,
    CLAUDE_MAX_PRIVMSG   => 4,
    CLAUDE_WRAP_BYTES    => 400,
    CLAUDE_SLEEP_US      => 750_000,
    CLAUDE_SYSTEM_PROMPT => 'You are a helpful IRC assistant. Be concise.',
    CLAUDE_TRUNC_MSG     => ' [truncated]',
    CLAUDE_MAX_HISTORY   => 6,  # A1: default max messages in conversation history
};

use constant CHATGPT_SYSTEM_PROMPT =>
    'You always answer in a helpful and serious way, precise and never start your answer with « Oh là là » when the answer is in French. Always respond using a maximum of 10 lines of text and line-based. There is one chance on two the answer contains emojis.';

sub _chatgpt_conf_int {
    my ($self, $key, $default, $min, $max) = @_;

    my $value = $self->{conf}->get($key);

    return $default unless defined($value) && $value =~ /^\d+\z/;

    $value = int($value);
    return $default if defined($min) && $value < $min;
    return $default if defined($max) && $value > $max;

    return $value;
}

sub _chatgpt_conf_float {
    my ($self, $key, $default, $min, $max) = @_;

    my $value = $self->{conf}->get($key);

    return $default unless defined($value) && $value =~ /^\d+(?:\.\d+)?\z/;

    $value = 0 + $value;
    return $default if defined($min) && $value < $min;
    return $default if defined($max) && $value > $max;

    return $value;
}

sub _chatgpt_conf_string {
    my ($self, $key, $default) = @_;

    my $value = $self->{conf}->get($key);

    return $default unless defined($value) && $value ne '';

    return $value;
}

# Queue IRC chunks without sleeping inside the IO::Async event loop.
#
# Batches are serialized per target so a second AI answer cannot interleave
# with a response that is still being paced. The first chunk is sent
# immediately; the configured delay applies only between subsequent chunks.
# When no usable event loop exists (notably lightweight tests), preserve
# compatibility by sending the batch immediately without a blocking sleep.
sub _queue_irc_chunks {
    my ($self, $target, $chunks, $sleep_us, $label) = @_;

    return 0 unless ref($chunks) eq 'ARRAY';

    my @payload = grep {
        defined($_) && $_ ne ''
    } @$chunks;

    return 0 unless @payload;

    my $queued_count = scalar @payload;

    $sleep_us = 0
        unless defined($sleep_us) && $sleep_us =~ /^\d+\z/;

    $label = 'AI'
        unless defined($label) && $label ne '';

    my $loop = eval {
        (ref($self) && $self->can('getLoop'))
            ? $self->getLoop
            : undef;
    };

    $loop ||= eval { $self->{loop} };

    my $can_schedule = $loop
        && eval { $loop->can('add') }
        && $sleep_us > 0
        && @payload > 1;

    unless ($can_schedule) {
        Mediabot::Helpers::botPrivmsg($self, $target, $_) for @payload;
        return $queued_count;
    }

    require IO::Async::Timer::Countdown;

    my $key = defined($target) && $target ne ''
        ? lc($target)
        : '__unknown__';

    my $queues = $self->{_external_ai_output_queues} //= {};
    my $state  = $queues->{$key} //= {
        active  => 0,
        batches => [],
        timer   => undef,
        current => undef,
    };

    push @{ $state->{batches} }, {
        chunks => \@payload,
        delay  => $sleep_us / 1_000_000,
        label  => $label,
    };

    return $queued_count if $state->{active};

    $state->{active} = 1;

    my ($pump, $schedule);

    my $cleanup = sub {
        my ($timer) = @_;
        return unless $timer;

        eval { $timer->stop if $timer->can('stop') };
        eval { $loop->remove($timer) };
    };

    $schedule = sub {
        my ($delay) = @_;

        my $timer;
        $timer = IO::Async::Timer::Countdown->new(
            delay     => $delay,
            on_expire => sub {
                $cleanup->($timer);
                $state->{timer} = undef;
                $pump->();
                # mb326-B1: rompre le cycle closure<->timer (le slot hash est vidé
                # mais le lexical capturé maintenait l'objet en vie).
                undef $timer;
            },
        );

        $state->{timer} = $timer;
        $loop->add($timer);
        $timer->start;
    };

    $pump = sub {
        my $batch = $state->{current};

        unless ($batch) {
            $batch = shift @{ $state->{batches} };
            $state->{current} = $batch if $batch;
        }

        unless ($batch) {
            delete $queues->{$key};
            $pump     = undef;
            $schedule = undef;
            return;
        }

        my $chunk = shift @{ $batch->{chunks} };

        if (defined($chunk) && $chunk ne '') {
            my $ok = eval {
                Mediabot::Helpers::botPrivmsg($self, $target, $chunk);
                1;
            };

            unless ($ok) {
                my $error = $@ || 'unknown send error';
                $error =~ s/\s+/ /g;
                eval {
                    $self->{logger}->log(
                        1,
                        "$batch->{label} paced output failed for $target: $error"
                    );
                };
            }
        }

        if (@{ $batch->{chunks} }) {
            $schedule->($batch->{delay});
            return;
        }

        $state->{current} = undef;

        if (@{ $state->{batches} }) {
            # Preserve ordering between consecutive replies on the same target.
            $schedule->($batch->{delay});
            return;
        }

        delete $queues->{$key};
        $pump     = undef;
        $schedule = undef;
    };

    $pump->();

    return $queued_count;
}

# chatGPT_ctx() — wrapper Context pour la commande publique !tellme
sub chatGPT_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    chatGPT($self, $message, $nick, $channel, @args);
}

# ------------------------------------------------------------------
# chatGPT()
# ------------------------------------------------------------------
sub chatGPT {
    my ($self, $message, $nick, $chan, @args) = @_;

    # --------------------------------------------------------------
    #  sanity / config checks
    # --------------------------------------------------------------
	my $api_key = $self->{conf}->get('openai.API_KEY')
    	or ($self->{logger}->log(0,'chatGPT() openai.API_KEY missing'), return);

    my $chatgpt_api_url     = _chatgpt_conf_string($self, 'openai.API_URL',     CHATGPT_API_URL);
    my $chatgpt_model          = _chatgpt_conf_string($self, 'openai.MODEL',          CHATGPT_MODEL);
    my $chatgpt_fallback_model = _chatgpt_conf_string($self, 'openai.FALLBACK_MODEL', '');
    my $chatgpt_temperature    = _chatgpt_conf_float( $self, 'openai.TEMPERATURE',    CHATGPT_TEMPERATURE, 0, 2);
    my $chatgpt_system_prompt  = _chatgpt_conf_string($self, 'openai.SYSTEM_PROMPT',  CHATGPT_SYSTEM_PROMPT);
    $chatgpt_system_prompt =~ s/\r|\n/ /g;
    $chatgpt_system_prompt = substr($chatgpt_system_prompt, 0, 800);
    my $chatgpt_max_tokens  = _chatgpt_conf_int(   $self, 'openai.MAX_TOKENS',  CHATGPT_MAX_TOKENS,  1, 4000);
    my $chatgpt_max_privmsg = _chatgpt_conf_int(   $self, 'openai.MAX_PRIVMSG', CHATGPT_MAX_PRIVMSG, 1, 8);
    my $chatgpt_wrap_bytes  = _chatgpt_conf_int(   $self, 'openai.WRAP_BYTES',  CHATGPT_WRAP_BYTES,  120, 450);
    my $chatgpt_sleep_us    = _chatgpt_conf_int(   $self, 'openai.SLEEP_US',    CHATGPT_SLEEP_US,    0, 2_000_000);

    unless ($chatgpt_api_url =~ m{^https://}i) {
        $self->{logger}->log(1, "chatGPT() invalid openai.API_URL, falling back to default");
        $chatgpt_api_url = CHATGPT_API_URL;
    }

    if ($chatgpt_fallback_model ne '' && $chatgpt_fallback_model !~ /^[A-Za-z0-9._:-]+\z/) {
        $self->{logger}->log(1, "chatGPT() invalid openai.FALLBACK_MODEL ignored");
        $chatgpt_fallback_model = '';
    }

    @args
        or (Mediabot::Helpers::botNotice($self,$nick,'Syntax: tellme <prompt>'), return);

    # opt-in check (+chatGPT chanset)
    my $setlist = Mediabot::External::getIdChansetList($self,'chatGPT') // '';
    my $setid   = Mediabot::External::getIdChannelSet($self,$chan,$setlist) // '';
    return unless length $setid;

    # --------------------------------------------------------------
    # payload preparation
    # --------------------------------------------------------------
    my $prompt = join ' ', @args;
    $self->{logger}->log(5,"chatGPT() chatGPT prompt: $prompt");

    my $build_payload = sub {
        my ($model) = @_;

        return encode_json {
            model       => $model,
            temperature => $chatgpt_temperature,
            max_tokens  => $chatgpt_max_tokens,
            messages    => [
                { role => 'system',
                  content => $chatgpt_system_prompt
                },
                { role => 'user', content => $prompt },
            ],
        };
    };

    # --------------------------------------------------------------
    # call the API with HTTP::Tiny (non-blocking, no shell)
    # --------------------------------------------------------------
    my $http = Mediabot::External::_make_http(timeout => 30);

    my $send_request = sub {
        my ($model) = @_;

        return eval {
            $http->request(
                'POST',
                $chatgpt_api_url,
                {
                    headers => {
                        'Content-Type'  => 'application/json',
                        'Authorization' => "Bearer $api_key",
                    },
                    content => $build_payload->($model),
                }
            );
        } // { success => 0, status => 0, reason => $@ };
    };

    my $request_model  = $chatgpt_model;
    my $http_response  = $send_request->($request_model);
    my $fallback_tried = 0;

    if (
        !$http_response->{success}
        && $chatgpt_fallback_model ne ''
        && $chatgpt_fallback_model ne $request_model
        && (($http_response->{status} // 0) == 400
            || ($http_response->{status} // 0) == 403
            || ($http_response->{status} // 0) == 404)
    ) {
        $self->{logger}->log(
            1,
            "chatGPT() primary model $request_model failed with HTTP "
            . ($http_response->{status} // 0) . " "
            . ($http_response->{reason} // '')
            . "; retrying with fallback model $chatgpt_fallback_model"
        );

        $request_model  = $chatgpt_fallback_model;
        $http_response  = $send_request->($request_model);
        $fallback_tried = 1;
    }

    unless ($http_response->{success}) {
        $self->{logger}->log(
            1,
            "chatGPT() HTTP error: "
            . ($http_response->{status} // 0) . " "
            . ($http_response->{reason} // '')
            . " model=$request_model"
        );

        Mediabot::Helpers::botPrivmsg($self, $chan, "($nick) Sorry, API did not answer.");
        return;
    }

    if ($fallback_tried) {
        $self->{logger}->log(1, "chatGPT() fallback model succeeded: $request_model");
    }

    my $response = $http_response->{content};
    unless ($response) {
        $self->{logger}->log(1, "chatGPT() empty response from API");
        Mediabot::Helpers::botPrivmsg($self, $chan, "($nick) Sorry, API did not answer.");
        return;
    }

    # --------------------------------------------------------------
	# decode the JSON response
	# --------------------------------------------------------------
	my $data = eval { decode_json($response) };
	my $answer;

	if (
		!$@
		&& ref($data) eq 'HASH'
		&& ref($data->{choices}) eq 'ARRAY'
		&& ref($data->{choices}[0]) eq 'HASH'
		&& ref($data->{choices}[0]{message}) eq 'HASH'
		&& defined($data->{choices}[0]{message}{content})
		&& $data->{choices}[0]{message}{content} ne ''
	) {
		$answer = $data->{choices}[0]{message}{content};
	}

	if ($@ || !defined($answer) || $answer eq '') {
		$self->{logger}->log( 0, 'chatGPT() chatGPT invalid JSON response');
		$self->{logger}->log( 5, "chatGPT() Raw API response: $response");
		$self->{logger}->log( 3, "chatGPT() JSON decode error: $@") if $@;
		$self->{logger}->log( 3, "chatGPT() Missing expected content in response structure") unless $@;
		Mediabot::Helpers::botPrivmsg($self, $chan, "($nick) Could not read API response.");
		return;
	}
    $self->{logger}->log(5,"chatGPT() chatGPT raw answer: $answer");

    # -------- minimise PRIVMSG --------------------------------------
    $answer =~ s/[\r\n]+/ /g;    # strip CR/LF
    $answer =~ s/\s{2,}/ /g;     # squeeze spaces

    my @chunk = _chatgpt_wrap($answer, $chatgpt_wrap_bytes);           # word-safe
    # … after  my @chunk = _chatgpt_wrap($answer);
    my $truncate   = @chunk > $chatgpt_max_privmsg;
    my $last       = $truncate ? $chatgpt_max_privmsg - 1 : $#chunk;

    if ($truncate) {
        my $suff  = CHATGPT_TRUNC_MSG;                   # funny suffix
        my $allow = $chatgpt_wrap_bytes - length($suff);  # bytes we can keep

        if (length($chunk[$last]) > $allow) {            # always enforce room
            $chunk[$last] = substr($chunk[$last], 0, $allow);
            $chunk[$last] =~ s/\s+\S*$//;                # backtrack to prev word
            $chunk[$last] =~ s/\s+$//;                   # trim trailing spaces
        }
        $chunk[$last] .= $suff;                          # now safe to append
    }

    my @out_chunks = @chunk[0 .. $last];
    my $queued = _queue_irc_chunks(
        $self,
        $chan,
        \@out_chunks,
        $chatgpt_sleep_us,
        'chatGPT',
    );
    $self->{logger}->log(4, "chatGPT() queued $queued PRIVMSG");
}

# ------------------------------------------------------------------
# helper: wrap text to ≤CHATGPT_WRAP_BYTES without splitting words
# ------------------------------------------------------------------
sub _chatgpt_wrap {
    my ($txt, $wrap_bytes) = @_;

    $wrap_bytes = CHATGPT_WRAP_BYTES
        unless defined($wrap_bytes) && $wrap_bytes =~ /^\d+\z/ && $wrap_bytes > 0;

    my @out;

    while (length $txt) {

        # If the remainder already fits, push and break
        if (length($txt) <= $wrap_bytes) {
            push @out, $txt;
            last;
        }

        # Look ahead up to the limit
        my $slice = substr($txt, 0, $wrap_bytes);
        my $break = rindex($slice, ' ');

        # If space found, split there; else hard split
        $break = $wrap_bytes if $break == -1;

        push @out, substr($txt, 0, $break, '');   # remove from $txt
        $txt =~ s/^\s+//;                         # trim leading spaces
    }
    return @out;
}

# xlogin
# Authenticate the bot to Undernet CSERVICE and set +x on itself.
# Requires:
#   - Logged in
#   - Level >= Master
# ---------------------------------------------------------------------------
# _repair_utf8_mojibake($text)
# Repair common IRC/client mojibake where UTF-8 bytes were decoded as CP1252.
# Example:
#   "piÃ¨ge de cristal" -> "piège de cristal"
# The function is deliberately conservative: if conversion fails or does not
# reduce suspicious mojibake markers, the original text is returned unchanged.
# ---------------------------------------------------------------------------
sub _repair_utf8_mojibake {
    my ($text) = @_;

    return $text unless defined $text;
    # B3: broaden detection — double-UTF8 produces various high-byte sequences
    return $text unless $text =~ /[\xC0-\xFF]{2,}|[ÃÂâÅÄÖÜ]/;

    my $score = sub {
        my ($s) = @_;
        return 9999 unless defined $s;
        return (() = $s =~ /[ÃÂâ�]/g);
    };

    # Best case: mojibake came from UTF-8 bytes decoded as Windows-1252.
    # This repairs both accents and typographic punctuation:
    #   piÃ¨ge        -> piège
    #   Lâ€™Ã©tÃ©      -> L’été
    my $fixed_cp1252 = eval {
        decode('UTF-8', encode('Windows-1252', $text));
    };

    if (!$@ && defined($fixed_cp1252) && $score->($fixed_cp1252) < $score->($text)) {
        return $fixed_cp1252;
    }

    # Fallback: mojibake came from UTF-8 bytes decoded as Latin-1.
    my $fixed_latin1 = eval {
        decode('UTF-8', pack('C*', map { ord($_) & 0xFF } split //, $text));
    };

    if (!$@ && defined($fixed_latin1) && $score->($fixed_latin1) < $score->($text)) {
        return $fixed_latin1;
    }

    return $text;
}

sub mbTMDBSearch_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my @tArgs   = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $conf = $self->{conf};

    my $api_key = $conf->get('tmdb.API_KEY');
    unless (defined($api_key) && $api_key ne "") {
        $self->{logger}->log(1, "tmdb.API_KEY is undefined in config file");
        Mediabot::Helpers::botNotice($self, $nick, "TMDB API key is missing in the configuration.");
        return;
    }

    unless (defined($tArgs[0]) && $tArgs[0] ne "") {
        Mediabot::Helpers::botNotice($self, $nick, "Syntax: tmdb <movie or series name>");
        return;
    }

    my $query = join(" ", @tArgs);
    my $raw_query = $query;

    $query = _repair_utf8_mojibake($query);

    if ($query ne $raw_query) {
        $self->{logger}->log(4, "mbTMDBSearch_ctx() repaired mojibake query '$raw_query' -> '$query'");
    }

    my $lang  = Mediabot::External::getTMDBLangChannel($self, $channel) || 'en';
    $self->{logger}->log(4, "mbTMDBSearch_ctx() tmdb_lang for $channel is $lang");

    my $info = get_tmdb_info($api_key, $lang, $query, $self->{logger});
    unless ($info) {
        Mediabot::Helpers::botPrivmsg($self, $channel, "($nick) No results found for '$query'.");
        return;
    }

    my $title    = $info->{title}    || $info->{name}          || "Unknown title";
    my $overview = $info->{overview} || "No synopsis available.";
    my $date     = $info->{release_date} || $info->{first_air_date} || "????";
    my $year     = ($date =~ /^(\d{4})/) ? $1 : "????";
    my $rating   = defined($info->{vote_average}) ? sprintf("%.1f", $info->{vote_average}) : "?";
    my $type     = exists($info->{title}) ? "Movie" : "TV Series";

    # Build the final IRC message first, then truncate the complete line.
    # The old code truncated only the overview based on prefix length; when the
    # prefix was long or MAIN_PROG_MAXLEN was too small, the computed overview
    # budget could become negative and produce odd output.
    my $maxlen = int(eval { $self->{conf}->get('main.MAIN_PROG_MAXLEN') } || 400);
    $maxlen = 120 if $maxlen < 120;
    $maxlen = 900 if $maxlen > 900;

    my $prefix = "($nick) [$type] \"$title\" ($year) - Rating: $rating/10 - ";
    my $reply  = $prefix . $overview;

    if (length($reply) > $maxlen) {
        my $cut = $maxlen - 3;
        $cut = 1 if $cut < 1;

        $reply = substr($reply, 0, $cut);
        $reply =~ s/\s+\S*$// if length($reply) > 40;  # backtrack to last complete word when useful
        $reply =~ s/[\s.,;:!?-]+\z//;
        $reply .= "...";
    }

    Mediabot::Helpers::botPrivmsg($self, $channel, $reply);
}

# Get TMDB info using HTTP::Tiny
sub get_tmdb_info {
    my ($api_key, $lang, $query, $logger) = @_;

    $lang = 'en-US'
        unless defined($lang) && $lang =~ /^[A-Za-z]{2}(?:-[A-Za-z]{2})?\z/;

    my $encoded_query = uri_escape_utf8($query);
    my $encoded_lang  = uri_escape_utf8($lang);
    my $url = "https://api.themoviedb.org/3/search/multi?api_key=$api_key&language=$encoded_lang&query=$encoded_query";

    my $http     = Mediabot::External::_make_http(timeout => 10);
    my $response = eval { $http->get($url); } // { success => 0, status => 0, reason => $@ };

    unless ($response->{success}) {
        my $status = $response->{status} // 0;
        my $reason = $response->{reason} // '';

        if ($logger) {
            $logger->log(3, "get_tmdb_info() HTTP error: $status $reason");
        }

        return undef;
    }

    my $content = $response->{content} // '';
    unless ($content ne '') {
        $logger->log(3, "get_tmdb_info() empty response") if $logger;
        return undef;
    }

    my $data = eval { decode_json($content) };
    if ($@ || ref($data) ne 'HASH') {
        my $err = $@ || 'decoded response is not a HASH';
        $logger->log(3, "get_tmdb_info() JSON decode error: $err") if $logger;
        return undef;
    }

    unless (ref($data->{results}) eq 'ARRAY' && @{ $data->{results} }) {
        $logger->log(4, "get_tmdb_info() no results in TMDB response") if $logger;
        return undef;
    }

    # Find the first movie or TV result.  Be defensive: API responses can
    # contain partial entries, unexpected media types, or malformed data.
    my $result;
    foreach my $item (@{ $data->{results} }) {
        next unless ref($item) eq 'HASH';

        my $media_type = $item->{media_type} // '';
        next unless $media_type eq 'movie' || $media_type eq 'tv';

        $result = $item;
        last;
    }

    return $result;
}

# --- Helpers DEBUG ------------------------------------------------------------


# ------------------------------------------------------------------
# claude_ctx() — Context wrapper for !ai command
# ------------------------------------------------------------------
sub claude_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;
    my @args    = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    # U8: !ai forget — clear only the caller's own history/persona on this channel
    if (@args && lc($args[0]) eq 'forget') {
        # mb123: history keys are case-sensitive and stored with the raw IRC nick,
        # while persona keys are deliberately lower-cased. Keep both conventions.
        my $chan_part   = (defined $channel ? $channel : '__private__');
        my $hist_key    = "$nick\x00$chan_part";
        my $persona_key = lc($nick) . "\x00" . $chan_part;
        # mb141-B1: "forget" must clear every in-memory AI session state.
        # History uses the raw IRC nick, while persona/pinned/last_active use
        # lc(nick). Keep both key conventions deliberately.
        my $aux_key     = lc($nick) . "\x00" . $chan_part;

        my $had = (exists $self->{_claude_history}{$hist_key}
                || exists $self->{_claude_persona}{$persona_key}
                || exists $self->{_claude_pinned}{$aux_key}
                || exists $self->{_ai_last_active}{$aux_key}) ? 1 : 0;

        delete $self->{_claude_history}{$hist_key};
        delete $self->{_claude_persona}{$persona_key};
        delete $self->{_claude_pinned}{$aux_key};
        delete $self->{_ai_last_active}{$aux_key};

        Mediabot::Helpers::botNotice($self, $nick, $had
            ? 'Your Claude history, persona and pinned context have been cleared.'
            : 'No active Claude session found for you on this channel.');
        return 1;
    }

    # R5: !ai stats — show Claude usage statistics
    if (@args && lc($args[0]) eq 'stats') {
        my $reqs = eval { $self->{metrics}->get('mediabot_claude_requests_total') } // 0;
        my $errs = eval { $self->{metrics}->get('mediabot_claude_errors_total') }   // 0;
        my $rl   = eval { $self->{metrics}->get('mediabot_claude_ratelimit_total') } // 0;
        my $hist_count = scalar keys %{ $self->{_claude_history}      // {} };
        my $pers_count = scalar keys %{ $self->{_claude_persona}      // {} };
        Mediabot::Helpers::botNotice($self, $nick, "Claude stats: $reqs req(s), $errs error(s), $rl rate-limited");
        Mediabot::Helpers::botNotice($self, $nick, "Active: $hist_count history session(s), $pers_count persona(s)");
        return 1;
    }

    # BB8: !ai models — list Claude models (mb103-IMP2: appel API dynamique avec fallback statique)
    if (@args && lc($args[0]) eq 'models') {
        my $current = _chatgpt_conf_string($self, 'anthropic.MODEL', CLAUDE_MODEL);
        my $api_key = _chatgpt_conf_string($self, 'anthropic.API_KEY', '');

        my @fetched;
        if ($api_key ne '') {
            eval {
                my $http = Mediabot::External::_make_http(timeout => 8);
                my $res  = $http->get(
                    CLAUDE_API_URL =~ s{/messages$}{/models}r,
                    { headers => {
                        'x-api-key'         => $api_key,
                        'anthropic-version' => CLAUDE_API_VERSION,
                    }}
                );
                if ($res->{success}) {
                    my $data = decode_json($res->{content});
                    if (ref($data->{data}) eq 'ARRAY') {
                        @fetched = map { $_->{id} }
                                   grep { ref($_) eq 'HASH' && $_->{id} =~ /^claude-/i }
                                   @{ $data->{data} };
                    }
                }
            };
            $self->{logger}->log(3, "!ai models API error: $@") if $@;
        }

        my @known = @fetched ? @fetched : qw(
            claude-opus-4-8
            claude-opus-4-7
            claude-opus-4-6
            claude-sonnet-4-6
            claude-haiku-4-5-20251001
        );

        my @labeled = map { $_ eq $current ? "$_ (current)" : $_ } @known;
        my $source  = @fetched ? ' [live]' : ' [static]';
        Mediabot::Helpers::botNotice($self, $nick,
            "Available Claude models$source: " . join('  |  ', @labeled));
        return 1;
    }

    # Z2: !ai summary [n|today|yesterday|week|last|Nd] [nick] — summarise from CHANNEL_LOG
    if (@args && lc($args[0]) eq 'summary') {
        shift @args;

        # mb86-IMP3 / mb87-IMP2 / mb91-IMP2: modes de filtre temporel
        my $date_filter = '';
        my $date_label  = '';
        if (@args && lc($args[0]) eq 'last') {
            # mb91-IMP2: résumé depuis le dernier appel !ai summary sur ce canal
            shift @args;
            my $last_key = "summary_last:$channel";
            my $last_ts  = $self->{_claude_summary_ts}{$last_key} // 0;
            if ($last_ts > 0) {
                $date_filter = "AND cl.ts > FROM_UNIXTIME($last_ts)";
                my $mins = int((time() - $last_ts) / 60);
                $date_label  = $mins >= 60
                    ? sprintf(' (last %dh%02dm)', int($mins/60), $mins%60)
                    : " (last ${mins}m)";
            } else {
                $date_filter = "AND DATE(cl.ts) = CURDATE()";
                $date_label  = ' (today — no previous summary found)';
            }
        } elsif (@args && lc($args[0]) eq 'today') {
            shift @args;
            $date_filter = "AND DATE(cl.ts) = CURDATE()";
            $date_label  = ' (today)';
        } elsif (@args && lc($args[0]) eq 'yesterday') {
            shift @args;
            $date_filter = "AND DATE(cl.ts) = CURDATE() - INTERVAL 1 DAY";
            $date_label  = ' (yesterday)';
        } elsif (@args && lc($args[0]) eq 'week') {
            # mb87-IMP2: résumé de la semaine courante (lundi → aujourd'hui)
            shift @args;
            $date_filter = "AND cl.ts >= DATE_SUB(CURDATE(), INTERVAL WEEKDAY(CURDATE()) DAY)";
            $date_label  = ' (this week)';
        } elsif (@args && $args[0] =~ /^(\d+)d$/i) {
            # mb87-IMP2: !ai summary 7d — N derniers jours
            my $days = int($1); shift @args;
            $days = 1 if $days < 1; $days = 30 if $days > 30;
            $date_filter = "AND cl.ts >= NOW() - INTERVAL $days DAY";
            $date_label  = " (last ${days}d)";
        }

        # AA2: optional count (ignoré quand date_filter actif, mais toujours parsé)
        my $n_msgs = (@args && $args[0] =~ /^(\d+)$/) ? int(shift @args) : 10;
        $n_msgs = 5 if $n_msgs < 5; $n_msgs = 50 if $n_msgs > 50;
        # With date filter: lift the limit to 200 (couvre une journée/semaine chargée)
        $n_msgs = 200 if $date_filter;

        my $filter_nick = (@args && $args[0] !~ /^\d/) ? lc(shift @args) : undef;
        my $dbh = eval { $self->{db}->ensure_connected } // $self->{dbh};
        unless ($dbh && defined $channel) {
            Mediabot::Helpers::botNotice($self, $nick, 'Not available in private or DB not connected.'); return;
        }
        my ($sth, @bind);
        if ($filter_nick) {
            $sth = $dbh->prepare(qq{
                SELECT cl.nick, cl.publictext AS text FROM CHANNEL_LOG cl
                JOIN CHANNEL c ON c.id_channel = cl.id_channel
                WHERE c.name = ? AND LOWER(cl.nick) = ? AND cl.publictext IS NOT NULL
                $date_filter
                ORDER BY cl.id_channel_log DESC LIMIT ?
            });
            @bind = ($channel, $filter_nick, $n_msgs);
        } else {
            $sth = $dbh->prepare(qq{
                SELECT cl.nick, cl.publictext AS text FROM CHANNEL_LOG cl
                JOIN CHANNEL c ON c.id_channel = cl.id_channel
                WHERE c.name = ? AND cl.publictext IS NOT NULL
                $date_filter
                ORDER BY cl.id_channel_log DESC LIMIT ?
            });
            @bind = ($channel, $n_msgs);
        }
        unless ($sth && $sth->execute(@bind)) {
            $sth->finish if $sth;
            Mediabot::Helpers::botNotice($self, $nick, 'DB error.');
            return;
        }
        my @rows;
        while (my $r = $sth->fetchrow_hashref) { unshift @rows, "$r->{nick}: $r->{text}"; }
        $sth->finish;
        unless (@rows) {
            Mediabot::Helpers::botNotice($self, $nick, "No messages found on $channel$date_label."); return;
        }
        my $transcript = join("\n", @rows);
        my $who_str    = $filter_nick ? " by $filter_nick" : "";
        my $n_found    = scalar @rows;
        # mb91-IMP2: mémoriser le timestamp pour le mode !ai summary last
        if (defined $channel) {
            $self->{_claude_summary_ts}{"summary_last:$channel"} = time();
        }
        # mb108-IMP4: notifier immédiatement le nb de messages analysés (feedback avant l'appel API)
        Mediabot::Helpers::botNotice($self, $nick,
            "Summarising $n_found message(s)${who_str}${date_label} on $channel...");
        my $summary_prompt = "Summarise this IRC conversation${who_str}${date_label} ($n_found messages) in 2-3 sentences:\n$transcript";
        # Call Claude with injected prompt, output as notice to caller
        return claudeAI($self, $ctx->message, $nick, undef,
            sub { Mediabot::Helpers::botNotice($self, $nick, $_[0]) }, $summary_prompt);
    }

    # Y1: !ai relay <#chan> <prompt> — relay response to a channel (from private)
    if (@args >= 2 && lc($args[0]) eq 'relay' && $args[1] =~ /^#/) {
        shift @args;
        my $relay_chan = shift @args;
        unless (exists $self->{channels}{$relay_chan}) {
            Mediabot::Helpers::botNotice($self, $nick, "Not on channel $relay_chan."); return;
        }
        # Override channel and re-enter claudeAI with relay channel
        my $ctx_relay = bless { %$ctx, _channel => $relay_chan }, ref($ctx);
        return claudeAI($self, $ctx_relay->message // $ctx->message,
            $nick, $relay_chan, undef, @args);
    }

    # X1: !ai pin [clear|<text>] — manage pinned context
    if (@args && lc($args[0]) eq 'pin') {
        shift @args;
        my $pin_key = lc($nick) . "\x00" . (defined $channel ? $channel : '__private__');

        # !ai pin clear
        if (@args && lc($args[0]) eq 'clear') {
            delete $self->{_claude_pinned}{$pin_key};
            Mediabot::Helpers::botNotice($self, $nick, 'Pinned context cleared.');
            return 1;
        }

        # !ai pin <text>
        if (@args) {
            my $pinned = join(' ', @args);
            $pinned = substr($pinned, 0, 300);
            $self->{_claude_pinned}{$pin_key} = $pinned;
            Mediabot::Helpers::botNotice($self, $nick, "Pinned context: $pinned");
        } else {
            # !ai pin alone → show current
            my $current = $self->{_claude_pinned}{$pin_key};
            if ($current) {
                Mediabot::Helpers::botNotice($self, $nick, "Pinned: $current");
            } else {
                Mediabot::Helpers::botNotice($self, $nick, 'No pinned context.');
            }
        }
        return 1;
    }

    # K6: !ai model — show current Claude model
    if (@args && lc($args[0]) eq 'model') {
        my $model = _chatgpt_conf_string($self, 'anthropic.MODEL', CLAUDE_MODEL);
        Mediabot::Helpers::botNotice($self, $nick, "Current Claude model: $model");
        return 1;
    }

    # I2: !ai persona — manage per-nick system prompt
    # I6: improved: no args or 'show' → display current; 'clear' → remove
    if (@args && lc($args[0]) eq 'persona') {
        shift @args;
        my $persona_key = lc($nick) . "\x00" . (defined $channel ? $channel : '__private__');
        my $subcmd = @args ? lc($args[0]) : 'show';

        if ($subcmd eq 'clear') {
            delete $self->{_claude_persona}{$persona_key};
            Mediabot::Helpers::botNotice($self, $nick, 'Persona cleared -- using default system prompt.');  # B17/fix: ASCII only
        } elsif ($subcmd eq 'show' && @args <= 1 && ($args[0]//'') eq 'show') {
            my $current = $self->{_claude_persona}{$persona_key};
            if ($current) {
                Mediabot::Helpers::botNotice($self, $nick, "Current persona: $current");
            } else {
                Mediabot::Helpers::botNotice($self, $nick, 'No persona set -- using default system prompt.');
            }
        } elsif (!@args) {
            # No args at all: show current persona  (I6)
            my $current = $self->{_claude_persona}{$persona_key};
            if ($current) {
                Mediabot::Helpers::botNotice($self, $nick, "Current persona: $current");
            } else {
                Mediabot::Helpers::botNotice($self, $nick, 'No persona set -- using default system prompt.');
            }
        } else {
            # Has args and not 'clear'/'show' — set new persona
            my $persona = join(' ', @args);
            $persona = substr($persona, 0, 400);
            $self->{_claude_persona}{$persona_key} = $persona;
            Mediabot::Helpers::botNotice($self, $nick, "Persona set: $persona");
        }
        return 1;
    }

    # A4: !ai quota — show remaining requests in current rate limit window
    if (@args && lc($args[0]) eq 'quota') {
        # B13/fix: $channel can be undef in private — use a stable key
        my $rl_key = lc($nick) . "\x00" . (defined $channel ? $channel : '__private__');
        my $now    = time();

        # mb81/polish: keep !ai quota aligned with claudeAI() configurable
        # rate limit. Do not hardcode 5 requests / 60 seconds here.
        my $rate_max = eval { int($self->{conf}->get('anthropic.RATE_MAX') // 5) } // 5;
        my $rate_window = eval { int($self->{conf}->get('anthropic.RATE_WINDOW') // 60) } // 60;
        $rate_max = 1 if $rate_max < 1;
        $rate_window = 10 if $rate_window < 10;

        my $fmt_wait = sub {
            my ($wait) = @_;
            $wait = int($wait // 0);
            $wait = 0 if $wait < 0;
            return $wait >= 60
                ? sprintf('%dm %ds', int($wait / 60), $wait % 60)
                : "${wait}s";
        };

        my $rl = $self->{_claude_ratelimit}{$rl_key};

        if (!$rl || ($now - ($rl->{window} // 0)) >= $rate_window) {
            Mediabot::Helpers::botNotice($self, $nick, "AI quota: $rate_max/$rate_max requests available (window not started).");
        }
        else {
            my $used = $rl->{count} // 0;
            my $remaining = $rate_max - $used;
            $remaining = 0 if $remaining < 0;

            my $wait = $rate_window - ($now - ($rl->{window} // $now));
            my $wait_h = $fmt_wait->($wait);

            Mediabot::Helpers::botNotice($self, $nick,
                "AI quota: $remaining/$rate_max request(s) remaining"
                . " (window resets in $wait_h)");
        }
        return 1;
    }

    # F50: !ai history — show current conversation context
    if (@args && lc($args[0]) eq 'history') {
        my $hist_key = "$nick\x00" . ($channel // "__private__");
        my $history  = $self->{_claude_history}{$hist_key} // [];
        unless (@$history) {
            Mediabot::Helpers::botNotice($self, $nick, 'No conversation history.');
            return 1;
        }
        my $hist_count = scalar(@$history);
        Mediabot::Helpers::botNotice($self, $nick, "$hist_count message(s) in context"
            . ($hist_count > 6 ? ' (showing last 6):' : ':'));
        # Q3: show only last 6 entries to avoid flooding
        my @display = $hist_count > 6 ? @{$history}[-6..-1] : @$history;
        for my $msg (@display) {
            my $role    = $msg->{role}    // '?';
            my $content = $msg->{content} // '';
            $content = substr($content, 0, 100) . '...' if length($content) > 100;
            # T2: include timestamp if present in history entry
            my $ts_tag  = $msg->{ts} ? ' [' . scalar(localtime($msg->{ts})) . ']' : '';
            Mediabot::Helpers::botNotice($self, $nick, "  [$role]$ts_tag $content");
        }
        return 1;
    }

    # P2: !ai reset — clear conversation history for this nick+channel
    if (@args && lc($args[0]) eq 'reset') {
        my $hist_key = "$nick\x00" . ($channel // "__private__");
        delete $self->{_claude_history}{$hist_key};
        Mediabot::Helpers::botNotice($self, $nick, 'Conversation history cleared.');
        return 1;
    }

    claudeAI($self, $message, $nick, $channel, @args);
}

# ------------------------------------------------------------------
# claudeAI() — send a prompt to Anthropic Claude and reply on IRC
# ------------------------------------------------------------------
sub claudeAI {
    # R1: optional $output_fn callback — called instead of Mediabot::Helpers::botPrivmsg for each line
    # Signature: claudeAI($self, $message, $nick, $chan, @args)
    #        or: claudeAI($self, $message, $nick, $chan, $output_fn_ref, @args)
    my ($self, $message, $nick, $chan, @args) = @_;
    my $output_fn;
    if (@args && ref($args[0]) eq 'CODE') {
        $output_fn = shift @args;
    }
    # mb98-B1: $chan peut être undef (ex: !ai summary passe undef pour envoyer en NOTICE)
    # Normaliser pour éviter les warnings "uninitialized" dans hist_key et logs
    my $chan_for_hist = $chan // '__private__';
    my $_out = sub {
        my ($text) = @_;
        if ($output_fn) { $output_fn->($text); }
        else            { Mediabot::Helpers::botPrivmsg($self, $chan, $text); }
    };

    # Config: anthropic.API_KEY required
    my $api_key = _chatgpt_conf_string($self, 'anthropic.API_KEY', '')
        or ($self->{logger}->log(0, 'claudeAI() anthropic.API_KEY missing'), return);

    my $api_url     = _chatgpt_conf_string($self, 'anthropic.API_URL',
                                            CLAUDE_API_URL);
    my $api_version = _chatgpt_conf_string($self, 'anthropic.API_VERSION',
                                            CLAUDE_API_VERSION);
    my $model       = _chatgpt_conf_string($self, 'anthropic.MODEL',
                                            CLAUDE_MODEL);
    my $max_tokens  = _chatgpt_conf_int($self, 'anthropic.MAX_TOKENS',
                                         CLAUDE_MAX_TOKENS, 1, 4000);
    # W6: temperature configurable (0.0 = deterministic, 1.0 = creative, default 1.0)
    my $temperature = do {
        my $t = eval { $self->{conf}->get('anthropic.TEMPERATURE') } // 1.0;
        $t < 0 ? 0.0 : $t > 1.0 ? 1.0 : $t + 0;  # clamp 0..1
    };
    my $max_privmsg = _chatgpt_conf_int($self, 'anthropic.MAX_PRIVMSG',
                                         CLAUDE_MAX_PRIVMSG, 1, 10);
    my $wrap_bytes  = _chatgpt_conf_int($self, 'anthropic.WRAP_BYTES',
                                         CLAUDE_WRAP_BYTES, 100, 480);
    my $sleep_us    = _chatgpt_conf_int($self, 'anthropic.SLEEP_US',
                                         CLAUDE_SLEEP_US, 0, 5_000_000);
    my $sys_prompt  = _chatgpt_conf_string($self, 'anthropic.SYSTEM_PROMPT',
                                            CLAUDE_SYSTEM_PROMPT);
    $sys_prompt =~ s/[\r\n]/ /g;
    $sys_prompt = substr($sys_prompt, 0, 800);
    # I2: per-nick persona overrides global system prompt
    my $persona_key = lc($nick) . "\x00" . (defined $chan ? $chan : '__private__');
    if (my $persona = $self->{_claude_persona}{$persona_key}) {
        $sys_prompt = $persona;
    }
    # mb163-B1: le bloc "DD1 prompt cache" qui se trouvait ici a ete supprime.
    #
    # Il lisait $self->{_claude_prompt_cache}{lc($prompt)} alors que le cache
    # F53 (dans _claude_send_and_parse) ecrit sous la cle
    # md5_hex(lc($prompt) ...) -> les formats ne matchaient jamais, le check
    # etait du code mort depuis son introduction.
    #
    # Il ne faut PAS le "reparer" en alignant les cles : ce bloc s'executait
    # AVANT le check chanset Claude et AVANT le rate limit per-nick, et ne
    # maintenait pas l'history (ni push user ni push assistant). Un cache-hit
    # ici aurait donc permis de faire repondre le bot sur un canal ou Claude
    # est desactive (chanset -Claude), de contourner le rate limit, et aurait
    # desynchronise l'historique de conversation.
    #
    # Le cache F53 dans _claude_send_and_parse fait deja ce travail au bon
    # endroit : apres le chanset check, apres le rate limit, et avec une
    # gestion correcte de l'history.

    # DD5: auto-reset persona if channel has been inactive > 1h
    if (defined $chan) {
        my $last_ai = $self->{_ai_last_active}{$persona_key} // 0;
        # IMP4: TTL configurable via anthropic.PERSONA_TTL_HOURS (default 1h)
        my $persona_ttl = do {
            my $h = eval { $self->{conf}->get('anthropic.PERSONA_TTL_HOURS') } // 1;
            int(($h || 1) * 3600);
        };
        if ($last_ai && (time() - $last_ai) > $persona_ttl) {
            delete $self->{_claude_persona}{$persona_key};
            $self->{logger}->log(3,
                "DD5: persona auto-reset for $persona_key (inactive " .
                int((time() - $last_ai)/60) . "min)");
        }
        $self->{_ai_last_active}{$persona_key} = time();
    }

    # X1: prepend pinned context to system prompt if set
    my $pin_key_x1 = lc($nick) . "\x00" . (defined $chan ? $chan : '__private__');
    if (my $pinned = $self->{_claude_pinned}{$pin_key_x1}) {
        $sys_prompt = "[Always remember: $pinned] $sys_prompt";
    }
    # A1: configurable history depth (in messages, must be even: user+assistant pairs)
    my $max_history = _chatgpt_conf_int($self, 'anthropic.MAX_HISTORY',
                                         CLAUDE_MAX_HISTORY, 2, 20);
    $max_history += 1 if $max_history % 2 != 0;  # ensure even number

    @args or (Mediabot::Helpers::botNotice($self, $nick, 'Syntax: ai <prompt>'), return);

    # opt-in check: chanset 'Claude' must be enabled on the channel
    # Skipped for Partyline (output_fn set — already authenticated operator)
    unless ($output_fn) {
        return unless Mediabot::External::_chanset_ok($self, $chan, 'Claude');
    }

    my $prompt = join ' ', @args;
    $self->{logger}->log(5, "claudeAI() prompt: $prompt");

    # R2: per-nick rate limiting — W2: configurable via anthropic.RATE_MAX / RATE_WINDOW
    unless ($output_fn) {  # skip rate limit for Partyline (already authenticated)
        my $rate_max    = eval { int($self->{conf}->get('anthropic.RATE_MAX')    // 5)  } // 5;
        my $rate_window = eval { int($self->{conf}->get('anthropic.RATE_WINDOW') // 60) } // 60;
        $rate_max    = 1   if $rate_max < 1;
        $rate_window = 10  if $rate_window < 10;
        my $rl_key = lc($nick) . "\x00" . ($chan // "__private__");  # CL1/fix: $chan may be undef in PM
        my $now    = time();
        $self->{_claude_ratelimit} //= {};
        my $rl = $self->{_claude_ratelimit}{$rl_key} //= { count => 0, window => $now };
        if ($now - $rl->{window} >= $rate_window) {
            $rl->{count}  = 0;
            $rl->{window} = $now;
        }
        if (++$rl->{count} > $rate_max) {
            my $wait = $rate_window - ($now - $rl->{window});
            Mediabot::Helpers::botNotice($self, $nick, "Rate limit: please wait ${wait}s before using !ai again.");
            $self->{metrics}->inc('mediabot_claude_ratelimit_total') if $self->{metrics};
            return;
        }
    }

    # P2: build conversation history (max 3 exchanges = 6 messages)
    my $hist_key  = "$nick\x00$chan_for_hist";
    my $history   = $self->{_claude_history}{$hist_key} //= [];
    push @$history, { role => 'user', content => $prompt };
    # Keep only last N messages (user+assistant pairs)
    splice @$history, 0, @$history - $max_history if @$history > $max_history;

    # mb87-R1: appel HTTP + parsing extraits dans _claude_send_and_parse
    # mb88-R3: passer output_fn pour que le chemin cache-hit l'utilise aussi
    my $answer = _claude_send_and_parse($self, {
        api_url     => $api_url,
        api_key     => $api_key,
        api_version => $api_version,
        model       => $model,
        max_tokens  => $max_tokens,
        temperature => $temperature,
        sys_prompt  => $sys_prompt,
        history     => $history,
        prompt      => $prompt,
        prompt_key  => do {
            require Digest::MD5;
            # mb163-B2: inclure le system prompt EFFECTIF (qui contient le
            # persona override et le pin context prepend) dans la cle de
            # cache. Avant ce fix, la cle etait md5(lc(prompt)) seule :
            # si Alice (persona pirate, pin "my pet is Talos") posait une
            # question, sa reponse personnalisee etait cachee 60s et servie
            # telle quelle a Bob posant la meme question — reponse dans le
            # mauvais style ET fuite possible du contenu du pin d'Alice.
            # Deux users ne partagent desormais un cache-hit que s'ils ont
            # le MEME system prompt effectif (cas typique : aucun des deux
            # n'a de persona/pin -> dedup utile preservee).
            Digest::MD5::md5_hex(encode('UTF-8',
                lc($prompt // '') . "\x00" . ($sys_prompt // '')));
        },
        wrap_bytes  => $wrap_bytes,
        max_privmsg => $max_privmsg,
        max_history => $max_history,
        nick        => $nick,
        chan         => $chan,
        output_fn   => $output_fn,  # mb88-R3: nécessaire pour cache-hit via callback
    });

    # mb141-B2: if the API call failed before an assistant answer was appended,
    # rollback the user message we just pushed. Cache hits append an assistant
    # internally before returning undef, so the last role tells both cases apart.
    if (!defined $answer
        && ref($history) eq 'ARRAY'
        && @$history
        && ($history->[-1]{role} // '') eq 'user')
    {
        pop @$history;
        $self->{logger}->log(4,
            "claudeAI() rollback orphan user msg in history (key=$hist_key)");
    }
    return unless defined $answer;

    # P2: optionally prefix response with model name
    my $show_model = _chatgpt_conf_int($self, 'anthropic.SHOW_MODEL', 0, 0, 1);
    if ($show_model) {
        my $model_short = $model =~ s/claude-//r =~ s/-\d{8,}//r;
        $answer = "[$model_short] $answer";
    }

    # Sanitise and wrap — reuse _chatgpt_wrap
    $answer =~ s/[\r\n]+/ /g;
    $answer =~ s/\s{2,}/ /g;

    my @chunk    = _chatgpt_wrap($answer, $wrap_bytes);
    my $truncate = @chunk > $max_privmsg;
    my $last     = $truncate ? $max_privmsg - 1 : $#chunk;

    if ($truncate) {
        my $suff  = CLAUDE_TRUNC_MSG;
        my $allow = $wrap_bytes - length($suff);
        if (length($chunk[$last]) > $allow) {
            $chunk[$last] = substr($chunk[$last], 0, $allow);
            $chunk[$last] =~ s/\s+\S*$//;
            $chunk[$last] =~ s/\s+$//;
        }
        $chunk[$last] .= $suff;
    }

    if ($output_fn) {
        # Partyline callbacks are already non-IRC and must remain synchronous.
        for my $i (0 .. $last) {
            $_out->($chunk[$i]);
        }
        $self->{logger}->log(4, 'claudeAI() sent ' . ($last+1) . ' callback line(s)');
    }
    else {
        my @out_chunks = @chunk[0 .. $last];
        my $queued = _queue_irc_chunks(
            $self,
            $chan,
            \@out_chunks,
            $sleep_us,
            'claudeAI',
        );
        $self->{logger}->log(4, "claudeAI() queued $queued PRIVMSG");
    }
    # P5: increment Prometheus counter on success
    $self->{metrics}->inc('mediabot_claude_requests_total') if $self->{metrics};
}

# ---------------------------------------------------------------------------
# mb87-R1: _claude_send_and_parse — extrait de claudeAI() pour lisibilité
# Gère le cache prompt, l'appel HTTP Anthropic et le parsing de la réponse.
# Retourne la réponse texte ou undef en cas d'erreur.
# ---------------------------------------------------------------------------
sub _claude_send_and_parse {
    my ($self, $p) = @_;
    my ($api_url, $api_key, $api_version, $model, $max_tokens, $temperature,
        $sys_prompt, $history, $prompt, $prompt_key, $wrap_bytes, $max_privmsg,
        $max_history, $nick, $chan, $output_fn) =
        @{$p}{qw(api_url api_key api_version model max_tokens temperature
                  sys_prompt history prompt prompt_key wrap_bytes max_privmsg
                  max_history nick chan output_fn)};

    # mb88-R3: _out utilise output_fn si disponible, sinon Mediabot::Helpers::botPrivmsg/Mediabot::Helpers::botNotice
    my $_out_sub = sub {
        my ($text) = @_;
        if ($output_fn) { $output_fn->($text); }
        elsif (defined $chan) { Mediabot::Helpers::botPrivmsg($self, $chan, $text); }
        else                  { Mediabot::Helpers::botNotice($self, $nick, $text); }
    };

    # F53: prompt cache — same exact prompt answered within 60s → skip API
    my $pcache = $self->{_claude_prompt_cache}{$prompt_key};
    if ($pcache && (time() - $pcache->{ts}) < 60) {
        $self->{logger}->log(4, 'claudeAI() prompt cache hit');
        my @chunk = _chatgpt_wrap($pcache->{answer}, $wrap_bytes);
        my $last  = @chunk > $max_privmsg ? $max_privmsg - 1 : $#chunk;
        $_out_sub->($chunk[$_]) for 0..$last;
        push @$history, { role => 'assistant', content => $pcache->{answer} };
        splice @$history, 0, @$history - $max_history if @$history > $max_history;
        return undef;  # already sent, caller should not re-send
    }

    # Anthropic API payload
    my $payload = eval { encode_json({
        model       => $model,
        max_tokens  => $max_tokens,
        temperature => $temperature + 0,
        system      => $sys_prompt,
        messages    => $history,
    }) };
    unless ($payload) {
        $self->{logger}->log(1, "claudeAI() payload encode error: $@");
        $_out_sub->("($nick) Internal error building request.");
        return undef;
    }

    # AA8/V14: log model + history size
    my $_h = scalar @$history;
    my $_c = 0; $_c += length($_->{content}//'') for @$history;
    my $_log_chan = $p->{chan} // "__private__";
    $self->{logger}->log(3, "claudeAI() \x{2192} $model for $_log_chan / $nick [hist: $_h msg(s), ~$_c chars]");

    my $http = Mediabot::External::_make_http(timeout => 30);
    my $res  = eval {
        $http->request('POST', $api_url, {
            headers => {
                'Content-Type'      => 'application/json',
                'x-api-key'         => $api_key,
                'anthropic-version' => $api_version,
            },
            content => $payload,
        });
    } // { success => 0, status => 0, reason => $@ };

    unless ($res->{success}) {
        $self->{logger}->log(1,
            'claudeAI() HTTP error: ' . ($res->{status}//0)
            . ' ' . ($res->{reason}//'') . " model=$model");
        $self->{metrics}->inc('mediabot_claude_errors_total') if $self->{metrics};
        $_out_sub->("($nick) Sorry, Claude did not answer.");
        return undef;
    }

    my $data   = eval { decode_json($res->{content} // '') };
    my $answer = eval {
        ref($data)                       eq 'HASH'  &&
        ref($data->{content})            eq 'ARRAY' &&
        ref($data->{content}[0])         eq 'HASH'  &&
        $data->{content}[0]{type}        eq 'text'  &&
        length($data->{content}[0]{text} // '') > 0
        ? $data->{content}[0]{text} : undef
    };

    unless (defined $answer && $answer ne '') {
        $self->{logger}->log(1, 'claudeAI() unexpected response structure');
        $self->{logger}->log(5, 'claudeAI() raw: ' . ($res->{content} // '(empty)'));
        $_out_sub->("($nick) Could not read Claude response.");
        return undef;
    }
    $self->{logger}->log(5, "claudeAI() raw answer: $answer");

    # P2: store assistant reply in history
    push @$history, { role => 'assistant', content => $answer };
    # F53: cache this prompt→answer pair (TTL 60s)
    $self->{_claude_prompt_cache}{$prompt_key} = { ts => time(), answer => $answer };
    # Evict entries older than 120s
    for my $k (keys %{ $self->{_claude_prompt_cache} // {} }) {
        delete $self->{_claude_prompt_cache}{$k}
            if (time() - ($self->{_claude_prompt_cache}{$k}{ts} // 0)) > 120;
    }
    splice @$history, 0, @$history - $max_history if @$history > $max_history;

    return $answer;
}

1;
