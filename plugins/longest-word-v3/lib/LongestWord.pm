package Mediabot::Plugin::LongestWord;

use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode);
use JSON::PP ();
use Scalar::Util qw(refaddr);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

BEGIN {
    require Cwd;
    my $engine = Cwd::abs_path(__FILE__);
    $engine =~ s{[^/]+\z}{Engine.pm};
    require $engine;
    $engine =~ s{Engine.pm\z}{Scores.pm};
    require $engine;
}

sub new {
    my ($class, %args) = @_;
    return bless { context => $args{context}, games => {}, cooldown => {},
        wall_clock => $args{wall_clock} || sub { time() },
        serial => 0,
        clock => $args{clock} || sub { clock_gettime(CLOCK_MONOTONIC) },
        random => $args{random} || sub { rand($_[0]) } }, $class;
}
sub start { $_[0]{started} = 1; 1 }
sub stop { $_[0]{started} = 0; $_[0]{games} = {}; $_[0]{cooldown} = {}; 1 }
sub policy_changed {
    my ($self, %args) = @_;
    my $key = Mediabot::Plugin::LongestWord::Engine::fold($args{channel});
    delete $self->{games}{$key};
    delete $self->{cooldown}{$key};
    return 1;
}

sub _bounded {
    my ($text, $max) = @_;
    $max //= 385;
    $text =~ s/[\x00-\x1f\x7f]//g;
    chop $text while length(encode('UTF-8', $text)) > $max;
    return $text;
}
sub _say {
    my ($self, $context, $inv, $text) = @_;
    $text = _bounded('[Mot le plus long] ' . $text);
    return $inv->can('_emit_channel_message')
        ? $context->channel_message($inv, $text) : $context->reply($inv, $text);
}
sub _notice {
    my ($self, $context, $inv, $text) = @_;
    return $context->notice($inv, _bounded($text));
}
sub _identity {
    my ($inv) = @_;
    my $principal = $inv->principal;
    return 'u.' . $principal->user_id if $principal->authenticated;
    return 'n.' . Mediabot::Plugin::LongestWord::Engine::fold($inv->nick);
}
sub _nick { _bounded($_[0], 32) }

sub _rack {
    my ($self, $length, $vowels) = @_;
    my $v = 'AAAAAAAEEEEEEEEEEEEEEEIIIIIIIIOOOOOOUUUUUUY';
    my $c = 'BBCCDDDFFGGHHJKLLLLLMMMNNNNNNPPQRRRRRRSSSSSSTTTTTTVVWXZ';
    my @letters;
    for (1 .. $length) {
        my $pool = $_ <= $vowels ? $v : $c;
        push @letters, substr($pool, int($self->{random}->(length $pool)), 1);
    }
    for (my $i = $#letters; $i > 0; $i--) {
        my $j = int($self->{random}->($i + 1));
        @letters[$i,$j] = @letters[$j,$i];
    }
    return join '', @letters;
}

