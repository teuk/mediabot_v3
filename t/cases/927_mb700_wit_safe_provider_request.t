# t/cases/927_mb700_wit_safe_provider_request.t
# =============================================================================
# MB700-E — minimal safe provider-neutral AI::Request for future +Wit.
#
# This round builds a request only. It never constructs AI::Client, performs
# HTTP, touches DB/chansets, calls a provider or emits IRC.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationRequest qw(
    wit_request_defaults
    build_wit_request
    wit_request_summary
);
use Mediabot::AI::Request qw(validate_request request_summary);

return sub {
    my ($assert) = @_;

    my $defaults = wit_request_defaults();
    $assert->is($defaults->{max_input_chars}, 800,
        'mb700-927: Wit request keeps the policy input ceiling');
    $assert->is($defaults->{max_output_tokens}, 120,
        'mb700-927: Wit request uses a small output token budget');
    $assert->is($defaults->{temperature}, 0.7,
        'mb700-927: Wit request uses a moderate fixed temperature');
    $assert->is($defaults->{timeout_seconds}, 20,
        'mb700-927: Wit request uses a bounded timeout');

    my $r = build_wit_request(
        provider => 'auto',
        language => 'fr',
        message  => 'Salut tout le monde 👋',
    );

    $assert->is($r->{provider}, 'auto',
        'mb700-927: provider-neutral auto is preserved');
    $assert->is($r->{purpose}, 'wit',
        'mb700-927: request purpose is dedicated to Wit');
    $assert->ok(!exists($r->{model}),
        'mb700-927: auto Wit request never pins a provider-specific model');
    $assert->is(scalar(@{ $r->{messages} }), 1,
        'mb700-927: initial Wit request contains one minimal user message');
    $assert->is($r->{messages}[0]{role}, 'user',
        'mb700-927: channel line is represented as user content');
    $assert->is($r->{messages}[0]{content}, 'Salut tout le monde 👋',
        'mb700-927: printable Unicode channel text is preserved');
    $assert->is($r->{max_output_tokens}, 120,
        'mb700-927: output token budget is fixed by the builder');
    $assert->is($r->{temperature}, 0.7,
        'mb700-927: caller cannot silently inflate creativity');
    $assert->is($r->{timeout_seconds}, 20,
        'mb700-927: caller cannot silently inflate timeout');
    $assert->ok(!defined(validate_request($r)),
        'mb700-927: constructed Wit request satisfies AI::Request contract');

    $assert->like($r->{system}, qr/NO_REPLY/,
        'mb700-927: system prompt embeds explicit NO_REPLY contract');
    $assert->like($r->{system}, qr/REPLY: <single-line reply>/,
        'mb700-927: system prompt embeds explicit REPLY wire contract');
    $assert->like($r->{system}, qr/write naturally in French/i,
        'mb700-927: request follows the channel language');
    $assert->like($r->{system}, qr/often preferable to choose NO_REPLY/i,
        'mb700-927: abstention is encouraged as a normal outcome');
    $assert->like($r->{system}, qr/friendly, witty and non-aggressive/i,
        'mb700-927: desired social tone is explicit and non-aggressive');
    $assert->like($r->{system}, qr/untrusted channel text/i,
        'mb700-927: prompt injection boundary marks channel content untrusted');
    $assert->like($r->{system}, qr/sensitive personal traits/i,
        'mb700-927: sensitive profiling is prohibited');
    $assert->like($r->{system}, qr/secrets, credentials or private data/i,
        'mb700-927: secret/private-data handling is prohibited');
    $assert->like($r->{system}, qr/privileged moderation, administration or system actions/i,
        'mb700-927: privilege-bearing actions are prohibited');
    $assert->like($r->{system}, qr/at most 280 characters/i,
        'mb700-927: prompt matches the parser reply ceiling');

    my $openai = build_wit_request(
        provider => 'GPT', language => 'en', message => 'Hello',
    );
    $assert->is($openai->{provider}, 'openai',
        'mb700-927: OpenAI aliases normalize centrally');

    my $anthropic = build_wit_request(
        provider => 'Claude', language => 'es', message => 'Hola',
    );
    $assert->is($anthropic->{provider}, 'anthropic',
        'mb700-927: Anthropic aliases normalize centrally');
    $assert->like($anthropic->{system}, qr/write naturally in Spanish/i,
        'mb700-927: Spanish channel policy reaches provider request');

    my $fallback = build_wit_request(
        language => 'xx', message => 'Hello',
    );
    $assert->like($fallback->{system}, qr/write naturally in English/i,
        'mb700-927: unsupported language fails safely to English');

    my $formatted = build_wit_request(
        message => "  \x02Hello\x02   \x0304world\x0f 👋  ",
    );
    $assert->is($formatted->{messages}[0]{content}, 'Hello world 👋',
        'mb700-927: IRC presentation controls are removed from provider input');

    for my $bad (
        [ nick       => 'Alice' ],
        [ channel    => '#test' ],
        [ model      => 'gpt-anything' ],
        [ system     => 'caller override' ],
        [ messages   => [] ],
        [ api_key    => 'must-never-enter-request' ],
        [ prompt     => 'caller override' ],
        [ memory     => 'profile blob' ],
    ) {
        my ($key, $value) = @$bad;
        my $ok = eval {
            build_wit_request(message => 'hello', $key => $value);
            1;
        };
        $assert->ok(!$ok,
            "mb700-927: builder rejects caller field $key");
        $assert->like($@, qr/unknown Wit request field: \Q$key\E/,
            "mb700-927: rejected $key is machine-visible");
    }

    for my $bad_message (
        undef,
        [],
        '',
        "   ",
        "hello\nworld",
        "hello\rworld",
        "hello\x00world",
        ('x' x 801),
    ) {
        my $ok = eval {
            build_wit_request(message => $bad_message);
            1;
        };
        $assert->ok(!$ok,
            'mb700-927: invalid/oversized channel content fails closed');
    }

    my $safe = wit_request_summary($r, language => 'fr');
    $assert->is($safe->{provider}, 'auto',
        'mb700-927: safe summary carries provider');
    $assert->is($safe->{purpose}, 'wit',
        'mb700-927: safe summary carries purpose');
    $assert->is($safe->{language}, 'fr',
        'mb700-927: safe summary carries normalized language');
    $assert->is($safe->{messages}, 1,
        'mb700-927: safe summary exposes count only');
    $assert->ok($safe->{chars} > 0,
        'mb700-927: safe summary exposes aggregate size only');
    $assert->unlike(join(' ', map { defined($_) ? $_ : '' } values %$safe),
        qr/Salut tout le monde|NO_REPLY|REPLY:/,
        'mb700-927: safe summary never exposes message or system prompt content');

    my $generic = request_summary($r);
    $assert->unlike(join(' ', map { defined($_) ? $_ : '' } values %$generic),
        qr/Salut tout le monde|sensitive personal traits/i,
        'mb700-927: base AI request summary remains content-free');

    my $src = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../Mediabot/AI/ConversationRequest.pm" or die $!;
        local $/; <$fh>;
    };
    $assert->unlike($src, qr/AI::Client|Provider::Anthropic|Provider::OpenAI|HTTP::|DBI\b|CHANNEL_SET|CHANSET_LIST|botPrivmsg|botNotice|botAction/,
        'mb700-927: request builder owns no client execution, provider transport, DB or IRC');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl" or die $!;
        local $/; <$fh>;
    };
    $assert->unlike($main, qr/use Mediabot::AI::ConversationRequest/,
        'mb700-927: MB700-E request builder is not wired into runtime yet');
};
