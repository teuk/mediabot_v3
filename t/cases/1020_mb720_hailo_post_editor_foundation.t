# MB720-B — provider-neutral, language-aware Hailo post-editor foundation.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::Hailo::Language qw(
    detect_phrase_language
    resolve_hailo_language
);
use Mediabot::Hailo::PostEditor;

{
    package MB720::Client;
    sub new { bless { result => $_[1], requests => [] }, $_[0] }
    sub submit {
        my ($self, $request, %args) = @_;
        push @{ $self->{requests} }, $request;
        $args{on_done}->($self->{result});
        return 1;
    }
}

sub _run_editor_1020 {
    my (%args) = @_;
    my $client = MB720::Client->new(delete $args{result});
    my $editor = Mediabot::Hailo::PostEditor->new(client => $client);
    my $decision;
    my $submitted = $editor->submit(
        %args,
        on_done => sub { $decision = $_[0] },
    );
    return ($submitted, $decision, $client->{requests}[0]);
}

return sub {
    my ($assert) = @_;

    $assert->is(detect_phrase_language('tu es avec moi, pourquoi pas ?'), 'fr',
        'French phrase markers are detected');
    $assert->is(detect_phrase_language('you are with me and this is fine'), 'en',
        'English phrase markers are detected');
    $assert->is(detect_phrase_language('¿por qué no estás con tu amigo?'), 'es',
        'Spanish phrase markers and punctuation are detected');
    $assert->ok(!defined detect_phrase_language('pizza 42'),
        'ambiguous short text remains undetected');

    my $code_switch = resolve_hailo_language(
        channel_language => 'fr',
        trigger          => 'you are with me and this is fine',
        candidate        => 'moi aller au marché demain',
    );
    $assert->is($code_switch->{language}, 'en',
        'confident trigger language wins for a channel code-switch');

    my ($submitted, $edited, $request) = _run_editor_1020(
        result => {
            ok       => 1,
            answer   => 'Moi, je vais au marché demain.',
            provider => 'anthropic',
        },
        provider         => 'auto',
        channel_language => 'fr',
        context          => [ 'Il fera beau demain.', 'Tu as besoin de pain.' ],
        trigger          => 'tu vas au marché demain ?',
        candidate        => 'moi aller au marché demain',
    );
    $assert->ok($submitted, 'post-editor submits through the injected common client');
    $assert->is($edited->{reason}, 'edited',
        'bounded grammar repair is accepted');
    $assert->is($edited->{line}, 'Moi, je vais au marché demain.',
        'accepted edit becomes the public candidate');
    $assert->is($edited->{provider}, 'anthropic',
        'safe provider metadata is preserved');
    $assert->is($request->{purpose}, 'hailo.post_edit',
        'provider-neutral request has a dedicated purpose');
    $assert->is($request->{timeout_seconds}, 5,
        'provider request has a short explicit deadline');
    $assert->like($request->{system}, qr/Hailo draft is the creative source/,
        'system prompt makes the learned draft the immutable creative anchor');
    $assert->like($request->{system}, qr/exactly one plain IRC-safe line/,
        'system prompt requires one IRC-safe line');

    my (undef, $rejected) = _run_editor_1020(
        result => { ok => 1, answer => 'Bien sûr, voici une réponse très utile et entièrement nouvelle.' },
        channel_language => 'fr',
        context          => [],
        trigger          => 'tu vas au marché demain ?',
        candidate        => 'moi aller au marché demain',
    );
    $assert->is($rejected->{reason}, 'anchor_rejected',
        'generic rewrite with no learned lexical anchor is rejected');
    $assert->is($rejected->{line}, 'moi aller au marché demain',
        'anchor rejection falls back to the original Hailo candidate');

    my (undef, $multiline) = _run_editor_1020(
        result => { ok => 1, answer => "Moi, je vais au marché.\nDeuxième ligne." },
        channel_language => 'fr',
        trigger          => 'tu vas au marché demain ?',
        candidate        => 'moi aller au marché demain',
    );
    $assert->is($multiline->{reason}, 'invalid_output',
        'multi-line provider output is rejected');
    $assert->is($multiline->{line}, 'moi aller au marché demain',
        'invalid output falls back to the original Hailo candidate');

    my (undef, $failed) = _run_editor_1020(
        result => { ok => 0, error => 'timeout' },
        channel_language => 'fr',
        trigger          => 'tu vas au marché demain ?',
        candidate        => 'moi aller au marché demain',
    );
    $assert->is($failed->{reason}, 'provider_error',
        'provider failure is normalized without a public error');
    $assert->is($failed->{line}, 'moi aller au marché demain',
        'provider failure preserves the Hailo reply');

    my (undef, $unchanged) = _run_editor_1020(
        result => { ok => 1, answer => 'moi aller au marché demain' },
        channel_language => 'fr',
        trigger          => 'tu vas au marché demain ?',
        candidate        => 'moi aller au marché demain',
    );
    $assert->is($unchanged->{reason}, 'unchanged',
        'provider may explicitly keep an already suitable draft');
    $assert->ok(!$unchanged->{edited},
        'unchanged draft is not counted as an edit');
};