sub _prepare {
    my ($self, $context, $inv, $game, $attempt) = @_;
    $attempt //= 0;
    my $key = $game->{channel};
    my $engine = $game->{engine};
    $engine->{phase} = 'preparing';
    $game->{preparing_at} = $self->{clock}->();
    my $rack = $self->_rack($game->{letters}, $game->{vowels});
    my $token = ++$game->{request};
    my $handled = 0;
    my $accepted = $context->dictionary_solve($inv, $rack, sub {
        my ($result) = @_;
        $handled = 1;
        return unless $self->{started} && $inv->output_allowed
            && $self->{games}{$key} && refaddr($self->{games}{$key}) == refaddr($game)
            && $game->{request} == $token && $engine->{phase} eq 'preparing';
        unless ($result && $result->{ok}) {
            delete $self->{games}{$key};
            return $self->_say($context, $inv,
                'Dictionnaire indisponible ou occupé. Partie annulée, aucun point ajouté pour cette manche.');
        }
        if ($result->{longest} < 5) {
            return $self->_prepare($context, $inv, $game, $attempt + 1) if $attempt < 5;
            delete $self->{games}{$key};
            return $self->_say($context, $inv, 'Aucun tirage assez intéressant trouvé. Réessaie dans un instant.');
        }
        $engine->begin_round(words => $result->{words}, letters => $rack, now => $self->{clock}->());
        $game->{round_end_epoch} = $self->{wall_clock}->() + $engine->{duration};
        $game->{warned} = 0;
        my $sent = $self->_say($context, $inv, sprintf(
            'Manche %d/%d : %s — Mot le plus long : %d lettres — %ds. Écris ton mot dans le salon. Il doit dépasser le meilleur déjà accepté sur cette manche.',
            $engine->{round}, $engine->{rounds}, join(' ', split //, $rack), $engine->{longest}, $engine->{duration}));
        delete $self->{games}{$key} unless $sent;
    });
    unless ($handled || ($accepted && $accepted->{accepted})) {
        delete $self->{games}{$key};
        $self->_say($context, $inv, 'La recherche ne peut pas démarrer. Partie annulée.');
    }
    return 1;
}

sub _ranking_text {
    my ($rows, $limit) = @_;
    return 'aucun point marqué' unless @$rows;
    my @shown = @$rows;
    splice @shown, $limit if @shown > $limit;
    return join(' | ', map { _nick($_->{nick}) . ' ' . $_->{score} . ' pts' } @shown);
}

sub _record_scope {
    my ($inv) = @_;
    return Mediabot::Plugin::LongestWord::Engine::fold($inv->channel) . '|'
        . join(',', map { $inv->config_value($_) // { letters => 10, vowels => 4, round_seconds => 50, rounds => 5, top_bonus => 3 }->{$_} }
            qw(letters vowels round_seconds rounds top_bonus));
}

sub _hall_key { 'hall.' . substr(sha256_hex(encode('UTF-8', $_[0])), 0, 40) }
sub _hall {
    my ($self, $context, $inv, $channel) = @_;
    my $snapshot = $context->storage_snapshot($inv);
    die "dictionary_storage\n" if !$snapshot || $snapshot->{error};
    my $raw = $snapshot->{values}{_hall_key($channel)};
    my $doc = defined($raw) ? JSON::PP->new->decode($raw)
        : { v => 1, channel => $channel, entries => [] };
    die "dictionary_storage\n" unless ref($doc) eq 'HASH' && ($doc->{v} // 0) == 1
        && ($doc->{channel} // '') eq $channel && ref($doc->{entries}) eq 'ARRAY'
        && @{ $doc->{entries} } <= 10;
    for my $row (@{ $doc->{entries} }) {
        die "dictionary_storage\n" unless ref($row) eq 'ARRAY' && @$row == 5
            && !grep { !defined($_) || ref($_) } @$row;
        die "dictionary_storage\n" unless length($row->[0]) <= 80 && length($row->[1]) <= 32
            && $row->[2] =~ /\A[0-9]{1,5}\z/ && $row->[3] =~ /\A[0-9]{1,2}\z/
            && $row->[4] =~ /\A[A-Z]{2,12}\z/;
    }
    return ($snapshot, $doc);
}

sub _save_records {
    my ($self, $context, $inv, $game) = @_;
    my $rank = $game->{engine}->ranking;
    return 1 unless @$rank;
    for (1 .. 2) {
        my ($snapshot, $doc) = $self->_hall($context, $inv, $game->{record_scope});
        my %best = map { $_->[0] => [ @$_ ] } @{ $doc->{entries} };
        for my $player (@$rank) {
            my $old = $best{$player->{id}};
            next if $old && $old->[2] >= $player->{score};
            $best{$player->{id}} = [ $player->{id}, _nick($player->{nick}),
                $player->{score}, $player->{tops}, $player->{best} ];
        }
        my @records = sort { $b->[2] <=> $a->[2] || $b->[3] <=> $a->[3] || $a->[0] cmp $b->[0] } values %best;
        splice @records, 10 if @records > 10;
        $doc->{entries} = \@records;
        my $json = JSON::PP->new->canonical;
        my $value = $json->encode($doc);
        while (length(encode('UTF-8', $value)) > 2048 && @records) {
            pop @records; $value = $json->encode($doc);
        }
        my $result = $context->storage_commit($inv,
            expected_revision => $snapshot->{revision},
            changes => { _hall_key($game->{record_scope}) => $value });
        return 1 if $result && $result->{ok};
        return 0 unless $result && ($result->{error} // '') eq 'conflict';
    }
    return 0;
}

sub _score_snapshot {
    my ($self, $context, $inv) = @_;
    my $snapshot = $context->channel_storage_snapshot($inv);
    die "word_score_storage\n" unless $snapshot && !$snapshot->{error};
    return $snapshot;
}
sub _save_round {
    my ($self, $context, $inv, $game) = @_;
    my $pending = $game->{pending_score} or return 1;
    for (1 .. 3) {
        my $snapshot = $self->_score_snapshot($context, $inv);
        my $changes = Mediabot::Plugin::LongestWord::Scores::changes($snapshot,
            %$pending, scope => $game->{record_scope}, game => $game->{id});
        return 1 unless keys %$changes;
        my $result = $context->channel_storage_commit($inv,
            expected_revision => $snapshot->{revision}, changes => $changes);
        return 1 if $result && $result->{ok};
        return 0 unless $result && ($result->{error} // '') eq 'conflict';
    }
    return 0;
}
sub _after_saved_round {
    my ($self, $context, $inv, $game) = @_;
    delete $game->{pending_score}; delete $game->{save_warned};
    if ($game->{engine}{phase} eq 'done') {
        delete $self->{games}{$game->{channel}};
        $self->{cooldown}{$game->{channel}} = $self->{clock}->() + 20;
        my $saved = eval { $self->_save_records($context, $inv, $game) };
        return $self->_say($context, $inv, 'Partie terminée. Cumuls sauvegardés : !motlong top total / top semaine. '
            . ($saved ? 'Records : !motlong records.' : 'Le record de partie n’a pas pu être sauvegardé.'));
    }
    return $self->_prepare($context, $inv, $game) if delete $game->{next_immediate};
    $game->{next_at} = $self->{clock}->() + 8;
    return 1;
}
sub _persistent_scores {
    my ($self, $context, $inv, $op, $args) = @_;
    my $zone = $inv->config_value('score_timezone') // 'Europe/Paris';
    my $epoch = $self->{wall_clock}->();
    my $week = eval { Mediabot::Plugin::LongestWord::Scores::week($epoch, $zone) };
    return $self->_notice($context, $inv, 'Le fuseau des scores est invalide.') unless $week;
    my $scope = _record_scope($inv);
    my $snapshot = eval { $self->_score_snapshot($context, $inv) };
    return $self->_notice($context, $inv, 'Les scores persistants sont indisponibles.') unless $snapshot;
    if ($op eq 'score') {
        return $self->_notice($context, $inv, 'Utilise !motlong score pour tes cumuls.') if @$args > 1;
        my $key = Mediabot::Plugin::LongestWord::Scores::player_key($scope, _identity($inv));
        my $row = eval { exists($snapshot->{values}{$key})
            ? Mediabot::Plugin::LongestWord::Scores::decode_player($snapshot->{values}{$key}) : undef };
        return $self->_notice($context, $inv, 'Tes scores sont indisponibles.') if $@;
        return $self->_notice($context, $inv, 'Tes scores sont indisponibles.')
            if $row && ($row->{id} ne _identity($inv) || $row->{scope} ne $scope);
        my $game = $self->{games}{Mediabot::Plugin::LongestWord::Engine::fold($inv->channel)};
        my $current = $game ? $game->{engine}{players}{_identity($inv)} : undef;
        return $self->_notice($context, $inv, 'Total : ' . ($row ? $row->{total} : 0)
            . ' pts | Semaine ' . $week . ' (' . $zone . ') : ' . ($row ? $row->{weeks}{$week} // 0 : 0)
            . ' pts' . ($current ? ' | Partie : ' . $current->{score} . ' pts' : '') . '.');
    }
    my @rest = @$args; shift @rest;
    my $period = @rest ? lc shift @rest : 'total';
    return $self->_notice($context, $inv, 'Utilise !motlong top total [page] ou top semaine [AAAA-Wss] [page].')
        unless $period eq 'total' || $period eq 'semaine';
    my $chosen;
    if ($period eq 'semaine') {
        $chosen = @rest && $rest[0] =~ /-W/i ? uc shift @rest : $week;
        return $self->_notice($context, $inv, 'Semaine invalide ou hors des 52 semaines disponibles.')
            unless Mediabot::Plugin::LongestWord::Scores::valid_week($chosen, $epoch, $zone);
    }
    my $page = @rest ? shift @rest : 1;
    return $self->_notice($context, $inv, 'Page invalide.') unless !@rest && $page =~ /\A[1-9][0-9]{0,2}\z/;
    my $rows = eval { Mediabot::Plugin::LongestWord::Scores::rows($snapshot, $scope, $chosen) };
    return $self->_notice($context, $inv, 'Les scores sont indisponibles.') unless $rows;
    my $pages = int((@$rows + 4) / 5) || 1;
    return $self->_notice($context, $inv, 'Page inexistante. Dernière page : ' . $pages . '.') if $page > $pages;
    my @shown = @$rows; splice @shown, 0, ($page - 1) * 5; splice @shown, 5 if @shown > 5;
    my $text = @shown ? join(' | ', map {
        $_->{rank} . '. ' . _bounded(_nick($_->{nick}), 20) . ' ' . $_->{score} . ' pts'
    } @shown) : 'aucun point marqué';
    return $self->_say($context, $inv, ($chosen ? 'Semaine ' . $chosen . ' (' . $zone . ')' : 'Total')
        . ' — ' . $page . '/' . $pages . ' : ' . $text . '.');
}
sub _submit_word {
    my ($self, $context, $inv, $game, $word, $plain) = @_;
    return unless $game && !$game->{pending_score} && $game->{engine}{phase} eq 'playing';
    my $engine = $game->{engine}; my $now = $self->{clock}->();
    return if $plain && ($now >= $engine->{deadline}
        || !defined(Mediabot::Plugin::LongestWord::Engine::normalize($word)));
    # Ordinary chat words that do not solve this rack stay completely silent.
    return if $plain && !$engine->{words}{Mediabot::Plugin::LongestWord::Engine::normalize($word)};
    my $id = _identity($inv);
    return if ($game->{attempts}{$id} // -100) + 1 > $now;
    if (!exists($game->{attempts}{$id}) && keys(%{$game->{attempts}}) >= 128) {
        return $self->_notice($context, $inv, 'Limite de participants atteinte pour cette partie.') unless $plain;
        return;
    }
    $game->{attempts}{$id} = $now;
    my $result = $engine->submit(id => $id, nick => _nick($inv->nick), word => $word, now => $now);
    if (($result->{error} // '') eq 'not_longer') {
        return $self->_notice($context, $inv, 'Non retenu : ' . $result->{word}
            . '. Il faut au moins ' . $result->{minimum} . ' lettres pour dépasser le meilleur accepté sur cette manche.');
    }
    my %error = (closed => 'Temps écoulé.', invalid => 'Mot absent du dictionnaire ou lettres incompatibles avec le tirage.',
        full => 'Cette partie accueille au maximum 32 joueurs.');
    return if $plain && !$result->{ok};
    return $self->_notice($context, $inv, $error{$result->{error}} // 'Proposition refusée.') unless $result->{ok};
    if (length($result->{word}) == $engine->{longest}) {
        $game->{round_end_epoch} = $self->{wall_clock}->();
        $self->_say($context, $inv, _nick($inv->nick) . ' : ' . $result->{word}
            . ' retenu (' . $engine->{longest} . ' lettres). Mot le plus long trouvé ! '
            . $engine->{longest} . ' points + ' . $engine->{bonus} . ' de bonus = '
            . $result->{points} . ' points. Manche remportée !');
        return $self->_advance($context, $inv, $game);
    }
    return $self->_say($context, $inv, _nick($inv->nick) . ' : ' . $result->{word}
        . ' retenu (' . length($result->{word}) . ' lettres). Le prochain mot doit faire au moins ' . ($engine->{round_best_length} + 1)
        . ' lettres. Score attribué en fin de manche.');
}
sub event_word {
    my ($self, $context, $event, $inv) = @_;
    return unless $self->{started} && $event->activation_mode eq 'on' && $inv && $inv->output_allowed;
    my $key = Mediabot::Plugin::LongestWord::Engine::fold($inv->channel);
    my $game = $self->{games}{$key} or return;
    my $received = $inv->observed_at;
    return unless defined($received) && $game->{engine}{phase} eq 'playing'
        && $received >= $game->{engine}{opened_at} && $received < $game->{engine}{deadline}
        && (!defined($game->{previous_closed_at}) || $received > $game->{previous_closed_at});
    return $self->_submit_word($context, $inv, $game, $event->get('word'), 1);
}

sub _advance {
    my ($self, $context, $inv, $game) = @_;
    my $engine = $game->{engine};
    my $now = $self->{clock}->();
    if ($game->{pending_score}) {
        if (eval { $self->_save_round($context, $inv, $game) }) {
            return $self->_after_saved_round($context, $inv, $game);
        }
        unless ($game->{save_warned}++) {
            $self->_say($context, $inv, 'Sauvegarde des cumuls indisponible. Partie en pause ; la manche terminée sera réessayée sans doubler les points.');
        }
        return;
    }
    if ($engine->{phase} eq 'preparing' && $now - $game->{preparing_at} > 15) {
        delete $self->{games}{$game->{channel}};
        return $self->_say($context, $inv, 'Préparation interrompue. Partie annulée sans points supplémentaires.');
    }
    if ($engine->{phase} eq 'playing' && ($now >= $engine->{deadline}
        || $engine->{round_best_length} == $engine->{longest})) {
        my $closed = $engine->close_round($now);
        return unless $closed;
        $game->{previous_closed_at} = $now;
        $game->{next_immediate} = 1 if $closed->{top_found};
        my @solutions = @{ $closed->{solutions} };
        my $count = @solutions;
        splice @solutions, 5 if @solutions > 5;
        $self->_say($context, $inv, ($closed->{top_found} ? 'Maximum atteint ! Top : ' : 'Temps écoulé ! Top : ')
            . $closed->{longest} . ' lettres — '
            . join(', ', @solutions) . ($count > 5 ? " (et " . ($count - 5) . ' autres)' : '') . '.');
        my @found = @{ $closed->{results} };
        splice @found, 5 if @found > 5;
        $self->_say($context, $inv, @found ? 'Meilleurs mots : ' . join(' | ', map {
            _nick($_->{nick}) . ' ' . $_->{word} . ' (+' . $_->{points} . ')'
        } @found) : 'Personne n’a proposé de mot valide.');
        $self->_say($context, $inv, 'Classement : ' . _ranking_text($engine->ranking, 5) . '.');
        my $epoch = $game->{round_end_epoch};
        my $zone = $inv->config_value('score_timezone') // 'Europe/Paris';
        $game->{pending_score} = { results => $closed->{results}, round => $engine->{round},
            week => Mediabot::Plugin::LongestWord::Scores::week($epoch, $zone),
            oldest => Mediabot::Plugin::LongestWord::Scores::oldest_week($epoch, $zone) };
        return $self->_advance($context, $inv, $game);
    }
    if ($engine->{phase} eq 'between' && $now >= $game->{next_at}) {
        return $self->_prepare($context, $inv, $game);
    }
    if ($engine->{phase} eq 'playing' && !$game->{warned} && $engine->{deadline} - $now <= 10) {
        $game->{warned} = 1;
        $self->_say($context, $inv, 'Dernières secondes !');
    }
    return 1;
}

sub job_clock {
    my ($self, $context, $inv) = @_;
    my $key = Mediabot::Plugin::LongestWord::Engine::fold($inv->channel);
    return unless $self->{started};
    unless ($inv->activation_mode eq 'on' && $inv->output_allowed) {
        delete $self->{games}{$key}; return;
    }
    my $game = $self->{games}{$key} or return;
    return $self->_advance($context, $inv, $game);
}

sub command_motlong {
    my ($self, $context, $inv) = @_;
    return unless $self->{started} && $inv->activation_mode eq 'on' && $inv->output_allowed;
    my $key = Mediabot::Plugin::LongestWord::Engine::fold($inv->channel);
    my @args = @{ $inv->args };
    my $explicit_word = @args == 2 && lc($args[0]) eq 'mot';
    shift @args if $explicit_word;
    my $op = $explicit_word ? '__word__' : @args ? lc $args[0] : 'start';
    my $now = $self->{clock}->();
    my $game = $self->{games}{$key};
    $self->_advance($context, $inv, $game) if $game;
    $game = $self->{games}{$key};
    if ($op =~ /\A(?:help|aide)\z/) {
        return $self->_notice($context, $inv,
            '!motlong démarre ; propose un mot seul. tirage | score (cumuls) | scores (partie) | top total/semaine [page] | records | stop. '
            . 'Chaque mot doit dépasser le meilleur déjà accepté sur la manche (départ : 0). Top trouvé : longueur + bonus, puis manche suivante immédiate.');
    }
    if ($op eq 'top' || $op eq 'score') {
        return $self->_persistent_scores($context, $inv, $op, \@args);
    }
    if ($op eq 'records') {
        my ($snapshot, $doc) = eval { $self->_hall($context, $inv, _record_scope($inv)) };
        return $self->_notice($context, $inv, 'Les records sont indisponibles.') unless $doc;
        my @rows = map { { nick => $_->[1], score => $_->[2] } } @{ $doc->{entries} };
        return $self->_say($context, $inv, 'Meilleures parties (règles actuelles, par salon) : '
            . _ranking_text(\@rows, 10) . '.');
    }
    if ($op eq 'start' || $op eq 'demarrer') {
        return $self->_notice($context, $inv, 'Une partie est déjà en cours ici. !motlong tirage') if $game;
        return $self->_notice($context, $inv, 'Patiente quelques secondes avant une nouvelle partie.')
            if ($self->{cooldown}{$key} // 0) > $now;
        return $self->_notice($context, $inv, 'Le maximum de huit parties simultanées est atteint.')
            if keys(%{ $self->{games} }) >= 8;
        my $rounds = $inv->config_value('rounds') // 5;
        return $self->_notice($context, $inv, 'Utilise !motlong start.')
            unless @args <= 1 && "$rounds" =~ /\A[0-9]{1,2}\z/ && $rounds >= 1 && $rounds <= 20;
        my $ready = eval {
            $self->_score_snapshot($context, $inv);
            Mediabot::Plugin::LongestWord::Scores::week($self->{wall_clock}->(),
                $inv->config_value('score_timezone') // 'Europe/Paris');
            1;
        };
        return $self->_notice($context, $inv, 'Stockage des scores ou fuseau indisponible : partie non démarrée.') unless $ready;
        $game = { channel => $key, starter => _identity($inv),
            id => sha256_hex(join('|', $key, $$, $self->{wall_clock}->(), ++$self->{serial}, rand())),
            letters => $inv->config_value('letters') // 10,
            vowels => $inv->config_value('vowels') // 4,
            attempts => {}, request => 0,
            engine => Mediabot::Plugin::LongestWord::Engine->new(rounds => $rounds,
                duration => $inv->config_value('round_seconds') // 50,
                bonus => $inv->config_value('top_bonus') // 3),
        };
        $game->{record_scope} = _record_scope($inv);
        $self->{games}{$key} = $game;
        $self->{cooldown}{$key} = $now + 20;
        return $self->_prepare($context, $inv, $game);
    }
    return $self->_notice($context, $inv, 'Aucune partie ici. !motlong pour démarrer, !motlong aide pour les règles.')
        unless $game;
    my $engine = $game->{engine};
    if ($op eq 'stop') {
        return $self->_notice($context, $inv, 'Une manche terminée attend sa sauvegarde. Partie en pause, nouvelle tentative automatique.')
            if $game->{pending_score};
        my $principal = $inv->principal;
        return $self->_notice($context, $inv, 'Seuls l’initiateur et les administrateurs peuvent arrêter cette partie.')
            unless _identity($inv) eq $game->{starter}
                || $principal->has_global_level('administrator') || $principal->has_channel_level(400);
        $context->dictionary_cancel($inv);
        delete $self->{games}{$key};
        $self->{cooldown}{$key} = $now + 20;
        return $self->_say($context, $inv, 'Partie arrêtée. La manche en cours est annulée ; les cumuls des manches déjà terminées sont conservés.');
    }
    if ($op =~ /\A(?:r|tirage|status)\z/) {
        return $self->_notice($context, $inv, 'Préparation du prochain tirage…') unless $engine->{phase} eq 'playing';
        return $self->_notice($context, $inv, join(' ', split //, $engine->{letters}) . ' — '
            . int($engine->{deadline} - $now + 0.999) . 's restantes. Meilleur accepté : '
            . $engine->{round_best_length} . ' lettres ; minimum suivant : ' . ($engine->{round_best_length} + 1) . '.');
    }
    if ($op eq 'scores') {
        return $self->_notice($context, $inv, 'Classement : ' . _ranking_text($engine->ranking, 10));
    }
    return $self->_notice($context, $inv, 'La manche n’est pas ouverte.') unless $engine->{phase} eq 'playing';
    return $self->_notice($context, $inv, 'Propose un seul mot : !motlong MOT.') unless @args == 1;
    return $self->_submit_word($context, $inv, $game, $args[0], 0);
}

1;
