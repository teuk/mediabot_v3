package Mediabot::Plugin::Playful;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    return bless {
        context        => $args{context},
        roll_history   => {},
        flip_stats     => {},
        choose_history => {},
        choose_last    => {},
        rng            => (time() ^ $$ ^ 0x504c4159) & 0xffffffff,
    }, $class;
}

sub start { $_[0]{started} = 1; 1 }
sub stop  { $_[0]{started} = 0; 1 }

sub _rand_index {
    my ($self, $size) = @_;
    $size = 1 unless defined($size) && $size > 0;
    $self->{rng} = (1664525 * $self->{rng} + 1013904223) & 0xffffffff;
    return $self->{rng} % $size;
}

sub _reply  { $_[0]{context}->reply($_[1], $_[2]) }
sub _notice { $_[0]{context}->notice($_[1], $_[2]) }

sub command_8ball {
    my ($self, $context, $invocation) = @_;
    my $question = join(' ', @{ $invocation->args });
    $question =~ s/^\s+|\s+$//g;
    return $context->notice($invocation, 'Syntax: 8ball <question>')
        unless length $question;

    my %answers = (
        en => [
            'It is certain.', 'It is decidedly so.', 'Without a doubt.',
            'Yes, definitely.', 'You may rely on it.', 'As I see it, yes.',
            'Most likely.', 'Outlook good.', 'Yes.',
            'Signs point to yes.', 'Reply hazy, try again.',
            'Ask again later.', 'Better not tell you now.',
            'Cannot predict now.', 'Concentrate and ask again.',
            "Don't count on it.", 'My reply is no.', 'My sources say no.',
            'Outlook not so good.', 'Very doubtful.',
        ],
        fr => [
            q{C'est certain.}, q{C'est absolument ça.}, 'Sans aucun doute.',
            'Oui, définitivement.', 'Tu peux compter dessus.',
            'Comme je le vois, oui.', 'Très probablement.',
            'Les perspectives sont bonnes.', 'Oui.',
            'Les signes indiquent que oui.', 'Flou, essaie encore.',
            'Demande plus tard.', 'Mieux vaut ne pas te le dire maintenant.',
            'Je ne peux pas prédire ça.', 'Concentre-toi et redemande.',
            q{N'y compte pas.}, 'Ma réponse est non.',
            'Mes sources disent non.',
            'Les perspectives ne sont pas bonnes.', 'Très douteux.',
        ],
        es => [
            'Definitivamente sí.', 'Por supuesto.', 'Sin ninguna duda.',
            'Sí, definitivamente.', 'Puedes contar con ello.',
            'Las perspectivas son buenas.', 'Muy probablemente.', 'Sí.',
            'Los indicios apuntan que sí.', 'Como yo lo veo, sí.',
            'La respuesta es incierta, intenta de nuevo.',
            'Pregunta más tarde.', 'Mejor no responderte ahora.',
            'No puedo predecirlo.', 'Concéntrate y pregunta de nuevo.',
            'No cuentes con ello.', 'Mi respuesta es no.',
            'Mis fuentes dicen que no.',
            'Las perspectivas no son buenas.', 'Muy dudoso.',
        ],
    );
    my $language = $invocation->config_value('language') || 'fr';
    my $pool = $answers{$language} || $answers{en};
    my $answer = $pool->[ $self->_rand_index(scalar @$pool) ];
    return $context->reply($invocation,
        "\x038\x02[8ball]\x0f " . $invocation->nick . ": $answer");
}

sub command_roll {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my $channel = $invocation->channel;
    my $nick = $invocation->nick;

    if (@args && lc($args[0]) eq 'history') {
        my $history = $self->{roll_history}{$channel} || [];
        return $context->reply($invocation,
            @$history ? 'Last rolls: ' . join('  |  ', reverse @$history)
                     : "$nick: no roll history on $channel.");
    }

    my ($number, $sides, $modifier, $mode) = (1, 6, 0, '');
    if (@args && $args[0] =~ /\A(\d+)d(\d+)\z/i) {
        ($number, $sides) = ($1, $2);
        $number = 1 if $number < 1;
        $number = 20 if $number > 20;
        $sides = 2 if $sides < 2;
        $sides = 100 if $sides > 100;
    }
    elsif (@args && $args[0] =~ /\A\d+\z/) {
        $sides = int($args[0]);
        $sides = 2 if $sides < 2;
        $sides = 100 if $sides > 100;
    }
    for my $extra (@args > 1 ? @args[1 .. $#args] : ()) {
        if ($extra =~ /\A([+-]\d+)\z/) {
            $modifier = int($1);
            $modifier = 100 if $modifier > 100;
            $modifier = -100 if $modifier < -100;
        }
        elsif ($extra =~ /\Aadv(?:antage)?\z/i) { $mode = 'adv' }
        elsif ($extra =~ /\Adis(?:advantage)?\z/i) { $mode = 'dis' }
    }

    my @rolls = map { 1 + $self->_rand_index($sides) } 1 .. $number;
    my $label = "${number}d${sides}";
    my $out;
    if ($mode && $number == 1) {
        my $second = 1 + $self->_rand_index($sides);
        my ($kept, $dropped) = $mode eq 'adv'
            ? sort { $b <=> $a } ($rolls[0], $second)
            : sort { $a <=> $b } ($rolls[0], $second);
        my $total = $kept + $modifier;
        my $mod = $modifier ? sprintf(' %+d = %d', $modifier, $total) : '';
        $out = sprintf('%s rolled %s (%s): [%d, %s]%s  → %d',
            $nick, $label, $mode, $kept, "\x1e$dropped\x0f", $mod, $total);
    }
    elsif ($number == 1) {
        my $total = $rolls[0] + $modifier;
        my $mod = $modifier ? sprintf(' %+d = %d', $modifier, $total) : '';
        $out = "$nick rolled $label: $rolls[0]$mod";
    }
    else {
        my $sum = 0; $sum += $_ for @rolls;
        my $total = $sum + $modifier;
        my $mod = $modifier ? sprintf(' %+d = %d', $modifier, $total) : " = $sum";
        $out = sprintf('%s rolled %s: [%s]%s',
            $nick, $label, join(', ', @rolls), $mod);
    }
    my $history = $self->{roll_history}{$channel} ||= [];
    push @$history, $out;
    splice @$history, 0, @$history - 5 if @$history > 5;
    return $context->reply($invocation, $out);
}

sub command_flip {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my ($channel, $nick) = ($invocation->channel, $invocation->nick);
    my $stats = $self->{flip_stats}{$channel} ||= { h => 0, t => 0 };
    if (@args && lc($args[0]) eq 'stats') {
        my $total = $stats->{h} + $stats->{t};
        return $context->reply($invocation,
            "$nick: no flips yet on $channel.") unless $total;
        return $context->reply($invocation, sprintf(
            '%s flip stats on %s: %d Heads (%.0f%%)  %d Tails (%.0f%%)  — %d total',
            $nick, $channel, $stats->{h}, 100 * $stats->{h} / $total,
            $stats->{t}, 100 * $stats->{t} / $total, $total));
    }
    my $number = @args && $args[0] =~ /\A\d+\z/ ? int($args[0]) : 1;
    $number = 1 if $number < 1;
    $number = 10 if $number > 10;
    my @results;
    for (1 .. $number) {
        my $result = $self->_rand_index(2) ? 'T' : 'H';
        push @results, $result;
        $result eq 'H' ? $stats->{h}++ : $stats->{t}++;
    }
    return $context->reply($invocation, $number == 1
        ? "$nick flipped a coin: " . ($results[0] eq 'H' ? 'Heads!' : 'Tails!')
        : sprintf('%s flipped %d coins: %s  (%d H, %d T)',
            $nick, $number, join('', @results),
            scalar(grep { $_ eq 'H' } @results),
            scalar(grep { $_ eq 'T' } @results)));
}

sub command_choose {
    my ($self, $context, $invocation) = @_;
    my @args = @{ $invocation->args };
    my ($channel, $nick) = ($invocation->channel, $invocation->nick);
    if (@args && lc($args[0]) eq 'history') {
        my $history = $self->{choose_history}{$channel} || [];
        return $context->reply($invocation,
            @$history ? 'Last choices: ' . join(' | ', reverse @$history)
                     : "$nick: no choice history on $channel.");
    }
    if (@args && lc($args[0]) eq 'last') {
        my $last = $self->{choose_last}{$channel};
        return $context->reply($invocation, defined($last)
            ? "$nick: last choice was: $last"
            : "$nick: no previous choice on this channel.");
    }
    my $raw = join(' ', @args);
    my $separator = $raw =~ /\|/ ? qr/\|/ : qr/\s+ou\s+/i;
    my @raw = grep { length } map {
        my $value = $_; $value =~ s/^\s+|\s+$//g; $value
    } split $separator, $raw;
    my (%seen, @unique);
    push @unique, $_ for grep { !$seen{lc $_}++ } @raw;
    if (@unique < @raw) {
        $context->notice($invocation,
            'Note: ' . (@raw - @unique) . ' duplicate option(s) removed.');
    }
    my @pool;
    for my $option (@unique) {
        if ($option =~ /\A(.+?):(\d+)\z/ && $2 >= 1 && $2 <= 20) {
            push @pool, ($1) x $2;
        }
        else { push @pool, $option }
    }
    return $context->notice($invocation,
        'No valid options remain after deduplication.') unless @pool;
    return $context->notice($invocation,
        'Only one option left after deduplication — nothing to choose from.')
        unless @pool >= 2;
    my $choice = $pool[ $self->_rand_index(scalar @pool) ];
    $self->{choose_last}{$channel} = $choice;
    my $history = $self->{choose_history}{$channel} ||= [];
    push @$history, $choice;
    splice @$history, 0, @$history - 5 if @$history > 5;
    return $context->reply($invocation,
        "$nick: I choose... $choice!"
            . (@pool > 2 ? ' (1 of ' . scalar(@pool) . ' options)' : ''));
}

sub command_morse {
    my ($self, $context, $invocation) = @_;
    my $text = uc join(' ', @{ $invocation->args });
    $text =~ s/^\s+|\s+$//g;
    return $context->notice($invocation, 'Syntax: morse <text>')
        unless length $text;
    return $context->notice($invocation, 'Text too long (max 80 chars).')
        if length($text) > 80;
    my %code = (
        A=>'.-', B=>'-...', C=>'-.-.', D=>'-..', E=>'.', F=>'..-.',
        G=>'--.', H=>'....', I=>'..', J=>'.---', K=>'-.-', L=>'.-..',
        M=>'--', N=>'-.', O=>'---', P=>'.--.', Q=>'--.-', R=>'.-.',
        S=>'...', T=>'-', U=>'..-', V=>'...-', W=>'.--', X=>'-..-',
        Y=>'-.--', Z=>'--..', '0'=>'-----', '1'=>'.----', '2'=>'..---',
        '3'=>'...--', '4'=>'....-', '5'=>'.....', '6'=>'-....',
        '7'=>'--...', '8'=>'---..', '9'=>'----.',
    );
    my $result = join(' / ', map {
        join(' ', map { $code{$_} // '?' } split //)
    } split /\s+/, $text);
    $result = substr($result, 0, 397) . '...' if length($result) > 400;
    return $context->reply($invocation, $result);
}

sub command_abbrev {
    my ($self, $context, $invocation) = @_;
    my $text = join(' ', @{ $invocation->args });
    $text =~ s/^\s+|\s+$//g;
    return $context->notice($invocation, 'Syntax: abbrev <text>')
        unless length $text;
    my @words = split /\s+/, $text;
    my $abbrev = join('', map { uc substr($_, 0, 1) } @words);
    return $context->reply($invocation,
        $invocation->nick . ": $abbrev (" . scalar(@words) . ' word(s))');
}

sub job_quiet_magic {
    my ($self, $context, $invocation) = @_;
    return 0 unless $invocation->config_value('ritual_enabled');
    my $every = $invocation->config_value('ritual_every') || 4;
    return 0 if $invocation->sequence % $every;
    my $language = $invocation->config_value('language') || 'fr';
    my $style = $invocation->config_value('ritual_style') || 'subtle';
    my %lines = (
        fr => {
            subtle => [
                'Une minuscule chouette en papier traverse le canal, vérifie que tout va bien, puis repart très professionnelle.',
                'Quelque part dans le canal, une théière invisible vient de faire « ding ». Personne ne sait pourquoi, mais le timing est impeccable.',
                'Un petit courant d’air feuillette les vieux messages et remet discrètement une virgule à sa place.',
            ],
            chaos => [
                'ALERTE TRÈS MODÉRÉE : trois chaussettes viennent de fonder un ministère provisoire dans le canal.',
                'Une pluie de confettis administratifs vient de valider le formulaire B-42. Le canal peut continuer.',
                'Le plafond imaginaire s’ouvre : un canard en cravate inspecte le canal, prend une note, puis disparaît.',
            ],
        },
        en => {
            subtle => [
                'A tiny paper owl crosses the channel, checks that everything is fine, then leaves looking very professional.',
                'An invisible teapot just went “ding” somewhere in the channel. Nobody knows why, but the timing was excellent.',
                'A small draft flips through the old messages and quietly puts one comma back in place.',
            ],
            chaos => [
                'VERY MODERATE ALERT: three socks have founded a provisional ministry in the channel.',
                'A shower of administrative confetti has approved form B-42. The channel may continue.',
                'The imaginary ceiling opens: a duck in a tie inspects the channel, takes one note, and vanishes.',
            ],
        },
        es => {
            subtle => [
                'Un pequeño búho de papel cruza el canal, comprueba que todo va bien y se marcha muy profesional.',
                'Una tetera invisible acaba de hacer «ding». Nadie sabe por qué, pero el momento fue perfecto.',
                'Una corriente de aire hojea los mensajes antiguos y coloca discretamente una coma en su sitio.',
            ],
            chaos => [
                'ALERTA MUY MODERADA: tres calcetines han fundado un ministerio provisional en el canal.',
                'Una lluvia de confeti administrativo ha aprobado el formulario B-42. El canal puede continuar.',
                'El techo imaginario se abre: un pato con corbata inspecciona el canal, toma nota y desaparece.',
            ],
        },
    );
    my $pool = $lines{$language}{$style} || $lines{en}{subtle};
    my $line = $pool->[ $self->_rand_index(scalar @$pool) ];
    return $context->channel_message($invocation, $line);
}

1;
